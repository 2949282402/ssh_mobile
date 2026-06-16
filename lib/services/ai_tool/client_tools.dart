part of '../ai_tool_service.dart';

class ClientToolsProvider implements AiToolProvider {
  final StorageService storageService;
  final ClientSystemToolAdapter clientSystemToolService;
  final ClientWebViewAdapter clientWebViewService;
  final String? clientWebViewSessionId;
  final ToolSecretPolicy secretPolicy;

  const ClientToolsProvider({
    required this.storageService,
    required this.clientSystemToolService,
    required this.clientWebViewService,
    this.clientWebViewSessionId,
    required this.secretPolicy,
  });

  @override
  Future<List<AiTool>> getTools(AiToolService service) async {
    final searchSettings = await storageService.loadAiConnectionSettings();
    return _getClientTools(service, searchSettings);
  }

  @override
  Future<String?> execute(
    AiToolService service,
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async {
    switch (name) {
      case 'web_search':
        return _webSearch(service, arguments);
      case 'client_get_time':
        return jsonEncode(clientSystemToolService.getClientTime());
      case 'client_get_device_info':
        return jsonEncode(clientSystemToolService.getClientDeviceInfo());
      case 'client_get_network_info':
        return jsonEncode(await clientSystemToolService.getNetworkInfo());
      case 'client_get_battery_status':
        return jsonEncode(await clientSystemToolService.getBatteryStatus());
      case 'client_get_permission_status':
        return jsonEncode(await clientSystemToolService.getPermissionStatus());
      case 'client_open_app_settings':
        return jsonEncode(await clientSystemToolService.openAppSettings());
      case 'client_set_clipboard':
        return _clientSetClipboard(service, arguments);
      case 'client_save_experience_skill':
        return _clientSaveExperienceSkill(service, arguments);
      case 'client_set_alarm':
        return _clientSetAlarm(service, arguments);
      case 'client_list_alarms':
        return jsonEncode(await clientSystemToolService.listAlarms());
      case 'client_cancel_alarm':
        return _clientCancelAlarm(service, arguments);
      case 'client_query_logs':
        return _clientQueryLogs(service, arguments);
      case 'client_delete_log_entries':
        return _clientDeleteLogEntries(service, arguments,
            approvedWrite: approvedWrite);
      case 'client_clear_logs':
        return _clientClearLogs(service, arguments,
            approvedWrite: approvedWrite);
      case 'client_export_app_backup':
        return _clientExportAppBackup(service, arguments);
      case 'client_import_app_backup':
        return _clientImportAppBackup(service, arguments,
            approvedWrite: approvedWrite);
      case 'client_webview_get_page_text':
        return _clientWebViewGetPageText(service, arguments);
      case 'client_webview_get_state':
        return _clientWebViewGetState(service, arguments);
      case 'client_webview_navigate':
        return _clientWebViewNavigate(service, arguments);
      case 'app_get_operational_settings':
        return _appGetOperationalSettings(service, arguments);
      case 'app_update_operational_settings':
        return _appUpdateOperationalSettings(service, arguments,
            approvedWrite: approvedWrite);
      case 'app_clear_secret_cache':
        return _appClearSecretCache(service, arguments);
      case 'client_set_plan_mode':
        return _clientSetPlanMode(service, arguments);
      case 'client_task_create':
        return _clientTaskCreate(service, arguments);
      case 'client_task_update':
        return _clientTaskUpdate(service, arguments);
      default:
        return null;
    }
  }

  Future<String> _webSearch(
      AiToolService service, Map<String, dynamic> arguments) async {
    final settings = await storageService.loadAiConnectionSettings();
    if (!settings.webSearchEnabled) {
      return jsonEncode({
        'execution': 'client',
        'target': 'client_webview',
        'provider': 'local_webview',
        'error': 'Web search is not enabled in LLM settings.',
      });
    }

    final query = service._arg(arguments, 'query');
    final limit = _webSearchLimit(arguments['limit'], settings);

    if (settings.webSearchEngine == AiWebSearchEngine.quark) {
      final result = await _executeQuarkCloudSearch(
        service,
        query,
        limit: limit,
        settings: settings,
      );
      return jsonEncode(result.toJson());
    }

    final chatId = clientWebViewSessionId;
    if (chatId == null || chatId.trim().isEmpty) {
      return jsonEncode(_missingChatSessionPayload());
    }
    final result = await clientWebViewService.searchWeb(
      chatId,
      query,
      maxResults: limit,
      engine: settings.webSearchEngine,
    );
    return jsonEncode(result.toJson());
  }

  Future<ClientWebViewSearchResult> _executeQuarkCloudSearch(
    AiToolService service,
    String query, {
    required int limit,
    required AiConnectionSettings settings,
  }) async {
    final apiKey = await storageService.getQuarkApiKey();
    if (apiKey == null || apiKey.trim().isEmpty) {
      return ClientWebViewSearchResult(
        chatId: clientWebViewSessionId ?? 'cloud',
        supported: true,
        query: query,
        results: const [],
        engine: 'quark',
        error: '阿里云夸克搜索 API Key 未在大模型设置中配置。',
      );
    }

    final endpoint = settings.quarkSearchEndpoint.isNotEmpty
        ? settings.quarkSearchEndpoint
        : 'https://dashscope.aliyuncs.com/api/v1/services/search/quark';

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      final uri = Uri.parse(endpoint);
      final request = await client.postUrl(uri);
      request.headers.set('Authorization', 'Bearer $apiKey');
      request.headers.set('Content-Type', 'application/json');

      final body = jsonEncode({
        'query': query,
        'parameter': {
          'top_k': limit,
        }
      });
      request.write(body);

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        return ClientWebViewSearchResult(
          chatId: clientWebViewSessionId ?? 'cloud',
          supported: true,
          query: query,
          results: const [],
          engine: 'quark',
          error: '夸克搜索请求失败: HTTP ${response.statusCode} $responseBody',
        );
      }

      final decoded = jsonDecode(responseBody);
      final results = <ClientWebViewSearchItem>[];

      final output = decoded['output'];
      if (output is Map) {
        final rawResults = output['results'];
        if (rawResults is List) {
          for (final item in rawResults) {
            if (item is Map) {
              final title = (item['title'] as String?)?.trim() ?? '';
              final url = (item['link'] as String?)?.trim() ??
                  (item['url'] as String?)?.trim() ??
                  '';
              final snippet = (item['snippet'] as String?)?.trim() ??
                  (item['description'] as String?)?.trim() ??
                  '';
              if (title.isNotEmpty && url.isNotEmpty) {
                results.add(ClientWebViewSearchItem(
                  title: title,
                  url: url,
                  snippet: snippet,
                ));
              }
            }
          }
        }
      }

      return ClientWebViewSearchResult(
        chatId: clientWebViewSessionId ?? 'cloud',
        supported: true,
        query: query,
        searchUrl: endpoint,
        title: '夸克搜索结果',
        results: results,
        capturedAt: DateTime.now(),
        engine: 'quark',
        error: results.isEmpty ? '夸克搜索未返回 any 结果。' : null,
      );
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Quark cloud search request failed',
        error: e,
        stackTrace: stackTrace,
        details: 'query=$query',
      );
      return ClientWebViewSearchResult(
        chatId: clientWebViewSessionId ?? 'cloud',
        supported: true,
        query: query,
        results: const [],
        engine: 'quark',
        error: '夸克搜索请求异常: $e',
      );
    } finally {
      client.close();
    }
  }

  int _webSearchLimit(Object? requestedLimit, AiConnectionSettings settings) {
    final configuredLimit = AiWebSearchMaxResults.normalize(
      settings.webSearchMaxResults,
    );
    final parsedLimit = switch (requestedLimit) {
      num value => value.toInt(),
      String value => int.tryParse(value.trim()),
      _ => null,
    };
    return (parsedLimit ?? configuredLimit).clamp(1, configuredLimit).toInt();
  }

  Future<String> _clientSetAlarm(
      AiToolService service, Map<String, dynamic> arguments) async {
    final result = await clientSystemToolService.setAlarm(
      triggerAt: service._optionalString(arguments, 'triggerAt'),
      delaySeconds: service._optionalInt(arguments, 'delaySeconds'),
      delayMinutes: service._optionalInt(arguments, 'delayMinutes'),
      label: service._optionalString(arguments, 'label'),
      useSystemAlarm:
          service._optionalBool(arguments, 'useSystemAlarm') ?? true,
    );
    return jsonEncode(result);
  }

  Future<String> _clientCancelAlarm(
      AiToolService service, Map<String, dynamic> arguments) async {
    return jsonEncode(
      await clientSystemToolService
          .cancelAlarm(service._arg(arguments, 'alarmId')),
    );
  }

  Future<String> _clientSetClipboard(
      AiToolService service, Map<String, dynamic> arguments) async {
    return jsonEncode(
      await clientSystemToolService
          .setClipboard(service._arg(arguments, 'text')),
    );
  }

  Future<String> _clientSaveExperienceSkill(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    final summary = service._arg(arguments, 'summary');
    final conciseSummary = _coerceConciseSkillSummary(summary);
    final title = service._optionalString(arguments, 'title') ??
        _defaultExperienceSkillTitle(conciseSummary);
    final details = service._optionalString(arguments, 'content');
    final now = DateTime.now();
    final record = AiSkillRecord(
      id: 'skill-${now.microsecondsSinceEpoch}',
      name: title,
      description: conciseSummary,
      content: details == null || details.trim().isEmpty
          ? conciseSummary
          : '$summary\n\n${details.trim()}',
      createdAt: now,
      updatedAt: now,
    );
    await storageService.saveAiSkill(record);
    AppLogService.instance.info(
      'AI experience skill saved',
      details:
          'skillId=${record.id} name=${secretPolicy.previewText(record.name)}',
    );
    return jsonEncode({
      'execution': 'client',
      'target': 'local_skill',
      'saved': true,
      'skillId': record.id,
      'name': record.name,
      'description': record.description,
    });
  }

  String _defaultExperienceSkillTitle(String summary) {
    final lines = summary
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.isEmpty) return 'Experience note';
    final firstLine = lines.first;
    if (firstLine.length <= 30) return firstLine;
    return '${firstLine.substring(0, 27).trim()}...';
  }

  String _coerceConciseSkillSummary(String summary) {
    final normalized = summary.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= 140) {
      return normalized;
    }
    final head = normalized.substring(0, 140).trim();
    final lastWordBoundary = head.lastIndexOf(' ');
    final truncated = lastWordBoundary >= 72
        ? head.substring(0, lastWordBoundary).trim()
        : head;
    return '$truncated…';
  }

  Future<String> _clientQueryLogs(
      AiToolService service, Map<String, dynamic> arguments) async {
    final result = await clientSystemToolService.queryLogs(
      level: service._optionalString(arguments, 'level'),
      contains: service._optionalString(arguments, 'contains'),
      limit: service._optionalInt(arguments, 'limit') ?? 50,
    );
    return jsonEncode(result);
  }

  Future<String> _clientDeleteLogEntries(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Deleting client log entries requires user approval.',
      });
    }
    final ids = service._intList(arguments['ids']);
    return jsonEncode(await clientSystemToolService.deleteLogEntries(ids));
  }

  Future<String> _clientClearLogs(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Clearing client logs requires user approval.',
      });
    }
    return jsonEncode(await clientSystemToolService.clearLogs());
  }

  Future<String> _clientExportAppBackup(
      AiToolService service, Map<String, dynamic> arguments) async {
    final jsonText = await storageService.exportAppDataJson();
    final now = DateTime.now();
    final fileName =
        'ssh_mobile_backup_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}.json';
    final saveResult = await clientSystemToolService.saveBytesToFile(
      fileName: fileName,
      bytes: utf8.encode(jsonText),
      dialogTitle: 'Export app backup',
    );
    return jsonEncode({
      ...saveResult,
      'backupSummary': _summarizeBackupJson(jsonText),
      'note':
          'Backup content was saved to the client device. Secrets and API keys are omitted from the exported file.',
    });
  }

  Future<String> _clientImportAppBackup(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Importing an app backup requires user approval.',
      });
    }
    final picked = await clientSystemToolService.pickFile(
      allowedExtensions: const ['json'],
      dialogTitle: 'Import app backup',
    );
    if (picked == null) {
      return jsonEncode({
        'execution': 'client',
        'target': 'app_backup',
        'imported': false,
        'cancelled': true,
        'note': 'The user cancelled the local file picker.',
      });
    }
    final jsonText = utf8.decode(picked.bytes);
    final summary = _summarizeBackupJson(jsonText);
    await storageService.importAppDataJson(jsonText);
    return jsonEncode({
      'execution': 'client',
      'target': 'app_backup',
      'imported': true,
      'cancelled': false,
      'fileName': picked.name,
      'bytes': picked.bytes.length,
      'summary': summary,
      'credentialFieldsIgnored': true,
    });
  }

  Future<String> _clientWebViewGetPageText(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    final chatId = clientWebViewSessionId;
    final maxChars = service._optionalInt(arguments, 'maxChars') ??
        ClientWebViewService.defaultMaxChars;
    if (chatId == null || chatId.trim().isEmpty) {
      return jsonEncode(_missingChatSessionPayload());
    }
    final result = await clientWebViewService.readPlainText(
      chatId,
      maxChars: maxChars,
    );
    return jsonEncode(result.toJson());
  }

  Future<String> _clientWebViewGetState(
      AiToolService service, Map<String, dynamic> arguments) async {
    final chatId = clientWebViewSessionId;
    if (chatId == null || chatId.trim().isEmpty) {
      return jsonEncode(_missingChatSessionPayload());
    }
    return jsonEncode((await clientWebViewService.getState(chatId)).toJson());
  }

  Future<String> _clientWebViewNavigate(
      AiToolService service, Map<String, dynamic> arguments) async {
    final chatId = clientWebViewSessionId;
    if (chatId == null || chatId.trim().isEmpty) {
      return jsonEncode(_missingChatSessionPayload());
    }
    final result = await clientWebViewService.navigate(
      chatId,
      action: service._arg(arguments, 'action'),
      input: service._optionalString(arguments, 'input'),
    );
    return jsonEncode(result.toJson());
  }

  Map<String, dynamic> _missingChatSessionPayload() {
    return {
      'execution': 'client',
      'target': 'client_webview',
      'provider': 'local_webview',
      'hasPage': false,
      'error':
          'No current chat session is bound to this tool call. Open or use the WebView from the current AI chat first.',
    };
  }

  Map<String, dynamic> _summarizeBackupJson(String jsonText) {
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != 'ssh_mobile_backup') {
      throw StateError('Unsupported backup file.');
    }
    final connections = (decoded['connections'] as List<dynamic>? ?? const []);
    final aiSettings = decoded['aiSettings'] as Map<String, dynamic>?;
    final hasCredentialFields =
        connections.whereType<Map<String, dynamic>>().any(
                  (item) =>
                      (item['password'] as String?)?.isNotEmpty == true ||
                      (item['privateKey'] as String?)?.isNotEmpty == true,
                ) ||
            ((aiSettings?['apiKey'] as String?)?.isNotEmpty == true);
    return {
      'format': decoded['format'],
      'version': decoded['version'],
      'exportedAt': decoded['exportedAt'],
      'connections': connections.length,
      'restorableTmuxSessions':
          (decoded['restorableTmuxSessions'] as List<dynamic>? ?? const [])
              .length,
      'terminalHistoryRecords':
          (decoded['terminalHistoryRecords'] as List<dynamic>? ?? const [])
              .length,
      'aiChats': (decoded['aiChats'] as List<dynamic>? ?? const []).length,
      'aiSkills': (decoded['aiSkills'] as List<dynamic>? ?? const []).length,
      'hasAiSettings': aiSettings != null,
      'credentialFieldsIgnored': hasCredentialFields,
    };
  }

  Future<String> _appGetOperationalSettings(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    final settings = await storageService.loadAiConnectionSettings();
    return jsonEncode({
      'sftpDownloadLimitBytes': service.appSettings?.sftpDownloadLimitBytes ??
          AppSettings.defaultSftpDownloadLimitBytes,
      'sftpTextEditLimitBytes': service.appSettings?.sftpTextEditLimitBytes ??
          AppSettings.defaultSftpTextEditLimitBytes,
      'secretCacheEnabled': storageService.isSecretCacheEnabled,
      'secretCacheTtlMinutes': storageService.secretCacheTtlMinutes,
      'aiRequestTimeoutSeconds': settings.timeoutSeconds,
      'webSearchEnabled': settings.webSearchEnabled,
      'webSearchMaxResults': settings.webSearchMaxResults,
      'webSearchEngine': settings.webSearchEngine,
      'quarkSearchEndpoint': settings.quarkSearchEndpoint,
      'multiAgentEnabled': settings.multiAgentEnabled,
      'multiAgentMaxAgents': settings.multiAgentMaxAgents,
      'toolCallBudget': settings.toolCallBudget,
      'hasApiKeyConfigured': settings.hasApiKey,
    });
  }

  Future<String> _appUpdateOperationalSettings(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error':
            'Updating app settings requires user approval before execution.',
      });
    }

    final current = await storageService.loadAiConnectionSettings();
    final nextDownloadLimit =
        service._optionalInt(arguments, 'sftpDownloadLimitBytes');
    if (nextDownloadLimit != null && service.appSettings != null) {
      await service.appSettings!.setSftpDownloadLimitBytes(nextDownloadLimit);
    }
    final nextEditLimit =
        service._optionalInt(arguments, 'sftpTextEditLimitBytes');
    if (nextEditLimit != null && service.appSettings != null) {
      await service.appSettings!.setSftpTextEditLimitBytes(nextEditLimit);
    }

    final secretCacheEnabled =
        service._optionalBool(arguments, 'secretCacheEnabled');
    if (secretCacheEnabled != null) {
      await storageService.setSecretCacheEnabled(secretCacheEnabled);
    }

    final secretCacheTtlMinutes =
        service._optionalInt(arguments, 'secretCacheTtlMinutes');
    if (secretCacheTtlMinutes != null) {
      await storageService.setSecretCacheTtl(
        Duration(minutes: secretCacheTtlMinutes),
      );
    }

    final aiRequestTimeoutSeconds =
        service._optionalInt(arguments, 'aiRequestTimeoutSeconds');
    final webSearchEnabled =
        service._optionalBool(arguments, 'webSearchEnabled');
    final webSearchMaxResults =
        service._optionalInt(arguments, 'webSearchMaxResults');
    final multiAgentEnabled =
        service._optionalBool(arguments, 'multiAgentEnabled');
    final multiAgentMaxAgents =
        service._optionalInt(arguments, 'multiAgentMaxAgents');
    final toolCallBudget = service._optionalInt(arguments, 'toolCallBudget');

    await storageService.saveAiConnectionSettings(
      baseUrl: current.baseUrl,
      model: current.model,
      contextWindowTokens: current.contextWindowTokens,
      timeoutSeconds: aiRequestTimeoutSeconds ?? current.timeoutSeconds,
      deepSeekThinkingEnabled: current.deepSeekThinkingEnabled,
      deepSeekReasoningEffort: current.deepSeekReasoningEffort,
      openAiReasoningEffort: current.openAiReasoningEffort,
      webSearchEnabled: webSearchEnabled ?? current.webSearchEnabled,
      webSearchMaxResults: webSearchMaxResults ?? current.webSearchMaxResults,
      multiAgentEnabled: multiAgentEnabled ?? current.multiAgentEnabled,
      multiAgentMaxAgents: multiAgentMaxAgents ?? current.multiAgentMaxAgents,
      toolCallBudget: toolCallBudget ?? current.toolCallBudget,
    );

    return await _appGetOperationalSettings(service, arguments);
  }

  Future<String> _appClearSecretCache(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    storageService.clearSecretCache();
    return jsonEncode({
      'execution': 'client',
      'cleared': true,
      'note': 'In-memory secret cache was cleared successfully.',
    });
  }

  Future<String> _clientSetPlanMode(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    final chatId = clientWebViewSessionId;
    if (chatId == null || chatId.trim().isEmpty) {
      return jsonEncode({
        'error': 'No active chat session found for this client tool call.',
      });
    }

    final enabled = service._optionalBool(arguments, 'enabled') ?? true;
    final chats = await storageService.loadAiChats();
    final chatIndex = chats.indexWhere((c) => c.id == chatId);
    if (chatIndex == -1) {
      return jsonEncode({
        'error': 'Active chat record not found for id: $chatId',
      });
    }
    final currentChat = chats[chatIndex];

    if (!enabled && !canExitPlanMode(currentChat)) {
      return jsonEncode({
        'error': 'Cannot exit Plan Mode. You must persist executable TODO steps on the latest assistant planning message before switching to execution mode.',
      });
    }

    final updatedChat = currentChat.copyWith(
      planMode: enabled,
      updatedAt: DateTime.now(),
      clearApprovedPlan: enabled,
    );
    await storageService.saveAiChat(updatedChat);

    return jsonEncode({
      'status': 'success',
      'planMode': enabled,
      'message': enabled
          ? 'Successfully entered Plan Mode. State-mutating tools are restricted. Please diagnose and replan.'
          : 'Successfully exited Plan Mode. Now in execution mode. You can instruct the user to execute the TODO steps.',
    });
  }

  Future<String> _clientTaskCreate(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    final chatId = clientWebViewSessionId;
    if (chatId == null || chatId.trim().isEmpty) {
      return jsonEncode({'error': 'No active chat session found.'});
    }

    final chats = await storageService.loadAiChats();
    final chatIndex = chats.indexWhere((c) => c.id == chatId);
    if (chatIndex == -1) {
      return jsonEncode({'error': 'Active chat record not found.'});
    }
    final currentChat = chats[chatIndex];

    if (!currentChat.planMode) {
      return jsonEncode({
        'error': 'Task creation is blocked. client_task_create can ONLY be called during Plan Mode.',
      });
    }

    final name = service._arg(arguments, 'name');
    final command = service._optionalString(arguments, 'command') ?? '';
    final description = service._optionalString(arguments, 'description') ?? '';
    final connectionId = service._optionalString(arguments, 'connectionId');

    final messages = [...currentChat.messages];
    if (messages.isEmpty) {
      return jsonEncode({'error': 'No messages to bind the task to.'});
    }

    final assistantIndex = messages.lastIndexWhere((m) => m.role == 'assistant');
    if (assistantIndex == -1) {
      return jsonEncode({'error': 'No assistant message found to bind the task.'});
    }

    final targetMsg = messages[assistantIndex];
    final steps = [...targetMsg.todoSteps];

    final now = DateTime.now();
    final taskId = 'task-${now.microsecondsSinceEpoch}-${steps.length}';
    final newStep = AiTodoStep(
      id: taskId,
      name: name,
      command: command,
      description: description,
      status: StepStatus.pending,
      connectionId: connectionId,
    );
    steps.add(newStep);

    messages[assistantIndex] = targetMsg.copyWith(todoSteps: steps);
    final updatedChat = currentChat.copyWith(
      messages: messages,
      updatedAt: DateTime.now(),
    );
    await storageService.saveAiChat(updatedChat);

    return jsonEncode({
      'status': 'success',
      'taskId': taskId,
      'name': name,
      'command': command,
      'description': description,
      'message': 'Task step successfully created and appended to the plan list.',
    });
  }

  Future<String> _clientTaskUpdate(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    final chatId = clientWebViewSessionId;
    if (chatId == null || chatId.trim().isEmpty) {
      return jsonEncode({'error': 'No active chat session found.'});
    }

    final chats = await storageService.loadAiChats();
    final chatIndex = chats.indexWhere((c) => c.id == chatId);
    if (chatIndex == -1) {
      return jsonEncode({'error': 'Active chat record not found.'});
    }
    final currentChat = chats[chatIndex];

    if (currentChat.planMode) {
      return jsonEncode({
        'error': 'Task status update is blocked. client_task_update can ONLY be called during Execution Mode.',
      });
    }

    final taskId = service._arg(arguments, 'taskId');
    final rawStatus = service._arg(arguments, 'status');
    final stdout = service._optionalString(arguments, 'stdout');
    final stderr = service._optionalString(arguments, 'stderr');
    final nextStatus = _taskStatusFromRaw(rawStatus);

    bool foundAndUpdated = false;
    final messages = [...currentChat.messages];

    for (var mIdx = 0; mIdx < messages.length; mIdx++) {
      final msg = messages[mIdx];
      if (msg.todoSteps.isEmpty) continue;

      final sIdx = msg.todoSteps.indexWhere((s) => s.id == taskId);
      if (sIdx != -1) {
        final steps = [...msg.todoSteps];
        final currentStep = steps[sIdx];

        steps[sIdx] = currentStep.copyWith(
          status: nextStatus,
          stdout: stdout ?? currentStep.stdout,
          stderr: stderr ?? currentStep.stderr,
          exitCode: nextStatus == StepStatus.success
              ? 0
              : (nextStatus == StepStatus.failed ? 1 : currentStep.exitCode),
        );

        messages[mIdx] = msg.copyWith(todoSteps: steps);
        foundAndUpdated = true;
        break;
      }
    }

    if (!foundAndUpdated) {
      return jsonEncode({
        'error': 'Task step not found. No task with id: $taskId exists in this chat session.',
      });
    }

    final updatedChat = currentChat.copyWith(
      messages: messages,
      updatedAt: DateTime.now(),
    );
    await storageService.saveAiChat(updatedChat);

    return jsonEncode({
      'status': 'success',
      'taskId': taskId,
      'newStatus': nextStatus.name,
      'message': 'Task step successfully updated in the execution logs.',
    });
  }

  StepStatus _taskStatusFromRaw(String rawStatus) {
    final normalized = rawStatus.trim().toLowerCase();
    if (normalized == 'in_progress') {
      return StepStatus.running;
    }
    return StepStatus.values.firstWhere(
      (e) => e.name == normalized,
      orElse: () => StepStatus.pending,
    );
  }

  List<AiTool> _getClientTools(
    AiToolService service,
    AiConnectionSettings searchSettings,
  ) {
    final webSearchMaxResults = AiWebSearchMaxResults.normalize(
      searchSettings.webSearchMaxResults,
    );
    return [
      if (searchSettings.webSearchEnabled)
        AiTool(
          name: 'web_search',
          description:
              'Search the public web from the SSH Mobile client WebView bound to the current chat session. Return cited result URLs. Use this before answering questions about current, latest, news, or external information. Current app setting returns up to $webSearchMaxResults results by default.',
          properties: {
            'query': _string('Search query. Keep it concise.'),
            'limit': _int(
              'Maximum number of results to return. Omit this to use the current app setting of $webSearchMaxResults results.',
              minimum: 1,
              maximum: webSearchMaxResults,
              defaultValue: webSearchMaxResults,
            ),
          },
          required: const ['query'],
          handler: (args) => _webSearch(service, args),
        ),
      AiTool(
        name: 'client_get_time',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Get the client system time, UTC time, timezone, and locale.',
        properties: const {},
        handler: (_) async =>
            jsonEncode(clientSystemToolService.getClientTime()),
      ),
      AiTool(
        name: 'client_get_device_info',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Get client OS/platform, locale, timezone, hostname, CPU count, and supported client integrations.',
        properties: const {},
        handler: (_) async =>
            jsonEncode(clientSystemToolService.getClientDeviceInfo()),
      ),
      AiTool(
        name: 'client_get_network_info',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Get client network status such as connectivity, transport, Wi-Fi details where available, and proxy or VPN indicators.',
        properties: const {},
        handler: (_) async =>
            jsonEncode(await clientSystemToolService.getNetworkInfo()),
      ),
      AiTool(
        name: 'client_get_battery_status',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Get client battery level, charging state, battery saver, and app battery-optimization exemption status where available.',
        properties: const {},
        handler: (_) async =>
            jsonEncode(await clientSystemToolService.getBatteryStatus()),
      ),
      AiTool(
        name: 'client_get_permission_status',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Get client notification permission, background-service support, and Android battery-optimization exemption status where available.',
        properties: const {},
        handler: (_) async =>
            jsonEncode(await clientSystemToolService.getPermissionStatus()),
      ),
      AiTool(
        name: 'client_open_app_settings',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Open the operating system app settings page so the user can grant notifications, battery, or background permissions.',
        properties: const {},
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (_) async =>
            jsonEncode(await clientSystemToolService.openAppSettings()),
      ),
      AiTool(
        name: 'client_set_clipboard',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Copy text to the client clipboard.',
        properties: {
          'text': _string('Text to place on the client clipboard.'),
        },
        required: const ['text'],
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (args) => _clientSetClipboard(service, args),
      ),
      AiTool(
        name: 'client_save_experience_skill',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Save a summarized user experience into a local AI skill so it can be reused by future chats.',
        properties: {
          'summary': _string(
            'Mandatory summarized experience text. Keep it concise, ideally 1-3 short lines.',
          ),
          'title': _string(
            'Optional short skill title. If omitted, a title is generated automatically.',
          ),
          'content': _string(
            'Optional detailed content such as steps, caveats, commands, and lessons.',
          ),
        },
        required: const ['summary'],
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (args) => _clientSaveExperienceSkill(service, args),
      ),
      AiTool(
        name: 'client_set_alarm',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Set a client-side alarm or reminder.',
        properties: {
          'triggerAt': _string(
            'Optional local ISO-8601 datetime, or a 24-hour time like 08:30.',
          ),
          'delaySeconds': _int('Optional delay in seconds.'),
          'delayMinutes': _int('Optional delay in minutes.'),
          'label': _string('Optional alarm or reminder label.'),
          'useSystemAlarm': _bool(
            'Optional. Default true. On Android request a system Clock alarm when supported.',
          ),
        },
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (args) => _clientSetAlarm(service, args),
      ),
      AiTool(
        name: 'client_list_alarms',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. List in-app client reminders created by client_set_alarm during this app process.',
        properties: const {},
        handler: (_) async =>
            jsonEncode(await clientSystemToolService.listAlarms()),
      ),
      AiTool(
        name: 'client_cancel_alarm',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Cancel an in-app client reminder created by client_set_alarm.',
        properties: {
          'alarmId': _string('Alarm id returned by client_set_alarm.'),
        },
        required: const ['alarmId'],
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (args) => _clientCancelAlarm(service, args),
      ),
      AiTool(
        name: 'client_query_logs',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Read recent redacted app logs from this client for SSH, SFTP, LLM, AI tool, WebView, and background diagnostics.',
        properties: {
          'level': {
            'type': 'string',
            'enum': AppLogLevel.values.map((item) => item.name).toList(),
            'description': 'Optional log level filter. Defaults to all.',
          },
          'contains': _string(
            'Optional case-insensitive text filter that matches the redacted log text.',
          ),
          'limit': _int(
            'Maximum number of newest-first log entries to return. Defaults to 50.',
            minimum: 1,
            maximum: 200,
            defaultValue: 50,
          ),
        },
        handler: (args) => _clientQueryLogs(service, args),
      ),
      AiTool(
        name: 'client_get_log_counts',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Return redacted app log counts grouped by level.',
        properties: const {},
        handler: (_) async =>
            jsonEncode(await clientSystemToolService.getLogCounts()),
      ),
      AiTool(
        name: 'client_delete_log_entries',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Delete specific client log entries by id. This changes local app state and requires user approval.',
        properties: {
          'ids': _intArray('Log entry ids to delete.', minimumItems: 1),
        },
        required: const ['ids'],
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (arguments) => _clientDeleteLogEntries(
          service,
          arguments,
          approvedWrite: false,
        ),
      ),
      AiTool(
        name: 'client_clear_logs',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Clear all client log entries. This changes local app state and requires user approval.',
        properties: const {},
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (arguments) =>
            _clientClearLogs(service, arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'client_export_app_backup',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Export a credential-free app backup file to the client device. The tool saves the file locally and returns only summary metadata.',
        properties: const {},
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (args) => _clientExportAppBackup(service, args),
      ),
      AiTool(
        name: 'client_import_app_backup',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Import an app backup file chosen through the client file picker. Credential fields in the backup are ignored and never exposed to the model. This replaces local saved data and requires user approval.',
        properties: const {},
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (arguments) => _clientImportAppBackup(
          service,
          arguments,
          approvedWrite: false,
        ),
      ),
      AiTool(
        name: 'client_webview_get_page_text',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Read visible plain text from the WebView page bound to the current chat session.',
        properties: {
          'maxChars': _int(
            'Optional maximum characters to return. Defaults to 40000 and is capped at 100000.',
          ),
        },
        handler: (args) => _clientWebViewGetPageText(service, args),
      ),
      AiTool(
        name: 'client_webview_get_state',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Get the current WebView state for the page bound to this chat session.',
        properties: const {},
        handler: (args) => _clientWebViewGetState(service, args),
      ),
      AiTool(
        name: 'client_webview_navigate',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Navigate the current chat session WebView using open, back, forward, or refresh without interrupting an active AI-browsing lock.',
        properties: {
          'action': {
            'type': 'string',
            'enum': const ['open', 'back', 'forward', 'refresh'],
            'description': 'Navigation action to perform.',
          },
          'input': _string(
            'Required when action=open. Accepts an HTTP(S) URL or search query.',
          ),
        },
        required: const ['action'],
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (args) => _clientWebViewNavigate(service, args),
      ),
      AiTool(
        name: 'app_get_operational_settings',
        description:
            'Return app operational settings that affect tools and server operations, including SFTP limits, secret-cache settings, AI timeout, web-search settings, multi-agent settings, and the per-request tool call budget. Does not reveal API keys.',
        properties: const {},
        handler: (args) => _appGetOperationalSettings(service, args),
      ),
      AiTool(
        name: 'app_update_operational_settings',
        description:
            'Update app operational settings that affect tools and server operations, including SFTP limits, secret-cache settings, AI timeout, web-search settings, multi-agent settings, and the per-request tool call budget. This changes local app state and requires user approval.',
        properties: {
          'sftpDownloadLimitBytes':
              _int('Optional SFTP download limit in bytes.'),
          'sftpTextEditLimitBytes':
              _int('Optional SFTP text edit limit in bytes.'),
          'secretCacheEnabled':
              _bool('Optional in-memory secret cache enabled flag.'),
          'secretCacheTtlMinutes': _int(
            'Optional in-memory secret cache TTL in minutes.',
          ),
          'aiRequestTimeoutSeconds':
              _int('Optional AI request timeout in seconds.'),
          'webSearchEnabled': _bool('Optional AI web search enabled flag.'),
          'webSearchMaxResults': _int(
            'Optional AI web search max results setting.',
          ),
          'multiAgentEnabled':
              _bool('Optional automatic multi-agent collaboration flag.'),
          'multiAgentMaxAgents': _int(
            'Optional maximum helper agents for automatic multi-agent collaboration.',
            minimum: AiMultiAgentMaxAgents.values.first,
            maximum: AiMultiAgentMaxAgents.values.last,
          ),
          'toolCallBudget': _int(
            'Optional default per-request tool call budget before budget guardrails extend or audit the run.',
            minimum: AiToolCallBudget.values.first,
            maximum: AiToolCallBudget.values.last,
          ),
        },
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (arguments) => _appUpdateOperationalSettings(
          service,
          arguments,
          approvedWrite: false,
        ),
      ),
      AiTool(
        name: 'app_clear_secret_cache',
        description:
            'Clear the in-memory secret cache for saved SSH credentials and the active LLM API key without revealing any secret values.',
        properties: const {},
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (args) => _appClearSecretCache(service, args),
      ),
      AiTool(
        name: 'client_set_plan_mode',
        description:
            'CLIENT tool. Toggle Plan Mode for the active chat thread. Set enabled=true to enter read-only planning when you need to replan. Set enabled=false to exit to execution mode ONLY after you have outlined a structured step-by-step playbook plan beforehand.',
        properties: {
          'enabled': _bool('true to enter plan mode, false to exit to execution mode.'),
        },
        required: const ['enabled'],
        executionMode: AiToolExecutionMode.planControl,
        handler: (args) => _clientSetPlanMode(service, args),
      ),
      AiTool(
        name: 'client_task_create',
        description:
            'CLIENT tool. Create a new step in the TODO task plan. This tool is ONLY allowed during Plan Mode (read-only stage). Returns a generated unique taskId. Complex planning flows may also persist todoSteps from a valid ```playbook JSON block without calling this tool.',
        properties: {
          'name': _string('The name/title of the planned step.'),
          'command': _string('The exact shell/remote command recommended for execution in this step.'),
          'description': _string('The purpose or explanation of what this step accomplishes.'),
          'connectionId': _string('Optional. The unique connectionId of the server to execute this step on. Use list_servers to find available ids.'),
        },
        required: const ['name'],
        executionMode: AiToolExecutionMode.planOnly,
        handler: (args) => _clientTaskCreate(service, args),
      ),
      AiTool(
        name: 'client_task_update',
        description:
            'CLIENT tool. Update the execution status and output logs of a planned TODO task. This tool is ONLY allowed during Execution Mode, and only for pre-existing taskIds. Use running as the canonical in-progress status; the legacy alias in_progress is still accepted.',
        properties: {
          'taskId': _string('The unique taskId of the step to update.'),
          'status': {
            'type': 'string',
            'enum': const ['pending', 'running', 'success', 'failed', 'skipped'],
            'description': 'The new execution status of the step. The legacy alias in_progress is still accepted.',
          },
          'stdout': _string('Optional stdout log response from executing the command.'),
          'stderr': _string('Optional stderr log response if execution failed.'),
        },
        required: const ['taskId', 'status'],
        executionMode: AiToolExecutionMode.executionOnly,
        handler: (args) => _clientTaskUpdate(service, args),
      ),
    ];
  }
}
