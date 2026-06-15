part of '../llm_chat_service.dart';

extension LlmChatServiceStreamHandler on LlmChatService {
  Future<String> _sendImpl({
    required List<Map<String, dynamic>> messages,
    String? modelOverride,
    Future<AiToolApprovalDecision> Function(AiToolApprovalRequest request)?
        requestToolApproval,
    void Function(LlmRunStats stats)? onStats,
    void Function(LlmTraceEvent event)? onTrace,
    LlmCancellationToken? cancellationToken,
    bool planMode = false,
  }) async {
    final buffer = StringBuffer();
    await for (final chunk in _streamImpl(
      messages: messages,
      modelOverride: modelOverride,
      requestToolApproval: requestToolApproval,
      onStats: onStats,
      onTrace: onTrace,
      cancellationToken: cancellationToken,
      planMode: planMode,
    )) {
      buffer.write(chunk);
    }
    return buffer.toString();
  }

  Stream<String> _streamImpl({
    required List<Map<String, dynamic>> messages,
    String? modelOverride,
    Future<AiToolApprovalDecision> Function(AiToolApprovalRequest request)?
        requestToolApproval,
    void Function(LlmRunStats stats)? onStats,
    void Function(LlmTraceEvent event)? onTrace,
    LlmCancellationToken? cancellationToken,
    Set<String>? allowedTools,
    bool forceContextCompression = false,
    bool planMode = false,
  }) async* {
    final settings = await storageService.loadAiConnectionSettings();
    final runStartedAt = DateTime.now();
    final model = modelOverride?.trim().isNotEmpty == true
        ? modelOverride!.trim()
        : settings.model;
    final apiKey = await storageService.getAiApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      AppLogService.instance.warning('LLM request blocked: API key missing');
      throw StateError('API key is not configured.');
    }
    _assertValidHeaderApiKey(apiKey);
    AppLogService.instance.info(
      'LLM chat started',
      details:
          'baseUrl=${settings.baseUrl} model=$model userMessages=${messages.length} forceContextCompression=$forceContextCompression planMode=$planMode',
    );

    var workingMessages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': systemPromptFor(planMode: planMode),
      },
      ...messages,
    ];
    final estimatedBeforeCompression =
        LlmChatService.estimateMessagesTokens(workingMessages);
    var compressed = false;
    final shouldCompressFromUsageThreshold =
        estimatedBeforeCompression >= settings.contextWindowTokens * 0.9;
    if (shouldCompressFromUsageThreshold || forceContextCompression) {
      workingMessages = await _compressWorkingMessages(
        baseUrl: settings.baseUrl,
        apiKey: apiKey,
        model: model,
        messages: messages,
        contextWindowTokens: settings.contextWindowTokens,
        deepSeekThinkingEnabled: settings.deepSeekThinkingEnabled,
        deepSeekReasoningEffort: settings.deepSeekReasoningEffort,
        openAiReasoningEffort: settings.openAiReasoningEffort,
        cancellationToken: cancellationToken,
      );
      compressed = true;
      if (forceContextCompression && !shouldCompressFromUsageThreshold) {
        AppLogService.instance.info(
          'LLM context compression forced',
          details:
              'baseTokens=$estimatedBeforeCompression window=${settings.contextWindowTokens}',
        );
      }
    }
    final toolDefinitions = await toolService.toolDefinitions();
    final normalizedAllowedTools = _normalizeToolNames(allowedTools);
    final filteredToolDefinitions = normalizedAllowedTools == null
        ? toolDefinitions
        : _filterToolDefinitions(toolDefinitions, normalizedAllowedTools);
    var currentToolDefinitions = filteredToolDefinitions;

    bool isReadOnlyTool(String toolName) {
      const writeTools = {
        'client_write_clipboard',
        'client_export_backup',
        'client_import_backup',
        'client_webview_navigate',
        'client_webview_scroll',
        'client_save_experience_skill',
        'ssh_connect',
        'ssh_disconnect',
        'ssh_send_input',
        'sftp_write_text',
        'sftp_upload_local_file',
        'sftp_create_directory',
        'sftp_rename_entry',
        'sftp_delete_entry',
        'playbook_execute',
      };
      return !writeTools.contains(toolName);
    }

    if (planMode) {
      currentToolDefinitions = currentToolDefinitions.where((def) {
        final function = def['function'];
        if (function is! Map) return false;
        final name = function['name'];
        if (name is! String) return false;
        return isReadOnlyTool(name);
      }).toList();
    }

    final toolBudget = LlmToolBudgetController(
      baseBudget: settings.toolCallBudget,
    );
    final toolLedger = <LlmToolLedgerEntry>[];
    final originalUserGoal = _latestUserGoal(messages);
    if (normalizedAllowedTools == null) {
      AppLogService.instance.info(
        'LLM tool filter skipped',
        details: 'availableTools=${toolDefinitions.length} planMode=$planMode',
      );
    } else {
      AppLogService.instance.info(
        'LLM tool definitions filtered',
        details:
            'requestedTools=${normalizedAllowedTools.length} availableTools=${toolDefinitions.length} filteredTools=${filteredToolDefinitions.length} planMode=$planMode',
      );
    }

    final isMultiAgent = settings.multiAgentEnabled || planMode;
    final activeMaxAgents = planMode ? 5 : settings.multiAgentMaxAgents;

    final multiAgentResult = await multiAgentCoordinator.run(
      messages: workingMessages,
      enabled: isMultiAgent,
      maxAgents: activeMaxAgents,
      checkCancelled: cancellationToken?.throwIfCancelled,
      language: language,
      plannerPrompt: plannerPrompt,
      operatorPrompt: operatorPrompt,
      explorePrompt: explorePrompt,
      reviewerPrompt: reviewerPrompt,
      summarizerPrompt: summarizerPrompt,
      coordinatorPrompt: coordinatorPrompt,
      planMode: planMode,
      classify: (classificationMessages) async {
        final response = await _chatCompletion(
          baseUrl: settings.baseUrl,
          apiKey: apiKey,
          model: model,
          messages: classificationMessages,
          deepSeekThinkingEnabled: false,
          deepSeekReasoningEffort: settings.deepSeekReasoningEffort,
          openAiReasoningEffort: 'low',
          cancellationToken: cancellationToken,
          operationLabel: 'LLM multi-agent classification',
        );
        return _contentFromChatResponse(response);
      },
      complete: (role, roleMessages, {required thinkingSettings}) async {
        final response = await _chatCompletion(
          baseUrl: settings.baseUrl,
          apiKey: apiKey,
          model: model,
          messages: roleMessages,
          deepSeekThinkingEnabled: thinkingSettings.thinkingEnabled,
          deepSeekReasoningEffort: settings.deepSeekReasoningEffort,
          openAiReasoningEffort: thinkingSettings.reasoningEffort,
          cancellationToken: cancellationToken,
          operationLabel: 'LLM multi-agent helper (${role.name})',
        );
        return _contentFromChatResponse(response);
      },
    );
    if (multiAgentResult != null) {
      workingMessages.add({
        'role': 'assistant',
        'content': multiAgentResult.memoryContent,
      });
      onTrace?.call(
        LlmTraceEvent(
          kind: 'multi_agent',
          title: 'Multi-agent collaboration',
          content: multiAgentResult.traceContent,
        ),
      );

      if (planMode) {
        yield multiAgentResult.memoryContent;
        final elapsedMs =
            DateTime.now().difference(runStartedAt).inMilliseconds;
        final promptTokens =
            LlmChatService.estimateMessagesTokens(workingMessages);
        final completionTokens = LlmChatService.estimateTextTokens(
            multiAgentResult.memoryContent);
        onStats?.call(
          LlmRunStats(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: promptTokens + completionTokens,
            elapsedMs: elapsedMs,
            usageFromProvider: false,
            contextTokensBeforeCompression: estimatedBeforeCompression,
            contextWindowTokens: settings.contextWindowTokens,
            compressed: compressed,
          ),
        );
        return;
      }
    }

    final visibleOutput = StringBuffer();
    for (var round = 0;; round++) {
      cancellationToken?.throwIfCancelled();
      final content = StringBuffer();
      final chunkController = StreamController<String>();
      _StreamChatResult? streamedResponse;
      Object? streamedError;
      StackTrace? streamedStackTrace;

      Future<void> pumpStream() async {
        try {
          streamedResponse = await _streamChatCompletion(
            baseUrl: settings.baseUrl,
            apiKey: apiKey,
            model: model,
            messages: workingMessages,
            tools: currentToolDefinitions,
            deepSeekThinkingEnabled: settings.deepSeekThinkingEnabled,
            deepSeekReasoningEffort: settings.deepSeekReasoningEffort,
            openAiReasoningEffort: settings.openAiReasoningEffort,
            cancellationToken: cancellationToken,
            includeTools: currentToolDefinitions.isNotEmpty,
            onContent: (chunk) {
              cancellationToken?.throwIfCancelled();
              content.write(chunk);
              chunkController.add(chunk);
            },
          );
        } catch (e, stackTrace) {
          streamedError = e;
          streamedStackTrace = stackTrace;
        } finally {
          await chunkController.close();
        }
      }

      unawaited(pumpStream());

      await for (final chunk in chunkController.stream) {
        visibleOutput.write(chunk);
        yield chunk;
      }
      if (streamedError != null) {
        Error.throwWithStackTrace(streamedError!, streamedStackTrace!);
      }
      cancellationToken?.throwIfCancelled();
      final response = streamedResponse;
      if (response == null) {
        throw StateError('LLM stream ended without a response.');
      }
      _emitReasoningTrace(onTrace, response.reasoningContent);

      if (response.toolCalls.isEmpty) {
        final answer =
            content.toString().trim().isNotEmpty ? content.toString() : 'Done.';
        if (content.isEmpty) yield answer;
        AppLogService.instance.info(
          'LLM chat completed',
          details: 'rounds=${round + 1} answerChars=${answer.length}',
        );
        final elapsedMs =
            DateTime.now().difference(runStartedAt).inMilliseconds;
        final promptTokens = response.usage?.promptTokens ??
            LlmChatService.estimateMessagesTokens(workingMessages);
        final completionTokens = response.usage?.completionTokens ??
            LlmChatService.estimateTextTokens(answer);
        onStats?.call(
          LlmRunStats(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens:
                response.usage?.totalTokens ?? promptTokens + completionTokens,
            elapsedMs: elapsedMs,
            usageFromProvider: response.usage != null,
            promptCacheHitTokens: response.usage?.promptCacheHitTokens,
            promptCacheMissTokens: response.usage?.promptCacheMissTokens,
            reasoningTokens: response.usage?.reasoningTokens,
            contextTokensBeforeCompression: estimatedBeforeCompression,
            contextWindowTokens: settings.contextWindowTokens,
            compressed: compressed,
          ),
        );
        return;
      }

      AppLogService.instance.info(
        'LLM requested tools',
        details:
            'round=${round + 1} tools=${response.toolCalls.map((call) => call.name).join(',')}',
      );
      final assistantToolMessage = <String, dynamic>{
        'role': 'assistant',
        'content': content.toString(),
        'tool_calls': [
          for (final call in response.toolCalls)
            {
              'id': call.id,
              'type': 'function',
              'function': {
                'name': call.name,
                'arguments': call.arguments,
              },
            },
        ],
      };

      if (response.reasoningContent.trim().isNotEmpty) {
        assistantToolMessage['reasoning_content'] = response.reasoningContent;
      }
      workingMessages.add(assistantToolMessage);
      for (var toolIndex = 0;
          toolIndex < response.toolCalls.length;
          toolIndex++) {
        final call = response.toolCalls[toolIndex];
        cancellationToken?.throwIfCancelled();
        final arguments = _decodeArguments(call.arguments);
        onTrace?.call(
          LlmTraceEvent(
            kind: 'tool_request',
            title: 'Tool request: ${call.name}',
            content: _prettyJson({
              'tool': call.name,
              'arguments': _toolSecretPolicy.redactValue(arguments),
            }),
          ),
        );
        final budgetCheck = toolBudget.checkBeforeToolCall();
        if (budgetCheck.requiresAudit) {
          bool humanApproved = true;
          if (toolBudget.auditCount >= 3) {
            if (requestToolApproval != null) {
              _emitBudgetTrace(
                onTrace,
                title: 'Requesting human approval for safety audit extension',
                content: _prettyJson({
                  'message':
                      'AI tool usage requires additional human confirmation after 3 automated safety audits.',
                  'budget': toolBudget.toJson(),
                  'auditCount': toolBudget.auditCount,
                  'nextTool': call.name,
                }),
              );

              final humanDecision = await requestToolApproval(
                const AiToolApprovalRequest(
                  toolName: 'budget_audit',
                  approvalType: 'budget_audit',
                  connectionId: 'local',
                  connectionName: 'System',
                  command: 'Request permission to extend tool usage budget',
                  reason:
                      'The assistant has performed 3 automated safety audits. Continue using tools?',
                ),
              );
              humanApproved = humanDecision.approved;
            } else {
              humanApproved = false;
            }
          }

          if (!humanApproved) {
            currentToolDefinitions = const [];
            final auditResult = LlmToolSafetyAuditResult.blocked(
              summary: 'The user rejected the request to continue tool usage.',
              issues: ['Human safety approval was denied.'],
              suspectedLoop: false,
              goalDrift: false,
              recommendedNextAction:
                  'Finish the conversation without more tools.',
            );
            _emitBudgetTrace(
              onTrace,
              title: 'Tool budget safety audit rejected by user',
              content: _prettyJson({
                'message':
                    'The user rejected the request to continue tool usage.',
                'budget': toolBudget.toJson(),
                'auditCount': toolBudget.auditCount,
              }),
            );
            for (var blockedIndex = toolIndex;
                blockedIndex < response.toolCalls.length;
                blockedIndex++) {
              final blockedCall = response.toolCalls[blockedIndex];
              final blockedResult = _toolBudgetBlockedToolResult(
                toolName: blockedCall.name,
                toolBudget: toolBudget,
                auditResult: auditResult,
              );
              _emitToolResultTrace(onTrace, blockedCall.name, blockedResult);
              workingMessages.add({
                'role': 'tool',
                'tool_call_id': blockedCall.id,
                'content': blockedResult,
              });
            }
            workingMessages.add({
              'role': 'system',
              'content': _toolBudgetRejectedFollowUpPrompt(
                auditResult: auditResult,
                toolBudget: toolBudget,
              ),
            });
            break;
          }

          toolBudget.recordAuditTriggered();
          _emitBudgetTrace(
            onTrace,
            title: 'Tool budget safety audit running',
            content: _prettyJson({
              'message':
                  'Tool usage reached the current ceiling. Running an internal safety audit before granting more tool calls.',
              'budget': toolBudget.toJson(),
              'nextTool': call.name,
            }),
          );
          final auditResult = await _runToolSafetyAudit(
            baseUrl: settings.baseUrl,
            apiKey: apiKey,
            model: model,
            deepSeekThinkingEnabled: settings.deepSeekThinkingEnabled,
            deepSeekReasoningEffort: settings.deepSeekReasoningEffort,
            openAiReasoningEffort: settings.openAiReasoningEffort,
            originalUserGoal: originalUserGoal,
            workingMessages: workingMessages,
            toolLedger: toolLedger,
            toolBudget: toolBudget,
            cancellationToken: cancellationToken,
          );
          cancellationToken?.throwIfCancelled();
          if (auditResult.shouldContinue) {
            final budgetEvent = toolBudget.approveAuditExtension();
            _emitBudgetTrace(
              onTrace,
              title: 'Tool budget safety audit approved',
              content: _prettyJson({
                'message':
                    'The safety audit approved continued tool use. The tool budget was extended again.',
                'budget': toolBudget.toJson(),
                'extension': budgetEvent.toJson(),
                'summary': auditResult.summary,
                'issues': auditResult.issues,
                'suspectedLoop': auditResult.suspectedLoop,
                'goalDrift': auditResult.goalDrift,
                'recommendedNextAction': auditResult.recommendedNextAction,
              }),
            );
          } else {
            currentToolDefinitions = const [];
            _emitBudgetTrace(
              onTrace,
              title: 'Tool budget safety audit rejected',
              content: _prettyJson({
                'message':
                    'The safety audit rejected further tool use for this run. Tools are now disabled and the assistant must finish without more tool calls.',
                'budget': toolBudget.toJson(),
                'summary': auditResult.summary,
                'issues': auditResult.issues,
                'suspectedLoop': auditResult.suspectedLoop,
                'goalDrift': auditResult.goalDrift,
                'recommendedNextAction': auditResult.recommendedNextAction,
              }),
            );
            for (var blockedIndex = toolIndex;
                blockedIndex < response.toolCalls.length;
                blockedIndex++) {
              final blockedCall = response.toolCalls[blockedIndex];
              final blockedResult = _toolBudgetBlockedToolResult(
                toolName: blockedCall.name,
                toolBudget: toolBudget,
                auditResult: auditResult,
              );
              _emitToolResultTrace(onTrace, blockedCall.name, blockedResult);
              workingMessages.add({
                'role': 'tool',
                'tool_call_id': blockedCall.id,
                'content': blockedResult,
              });
            }
            workingMessages.add({
              'role': 'system',
              'content': _toolBudgetRejectedFollowUpPrompt(
                auditResult: auditResult,
                toolBudget: toolBudget,
              ),
            });
            break;
          }
        }

        final budgetEvent = toolBudget.recordAcceptedToolCall();
        if (budgetEvent != null) {
          _emitBudgetTrace(
            onTrace,
            title: 'Tool budget reached and auto-extended',
            content: _prettyJson({
              'message':
                  'The default tool budget was reached. The app automatically granted more tool calls. Please review whether the assistant is still using tools reasonably.',
              'budget': toolBudget.toJson(),
              'extension': budgetEvent.toJson(),
            }),
          );
        }

        var result = jsonEncode({
          'error': 'Tool execution did not complete.',
        });
        var outcome = 'success';
        var approvalRequired = false;
        var approvedWrite = false;
        var stopAfterToolResult = false;
        String? stopMessage;
        try {
          final approvalRequest = toolService.approvalRequestFor(
            call.name,
            arguments,
          );
          approvalRequired = approvalRequest != null;
          if (approvalRequest != null) {
            if (planMode) {
              outcome = 'blocked_in_plan_mode';
              result = jsonEncode({
                'error': 'This write operation or state-changing action is blocked because PLAN MODE is active. You must only outline your plan without execution.',
                'command': approvalRequest.command,
              });
              onTrace?.call(
                LlmTraceEvent(
                  kind: 'approval',
                  title: 'Action blocked in Plan Mode',
                  content: _prettyJson({
                    'tool': call.name,
                    'message': 'Action blocked in plan mode',
                    'command': approvalRequest.command,
                  }),
                ),
              );
            } else if (requestToolApproval == null) {
              outcome = 'approval_unavailable';
              result = jsonEncode({
                'error':
                    'This tool action requires user approval, but no approval UI is available.',
                'command': approvalRequest.command,
              });
            } else {
              AppLogService.instance.info(
                'AI tool approval requested',
                details:
                    'tool=${call.name} connection=${approvalRequest.connectionName} command=${approvalRequest.command}',
              );
              final decision = await requestToolApproval(approvalRequest);
              cancellationToken?.throwIfCancelled();
              if (!decision.approved) {
                outcome = 'approval_rejected';
                AppLogService.instance.warning(
                  'AI tool approval rejected',
                  details:
                      'tool=${call.name} connection=${approvalRequest.connectionName} abort=${decision.abort}',
                );
                result = jsonEncode({
                  'error': 'User rejected the requested tool action.',
                  'command': approvalRequest.command,
                  if (decision.feedback?.trim().isNotEmpty == true)
                    'feedback': decision.feedback!.trim(),
                });
                onTrace?.call(
                  LlmTraceEvent(
                    kind: 'approval',
                    title: 'Tool action rejected',
                    content: _prettyJson({
                      'tool': call.name,
                      'approvalType': approvalRequest.approvalType,
                      'server': approvalRequest.connectionName,
                      'command': approvalRequest.command,
                      'abort': decision.abort,
                      if (decision.feedback?.trim().isNotEmpty == true)
                        'feedback': decision.feedback!.trim(),
                    }),
                  ),
                );
                stopAfterToolResult = decision.abort;
                if (decision.abort) {
                  stopMessage =
                      '\n\nTool action rejected. Operation stopped. You can tell me what to do next.';
                }
              } else {
                approvedWrite = true;
                onTrace?.call(
                  LlmTraceEvent(
                    kind: 'approval',
                    title: 'Tool action approved',
                    content: _prettyJson({
                      'tool': call.name,
                      'approvalType': approvalRequest.approvalType,
                      'server': approvalRequest.connectionName,
                      'command': approvalRequest.command,
                    }),
                  ),
                );
                AppLogService.instance.info(
                  'AI tool approval accepted',
                  details:
                      'tool=${call.name} connection=${approvalRequest.connectionName} command=${approvalRequest.command}',
                );
              }
            }
          }
          if (approvedWrite || !approvalRequired) {
            result = await toolService.execute(
              call.name,
              arguments,
              approvedWrite: approvedWrite,
            );
            cancellationToken?.throwIfCancelled();
            outcome = _classifyToolResultOutcome(result);
          }
        } on LlmCancelledException {
          rethrow;
        } catch (e) {
          outcome = 'execution_error';
          result = jsonEncode({
            'error': _toolSecretPolicy.redactText(e.toString()),
          });
        }
        _emitToolResultTrace(onTrace, call.name, result);
        workingMessages.add({
          'role': 'tool',
          'tool_call_id': call.id,
          'content': result,
        });
        final redactedArguments = _toolSecretPolicy.redactValue(arguments);
        final signatureArguments = _mapFromValue(redactedArguments);
        toolLedger.add(
          LlmToolLedgerEntry(
            index: toolBudget.usedCalls,
            toolName: call.name,
            signature: LlmToolLedgerEntry.buildSignature(
              call.name,
              signatureArguments,
            ),
            argumentsPreview: _toolSecretPolicy.previewText(
              _prettyJson(redactedArguments),
              maxChars: 400,
            ),
            outcome: outcome,
            approvalRequired: approvalRequired,
            approved: approvedWrite,
            failed: outcome != 'success',
            emptyResult: _looksLikeEmptyToolResult(result),
            resultPreview: _toolSecretPolicy.previewText(
              _prettyJsonString(result),
              maxChars: 600,
            ),
          ),
        );
        if (stopAfterToolResult) {
          if (stopMessage != null) {
            yield stopMessage;
          }
          return;
        }
      }
      final separator = _toolContinuationSeparator(visibleOutput.toString());
      if (separator.isNotEmpty) {
        visibleOutput.write(separator);
        yield separator;
      }
    }
  }

  Future<_StreamChatResult> _streamChatCompletion({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    required bool deepSeekThinkingEnabled,
    required String deepSeekReasoningEffort,
    required String openAiReasoningEffort,
    required void Function(String chunk) onContent,
    LlmCancellationToken? cancellationToken,
    bool includeUsage = true,
    bool includeTools = true,
    bool includeReasoningParams = true,
  }) async {
    final endpoint = Uri.parse(_joinUrl(baseUrl, '/chat/completions'));
    for (var attempt = 0;
        attempt <= LlmChatService._networkRetryCount;
        attempt++) {
      final client = HttpClient();
      cancellationToken?.onCancel(() => client.close(force: true));
      final startedAt = DateTime.now();
      final contentChunks = <String>[];
      final reasoningContent = StringBuffer();
      final toolCalls = <int, _StreamingToolCall>{};
      LlmTokenUsage? usage;
      AppLogService.instance.info(
        'LLM stream request sent',
        details:
            'endpoint=$endpoint model=$model messages=${messages.length} attempt=${attempt + 1}',
      );
      try {
        cancellationToken?.throwIfCancelled();
        final request = await client.postUrl(endpoint);
        cancellationToken?.throwIfCancelled();
        final useTools = includeTools && tools.isNotEmpty;
        final requestBody = <String, dynamic>{
          'model': model,
          'messages': messages,
          'stream': true,
          if (useTools) ...{
            'tools': tools,
            'tool_choice': 'auto',
          },
          if (includeUsage) 'stream_options': {'include_usage': true},
        };
        if (includeReasoningParams) {
          requestBody.addAll(
            _providerReasoningParams(
              baseUrl: baseUrl,
              model: model,
              deepSeekThinkingEnabled: deepSeekThinkingEnabled,
              deepSeekReasoningEffort: deepSeekReasoningEffort,
              openAiReasoningEffort: openAiReasoningEffort,
            ),
          );
        }
        final bodyBytes = utf8.encode(jsonEncode(requestBody));
        request.headers
          ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey')
          ..contentType = ContentType.json;
        request.contentLength = bodyBytes.length;
        request.add(bodyBytes);
        final response = await request.close();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final body = await response.transform(utf8.decoder).join();
          if (includeUsage &&
              response.statusCode == 400 &&
              (body.contains('stream_options') ||
                  body.contains('include_usage'))) {
            AppLogService.instance.warning(
              'LLM stream usage unsupported, retrying without usage',
              details:
                  'endpoint=$endpoint model=$model bodyChars=${body.length}',
            );
            return _streamChatCompletion(
              baseUrl: baseUrl,
              apiKey: apiKey,
              model: model,
              messages: messages,
              tools: tools,
              deepSeekThinkingEnabled: deepSeekThinkingEnabled,
              deepSeekReasoningEffort: deepSeekReasoningEffort,
              openAiReasoningEffort: openAiReasoningEffort,
              onContent: onContent,
              cancellationToken: cancellationToken,
              includeUsage: false,
              includeTools: includeTools,
              includeReasoningParams: includeReasoningParams,
            );
          }
          if (includeTools && _looksLikeToolUnsupportedError(body)) {
            AppLogService.instance.warning(
              'LLM stream tools unsupported, retrying without tools',
              details:
                  'endpoint=$endpoint model=$model bodyChars=${body.length}',
            );
            return _streamChatCompletion(
              baseUrl: baseUrl,
              apiKey: apiKey,
              model: model,
              messages: messages,
              tools: tools,
              deepSeekThinkingEnabled: deepSeekThinkingEnabled,
              deepSeekReasoningEffort: deepSeekReasoningEffort,
              openAiReasoningEffort: openAiReasoningEffort,
              onContent: onContent,
              cancellationToken: cancellationToken,
              includeUsage: includeUsage,
              includeTools: false,
              includeReasoningParams: includeReasoningParams,
            );
          }
          if (includeReasoningParams &&
              _looksLikeReasoningParamUnsupportedError(body)) {
            AppLogService.instance.warning(
              'LLM reasoning params unsupported, retrying without them',
              details:
                  'endpoint=$endpoint model=$model bodyChars=${body.length}',
            );
            return _streamChatCompletion(
              baseUrl: baseUrl,
              apiKey: apiKey,
              model: model,
              messages: messages,
              tools: tools,
              deepSeekThinkingEnabled: deepSeekThinkingEnabled,
              deepSeekReasoningEffort: deepSeekReasoningEffort,
              openAiReasoningEffort: openAiReasoningEffort,
              onContent: onContent,
              cancellationToken: cancellationToken,
              includeUsage: includeUsage,
              includeTools: includeTools,
              includeReasoningParams: false,
            );
          }
          AppLogService.instance.warning(
            'LLM stream request failed',
            details:
                'status=${response.statusCode} elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} bodyChars=${body.length}',
          );
          throw StateError(
            'LLM stream failed (${response.statusCode}): $body',
          );
        }

        await for (final line in response
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          cancellationToken?.throwIfCancelled();
          final trimmed = line.trim();
          if (!trimmed.startsWith('data:')) continue;
          final data = trimmed.substring(5).trim();
          if (data == '[DONE]') break;
          if (data.isEmpty) continue;

          final decoded = jsonDecode(data) as Map<String, dynamic>;
          final rawUsage = decoded['usage'];
          if (rawUsage is Map<String, dynamic>) {
            usage = LlmTokenUsage.fromJson(rawUsage);
          }
          final choices = decoded['choices'] as List<dynamic>? ?? const [];
          if (choices.isEmpty) continue;
          final delta =
              (choices.first as Map<String, dynamic>)['delta'] as Map?;
          if (delta == null) continue;

          final content = delta['content'];
          if (content is String && content.isNotEmpty) {
            contentChunks.add(content);
            onContent(content);
          }

          final reasoning = delta['reasoning_content'];
          if (reasoning is String && reasoning.isNotEmpty) {
            reasoningContent.write(reasoning);
          }

          final rawToolCalls = delta['tool_calls'];
          if (rawToolCalls is List) {
            for (final rawCall in rawToolCalls) {
              if (rawCall is! Map) continue;
              final index = rawCall['index'] as int? ?? 0;
              final current = toolCalls.putIfAbsent(
                index,
                () => _StreamingToolCall(id: '', name: '', arguments: ''),
              );
              final id = rawCall['id'];
              if (id is String && id.isNotEmpty) current.id = id;
              final function = rawCall['function'];
              if (function is Map) {
                final name = function['name'];
                if (name is String && name.isNotEmpty) current.name += name;
                final arguments = function['arguments'];
                if (arguments is String && arguments.isNotEmpty) {
                  current.arguments += arguments;
                }
              }
            }
          }
        }

        final calls = toolCalls.entries
            .where((entry) => entry.value.name.trim().isNotEmpty)
            .map((entry) {
          final call = entry.value;
          if (call.id.trim().isEmpty) {
            call.id = 'call_${entry.key}';
          }
          return call;
        }).toList();
        AppLogService.instance.info(
          'LLM stream response completed',
          details:
              'elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} chunks=${contentChunks.length} toolCalls=${calls.length} attempt=${attempt + 1}',
        );
        return _StreamChatResult(
          contentChunks: contentChunks,
          reasoningContent: reasoningContent.toString(),
          toolCalls: calls,
          usage: usage,
        );
      } catch (e, stackTrace) {
        if (cancellationToken?.isCancelled == true ||
            e is LlmCancelledException) {
          AppLogService.instance.info(
            'LLM stream cancelled',
            details: 'endpoint=$endpoint model=$model',
          );
          throw const LlmCancelledException();
        }
        final canRetry = _isRetryableNetworkError(e) &&
            contentChunks.isEmpty &&
            reasoningContent.isEmpty &&
            toolCalls.isEmpty &&
            attempt < LlmChatService._networkRetryCount;
        if (canRetry) {
          AppLogService.instance.warning(
            'LLM stream network error, retrying',
            details:
                'endpoint=$endpoint model=$model attempt=${attempt + 1} nextAttempt=${attempt + 2} error=$e stack=$stackTrace',
          );
          await _delayBeforeNetworkRetry(attempt, cancellationToken);
          continue;
        }
        AppLogService.instance.error(
          'LLM stream request error',
          error: e,
          stackTrace: stackTrace,
          details: 'endpoint=$endpoint model=$model attempt=${attempt + 1}',
        );
        rethrow;
      } finally {
        client.close(force: true);
      }
    }
    throw StateError('LLM stream failed after network retries.');
  }
}
