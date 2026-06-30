part of '../../ai_tool_service.dart';

Future<String> _webSearch(ClientToolsProvider provider, AiToolService service,
    Map<String, dynamic> arguments) async {
  final settings = await provider.storageService.loadAiConnectionSettings();
  if (!settings.webSearchEnabled) {
    return jsonEncode({
      'execution': 'client',
      'target': 'client_webview',
      'provider': 'local_webview',
      'error': 'Web search is not enabled in LLM settings.',
    });
  }

  final query = service._arg(arguments, 'query');
  final limit = _webSearchLimit(provider, arguments['limit'], settings);

  if (settings.webSearchEngine == AiWebSearchEngine.quark) {
    final result = await _executeQuarkCloudSearch(
      provider,
      service,
      query,
      limit: limit,
      settings: settings,
    );
    return jsonEncode(result.toJson());
  }

  final chatId = provider.clientWebViewSessionId;
  if (chatId == null || chatId.trim().isEmpty) {
    return jsonEncode(_missingChatSessionPayload(provider));
  }
  final result = await provider.clientWebViewService.searchWeb(
    chatId,
    query,
    maxResults: limit,
    engine: settings.webSearchEngine,
  );
  return jsonEncode(result.toJson());
}

Future<ClientWebViewSearchResult> _executeQuarkCloudSearch(
  ClientToolsProvider provider,
  AiToolService service,
  String query, {
  required int limit,
  required AiConnectionSettings settings,
}) async {
  final apiKey = await provider.storageService.getQuarkApiKey();
  if (apiKey == null || apiKey.trim().isEmpty) {
    return ClientWebViewSearchResult(
      chatId: provider.clientWebViewSessionId ?? 'cloud',
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
        chatId: provider.clientWebViewSessionId ?? 'cloud',
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
      chatId: provider.clientWebViewSessionId ?? 'cloud',
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
      chatId: provider.clientWebViewSessionId ?? 'cloud',
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

int _webSearchLimit(ClientToolsProvider provider, Object? requestedLimit,
    AiConnectionSettings settings) {
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

Future<String> _clientSetAlarm(ClientToolsProvider provider,
    AiToolService service, Map<String, dynamic> arguments) async {
  final result = await provider.clientSystemToolService.setAlarm(
    triggerAt: service._optionalString(arguments, 'triggerAt'),
    delaySeconds: service._optionalInt(arguments, 'delaySeconds'),
    delayMinutes: service._optionalInt(arguments, 'delayMinutes'),
    label: service._optionalString(arguments, 'label'),
    useSystemAlarm: service._optionalBool(arguments, 'useSystemAlarm') ?? true,
  );
  return jsonEncode(result);
}

Future<String> _clientCancelAlarm(ClientToolsProvider provider,
    AiToolService service, Map<String, dynamic> arguments) async {
  return jsonEncode(
    await provider.clientSystemToolService
        .cancelAlarm(service._arg(arguments, 'alarmId')),
  );
}

Future<String> _clientSetClipboard(ClientToolsProvider provider,
    AiToolService service, Map<String, dynamic> arguments) async {
  return jsonEncode(
    await provider.clientSystemToolService
        .setClipboard(service._arg(arguments, 'text')),
  );
}

Future<String> _clientSaveExperienceSkill(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments, {
  required bool approvedWrite,
}) async {
  if (!approvedWrite) {
    return jsonEncode({
      'error': 'Saving a local skill requires user approval before execution.',
    });
  }

  final summary = service._arg(arguments, 'summary');
  final title = service._optionalString(arguments, 'title');
  final details = service._optionalString(arguments, 'content');

  final rawRefs = arguments['references'];
  final inputReferences = <SkillReferenceItem>[];
  if (rawRefs is List) {
    for (final item in rawRefs) {
      if (item is Map) {
        final t = (item['title'] as String?)?.trim() ?? '';
        final c = (item['content'] as String?)?.trim() ?? '';
        inputReferences.add(SkillReferenceItem(title: t, content: c));
      }
    }
  }

  final buildResult = provider.skillDomainService.buildCreateSkill(
    title: title,
    summary: summary,
    content: details == null || details.trim().isEmpty
        ? null
        : '$summary\n\n${details.trim()}',
    references: inputReferences,
  );

  final now = DateTime.now();
  final record = AiSkillRecord(
    id: 'skill-${now.microsecondsSinceEpoch}',
    name: buildResult.name,
    description: buildResult.description,
    content: buildResult.content,
    enabled: true,
    references: buildResult.references,
    createdAt: now,
    updatedAt: now,
  );
  await provider.storageService.saveAiSkill(record);
  AppLogService.instance.info(
    'AI experience skill saved',
    details:
        'skillId=${record.id} name=${provider.secretPolicy.previewText(record.name)}',
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

Future<String> _clientListSkills(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments,
) async {
  final skills = await provider.storageService.loadAiSkills();
  return jsonEncode({
    'execution': 'client',
    'target': 'local_skill',
    'skills': skills.map((s) => s.toJson()).toList(),
  });
}

Future<String> _clientUpdateSkill(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments, {
  required bool approvedWrite,
}) async {
  if (!approvedWrite) {
    return jsonEncode({
      'error':
          'Updating a local skill requires user approval before execution.',
    });
  }
  final skillId = service._arg(arguments, 'skillId');
  final name = service._optionalString(arguments, 'name');
  final description = service._optionalString(arguments, 'description');
  final content = service._optionalString(arguments, 'content');
  final enabled = service._optionalBool(arguments, 'enabled');
  final rawRefs = arguments['references'];

  final skills = await provider.storageService.loadAiSkills();
  final idx = skills.indexWhere((s) => s.id == skillId);
  if (idx == -1) {
    return jsonEncode({
      'error': 'Skill not found with id: $skillId',
    });
  }

  final current = skills[idx];
  List<SkillReferenceItem>? targetReferences;

  if (rawRefs is List) {
    targetReferences = [];
    for (final item in rawRefs) {
      if (item is Map) {
        final t = (item['title'] as String?)?.trim() ?? '';
        final c = (item['content'] as String?)?.trim() ?? '';
        targetReferences.add(SkillReferenceItem(title: t, content: c));
      }
    }
  }

  final buildResult = provider.skillDomainService.buildUpdateSkill(
    current,
    name: name,
    description: description,
    content: content,
    references: targetReferences,
  );

  final updated = current.copyWith(
    name: buildResult.name,
    description: buildResult.description,
    content: buildResult.content,
    enabled: enabled ?? current.enabled,
    references: buildResult.references,
    updatedAt: DateTime.now(),
  );

  await provider.storageService.saveAiSkill(updated);

  return jsonEncode({
    'execution': 'client',
    'target': 'local_skill',
    'updated': true,
    'skillId': updated.id,
    'name': updated.name,
    'description': updated.description,
    'enabled': updated.enabled,
  });
}

Future<String> _clientQueryLogs(ClientToolsProvider provider,
    AiToolService service, Map<String, dynamic> arguments) async {
  final result = await provider.clientSystemToolService.queryLogs(
    level: service._optionalString(arguments, 'level'),
    contains: service._optionalString(arguments, 'contains'),
    limit: service._optionalInt(arguments, 'limit') ?? 50,
  );
  return jsonEncode(result);
}

Future<String> _clientDeleteLogEntries(
  ClientToolsProvider provider,
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
  return jsonEncode(
      await provider.clientSystemToolService.deleteLogEntries(ids));
}

Future<String> _clientClearLogs(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments, {
  required bool approvedWrite,
}) async {
  if (!approvedWrite) {
    return jsonEncode({
      'error': 'Clearing client logs requires user approval.',
    });
  }
  return jsonEncode(await provider.clientSystemToolService.clearLogs());
}

Future<String> _clientExportAppBackup(ClientToolsProvider provider,
    AiToolService service, Map<String, dynamic> arguments) async {
  final jsonText = await provider.storageService.exportAppDataJson();
  final now = DateTime.now();
  final fileName =
      'ssh_mobile_backup_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}.json';
  final saveResult = await provider.clientSystemToolService.saveBytesToFile(
    fileName: fileName,
    bytes: utf8.encode(jsonText),
    dialogTitle: 'Export app backup',
  );
  return jsonEncode({
    ...saveResult,
    'backupSummary': _summarizeBackupJson(provider, jsonText),
    'note':
        'Backup content was saved to the client device. Secrets and API keys are omitted from the exported file.',
  });
}

Future<String> _clientImportAppBackup(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments, {
  required bool approvedWrite,
}) async {
  if (!approvedWrite) {
    return jsonEncode({
      'error': 'Importing an app backup requires user approval.',
    });
  }
  final picked = await provider.clientSystemToolService.pickFile(
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
  final summary = _summarizeBackupJson(provider, jsonText);
  await provider.storageService.importAppDataJson(jsonText);
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
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments,
) async {
  final chatId = provider.clientWebViewSessionId;
  final maxChars = service._optionalInt(arguments, 'maxChars') ??
      ClientWebViewService.defaultMaxChars;
  if (chatId == null || chatId.trim().isEmpty) {
    return jsonEncode(_missingChatSessionPayload(provider));
  }
  final result = await provider.clientWebViewService.readPlainText(
    chatId,
    maxChars: maxChars,
  );
  return jsonEncode(result.toJson());
}

Future<String> _clientWebViewGetState(ClientToolsProvider provider,
    AiToolService service, Map<String, dynamic> arguments) async {
  final chatId = provider.clientWebViewSessionId;
  if (chatId == null || chatId.trim().isEmpty) {
    return jsonEncode(_missingChatSessionPayload(provider));
  }
  return jsonEncode(
      (await provider.clientWebViewService.getState(chatId)).toJson());
}

Future<String> _clientWebViewNavigate(ClientToolsProvider provider,
    AiToolService service, Map<String, dynamic> arguments) async {
  final chatId = provider.clientWebViewSessionId;
  if (chatId == null || chatId.trim().isEmpty) {
    return jsonEncode(_missingChatSessionPayload(provider));
  }
  final result = await provider.clientWebViewService.navigate(
    chatId,
    action: service._arg(arguments, 'action'),
    input: service._optionalString(arguments, 'input'),
  );
  return jsonEncode(result.toJson());
}

Map<String, dynamic> _missingChatSessionPayload(
  ClientToolsProvider provider,
) {
  return {
    'execution': 'client',
    'target': 'client_webview',
    'provider': 'local_webview',
    'hasPage': false,
    'error':
        'No current chat session is bound to this tool call. Open or use the WebView from the current AI chat first.',
  };
}

Map<String, dynamic> _summarizeBackupJson(
    ClientToolsProvider provider, String jsonText) {
  final decoded = jsonDecode(jsonText);
  if (decoded is! Map<String, dynamic> ||
      decoded['format'] != 'ssh_mobile_backup') {
    throw StateError('Unsupported backup file.');
  }
  final connections = (decoded['connections'] as List<dynamic>? ?? const []);
  final aiSettings = decoded['aiSettings'] as Map<String, dynamic>?;
  final hasCredentialFields = connections.whereType<Map<String, dynamic>>().any(
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
    'playbooks': (decoded['playbooks'] as List<dynamic>? ?? const []).length,
    'hasAiSettings': aiSettings != null,
    'credentialFieldsIgnored': hasCredentialFields,
    'highRiskContent': _backupHighRiskSections(provider, decoded),
  };
}

List<String> _backupHighRiskSections(
    ClientToolsProvider provider, Map<String, dynamic> decoded) {
  final sections = <String>[];
  if ((decoded['playbooks'] as List<dynamic>? ?? const []).isNotEmpty) {
    sections.add('playbooks');
  }
  if ((decoded['aiSkills'] as List<dynamic>? ?? const []).isNotEmpty) {
    sections.add('aiSkills');
  }
  final shortcuts = decoded['shortcutCommands'];
  if (shortcuts is Map<String, dynamic> &&
      shortcuts.values.any((value) => value != null && '$value'.isNotEmpty)) {
    sections.add('shortcuts');
  }
  final aiSettings = decoded['aiSettings'];
  if (aiSettingsHasCustomPrompts(aiSettings)) {
    sections.add('customPrompts');
  }
  return sections;
}

bool aiSettingsHasCustomPrompts(Map<String, dynamic>? aiSettings) {
  if (aiSettings == null) return false;
  const keys = [
    'customSystemPrompt',
    'customPlannerPrompt',
    'customOperatorPrompt',
    'customExplorePrompt',
    'customReviewerPrompt',
    'customSummarizerPrompt',
    'customCoordinatorPrompt',
  ];
  return aiSettings['useCustomPrompts'] == true ||
      keys.any((key) {
        final value = aiSettings[key];
        return value is String && value.trim().isNotEmpty;
      });
}

Future<String> _appGetOperationalSettings(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments,
) async {
  final settings = await provider.storageService.loadAiConnectionSettings();
  return jsonEncode({
    'sftpDownloadLimitBytes': service.appSettings?.sftpDownloadLimitBytes ??
        AppSettings.defaultSftpDownloadLimitBytes,
    'sftpTextEditLimitBytes': service.appSettings?.sftpTextEditLimitBytes ??
        AppSettings.defaultSftpTextEditLimitBytes,
    'secretCacheEnabled': provider.storageService.isSecretCacheEnabled,
    'secretCacheTtlMinutes': provider.storageService.secretCacheTtlMinutes,
    'aiRequestTimeoutSeconds': settings.timeoutSeconds,
    'webSearchEnabled': settings.webSearchEnabled,
    'webSearchMaxResults': settings.webSearchMaxResults,
    'webSearchEngine': settings.webSearchEngine,
    'quarkSearchEndpoint': settings.quarkSearchEndpoint,
    'multiAgentEnabled': settings.multiAgentEnabled,
    'multiAgentMaxAgents': settings.multiAgentMaxAgents,
    'postToolReviewEnabled': settings.postToolReviewEnabled,
    'toolCallBudget': settings.toolCallBudget,
    'hasApiKeyConfigured': settings.hasApiKey,
  });
}

Future<String> _appUpdateOperationalSettings(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments, {
  required bool approvedWrite,
}) async {
  if (!approvedWrite) {
    return jsonEncode({
      'error': 'Updating app settings requires user approval before execution.',
    });
  }

  final current = await provider.storageService.loadAiConnectionSettings();
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
    await provider.storageService.setSecretCacheEnabled(secretCacheEnabled);
  }

  final secretCacheTtlMinutes =
      service._optionalInt(arguments, 'secretCacheTtlMinutes');
  if (secretCacheTtlMinutes != null) {
    await provider.storageService.setSecretCacheTtl(
      Duration(minutes: secretCacheTtlMinutes),
    );
  }

  final aiRequestTimeoutSeconds =
      service._optionalInt(arguments, 'aiRequestTimeoutSeconds');
  final webSearchEnabled = service._optionalBool(arguments, 'webSearchEnabled');
  final webSearchMaxResults =
      service._optionalInt(arguments, 'webSearchMaxResults');
  final multiAgentEnabled =
      service._optionalBool(arguments, 'multiAgentEnabled');
  final multiAgentMaxAgents =
      service._optionalInt(arguments, 'multiAgentMaxAgents');
  final postToolReviewEnabled =
      service._optionalBool(arguments, 'postToolReviewEnabled');
  final toolCallBudget = service._optionalInt(arguments, 'toolCallBudget');

  await provider.storageService.saveAiConnectionSettings(
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
    postToolReviewEnabled:
        postToolReviewEnabled ?? current.postToolReviewEnabled,
    toolCallBudget: toolCallBudget ?? current.toolCallBudget,
  );

  return await _appGetOperationalSettings(provider, service, arguments);
}

Future<String> _appClearSecretCache(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments,
) async {
  provider.storageService.clearSecretCache();
  return jsonEncode({
    'execution': 'client',
    'cleared': true,
    'note': 'In-memory secret cache was cleared successfully.',
  });
}

Future<String> _clientSetPlanMode(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments,
) async {
  final chatId = provider.clientWebViewSessionId;
  if (chatId == null || chatId.trim().isEmpty) {
    return jsonEncode({
      'error': 'No active chat session found for this client tool call.',
    });
  }

  final enabled = service._optionalBool(arguments, 'enabled') ?? true;
  final chats = await provider.storageService.loadAiChats();
  final chatIndex = chats.indexWhere((c) => c.id == chatId);
  if (chatIndex == -1) {
    return jsonEncode({
      'error': 'Active chat record not found for id: $chatId',
    });
  }
  final currentChat = chats[chatIndex];

  if (!enabled &&
      !canExitPlanMode(currentChat, actor: PlanModeExitActor.llmTool)) {
    final isZh = service.appSettings?.language == AppLanguage.zh;
    final errorMsg = isZh
        ? '无法退出规划模式。当前聊天没有可执行的 TODO 步骤。请先在最新的回复中输出包含 steps 的 ```playbook JSON 代码块，或使用 client_task_create 创建计划步骤。'
        : 'Cannot exit Plan Mode. This plan has no executable steps. Generate a valid ```playbook JSON block with steps in your latest reply, or create steps with client_task_create first.';
    return jsonEncode({
      'error': errorMsg,
    });
  }

  final updatedChat = currentChat.copyWith(
    planMode: enabled,
    updatedAt: DateTime.now(),
    clearApprovedPlan: enabled,
  );
  await provider.storageService.saveAiChat(updatedChat);

  return jsonEncode({
    'status': 'success',
    'planMode': enabled,
    'message': enabled
        ? 'Successfully entered Plan Mode. State-mutating tools are restricted. Please diagnose and replan.'
        : 'Successfully exited Plan Mode. Now in execution mode. You can instruct the user to execute the TODO steps.',
  });
}

Future<String> _clientTaskCreate(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments,
) async {
  final chatId = provider.clientWebViewSessionId;
  if (chatId == null || chatId.trim().isEmpty) {
    return jsonEncode({'error': 'No active chat session found.'});
  }

  final chats = await provider.storageService.loadAiChats();
  final chatIndex = chats.indexWhere((c) => c.id == chatId);
  if (chatIndex == -1) {
    return jsonEncode({'error': 'Active chat record not found.'});
  }
  final currentChat = chats[chatIndex];

  if (!currentChat.planMode) {
    return jsonEncode({
      'error':
          'Task creation is blocked. client_task_create can ONLY be called during Plan Mode.',
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
    return jsonEncode(
        {'error': 'No assistant message found to bind the task.'});
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
  await provider.storageService.saveAiChat(updatedChat);

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
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments,
) async {
  final chatId = provider.clientWebViewSessionId;
  if (chatId == null || chatId.trim().isEmpty) {
    return jsonEncode({'error': 'No active chat session found.'});
  }

  final chats = await provider.storageService.loadAiChats();
  final chatIndex = chats.indexWhere((c) => c.id == chatId);
  if (chatIndex == -1) {
    return jsonEncode({'error': 'Active chat record not found.'});
  }
  final currentChat = chats[chatIndex];

  if (currentChat.planMode) {
    return jsonEncode({
      'error':
          'Task status update is blocked. client_task_update can ONLY be called during Execution Mode.',
    });
  }

  final taskId = service._arg(arguments, 'taskId');
  final String rawStatus = service._arg(arguments, 'status').trim();
  final allowedStatuses = [
    'pending',
    'running',
    'in_progress',
    'success',
    'failed',
    'skipped'
  ];
  if (!allowedStatuses.contains(rawStatus.toLowerCase())) {
    return jsonEncode({
      'error': 'Unknown task status.',
      'code': 'invalid_task_status',
      'allowed': ['pending', 'running', 'success', 'failed', 'skipped']
    });
  }

  final nextStatus = _taskStatusFromRaw(provider, rawStatus);
  if (nextStatus == StepStatus.skipped) {
    final reason = service._optionalString(arguments, 'reason');
    if (reason == null || reason.trim().isEmpty) {
      return jsonEncode({
        'error': 'Skipping a task requires a reason.',
        'code': 'skip_reason_required'
      });
    }
  }

  final stdout = service._optionalString(arguments, 'stdout');
  final stderr = service._optionalString(arguments, 'stderr');
  final errorSummary = service._optionalString(arguments, 'errorSummary');

  bool foundAndUpdated = false;
  final messages = [...currentChat.messages];
  AiTodoStep? updatedStep;

  for (var mIdx = 0; mIdx < messages.length; mIdx++) {
    final msg = messages[mIdx];
    if (msg.todoSteps.isEmpty) continue;

    final sIdx = msg.todoSteps.indexWhere((s) => s.id == taskId);
    if (sIdx != -1) {
      final steps = [...msg.todoSteps];
      final currentStep = steps[sIdx];

      const planController = PlanExecutionController();
      final validation = planController.validateTransition(
        steps: steps,
        targetTaskId: taskId,
        nextStatus: nextStatus,
      );

      if (!validation.allowed) {
        return jsonEncode({
          'error':
              'Plan execution validation failed: ${validation.errorMessage}',
        });
      }

      final combinedStderr = [
        if (stderr?.trim().isNotEmpty == true) stderr!.trim(),
        if (errorSummary?.trim().isNotEmpty == true)
          'Error Summary: ${errorSummary!.trim()}',
      ].join('\n');

      steps[sIdx] = currentStep.copyWith(
        status: nextStatus,
        stdout: stdout ?? currentStep.stdout,
        stderr: combinedStderr.isNotEmpty ? combinedStderr : currentStep.stderr,
        exitCode: nextStatus == StepStatus.success
            ? 0
            : (nextStatus == StepStatus.failed ? 1 : currentStep.exitCode),
      );

      updatedStep = steps[sIdx];
      messages[mIdx] = msg.copyWith(todoSteps: steps);
      foundAndUpdated = true;
      break;
    }
  }

  if (!foundAndUpdated || updatedStep == null) {
    return jsonEncode({
      'error':
          'Task step not found. No task with id: $taskId exists in this chat session.',
    });
  }

  final updatedChat = currentChat.copyWith(
    messages: messages,
    updatedAt: DateTime.now(),
  );
  await provider.storageService.saveAiChat(updatedChat);

  return jsonEncode({
    'status': 'success',
    'taskId': taskId,
    'newStatus': nextStatus.name,
    'message': 'Task step successfully updated in the execution logs.',
    if (nextStatus == StepStatus.running) ...{
      if (updatedStep.command.trim().isNotEmpty)
        'expectedCommand': updatedStep.command,
      if (updatedStep.connectionId?.trim().isNotEmpty == true)
        'expectedConnectionId': updatedStep.connectionId,
    },
    if (nextStatus == StepStatus.failed) ...{
      'nextAction':
          'Stop execution and ask the user whether to retry, skip, or revise the plan.',
      'options': ['retry_current_step', 'skip_current_step', 'ask_user']
    }
  });
}

StepStatus _taskStatusFromRaw(ClientToolsProvider provider, String rawStatus) {
  final normalized = rawStatus.trim().toLowerCase();
  if (normalized == 'in_progress') {
    return StepStatus.running;
  }
  return StepStatus.values.firstWhere(
    (e) => e.name == normalized,
    orElse: () => StepStatus.pending,
  );
}

Future<String> _clientTaskRetry(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments,
) async {
  final chatId = provider.clientWebViewSessionId;
  if (chatId == null || chatId.trim().isEmpty) {
    return jsonEncode({'error': 'No active chat session found.'});
  }

  final chats = await provider.storageService.loadAiChats();
  final chatIndex = chats.indexWhere((c) => c.id == chatId);
  if (chatIndex == -1) {
    return jsonEncode({'error': 'Active chat record not found.'});
  }
  final currentChat = chats[chatIndex];

  if (currentChat.planMode) {
    return jsonEncode({
      'error': 'client_task_retry can ONLY be called during Execution Mode.',
    });
  }

  final taskId = service._arg(arguments, 'taskId');
  final reason = service._optionalString(arguments, 'reason');
  bool foundAndUpdated = false;
  final messages = [...currentChat.messages];

  for (var mIdx = 0; mIdx < messages.length; mIdx++) {
    final msg = messages[mIdx];
    if (msg.todoSteps.isEmpty) continue;

    final sIdx = msg.todoSteps.indexWhere((s) => s.id == taskId);
    if (sIdx != -1) {
      final steps = [...msg.todoSteps];
      final currentStep = steps[sIdx];

      if (currentStep.status != StepStatus.failed) {
        return jsonEncode({
          'error':
              'Only failed tasks can be retried. Current status is: ${currentStep.status.name}',
        });
      }

      steps[sIdx] = currentStep.copyWith(
        status: StepStatus.pending,
        stdout: '',
        stderr: '',
        exitCode: null,
      );

      messages[mIdx] = msg.copyWith(todoSteps: steps);
      foundAndUpdated = true;
      break;
    }
  }

  if (!foundAndUpdated) {
    return jsonEncode({
      'error': 'Task step not found: $taskId',
    });
  }

  final updatedChat = currentChat.copyWith(
    messages: messages,
    updatedAt: DateTime.now(),
  );
  await provider.storageService.saveAiChat(updatedChat);

  return jsonEncode({
    'status': 'success',
    'taskId': taskId,
    'newStatus': StepStatus.pending.name,
    'message': 'Task step successfully reset to pending for retry.',
    if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
  });
}

Future<String> _clientTaskSkip(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments, {
  required bool approvedWrite,
}) async {
  if (!approvedWrite) {
    return jsonEncode({
      'error': 'Skipping a task requires user approval.',
    });
  }
  final chatId = provider.clientWebViewSessionId;
  if (chatId == null || chatId.trim().isEmpty) {
    return jsonEncode({'error': 'No active chat session found.'});
  }

  final chats = await provider.storageService.loadAiChats();
  final chatIndex = chats.indexWhere((c) => c.id == chatId);
  if (chatIndex == -1) {
    return jsonEncode({'error': 'Active chat record not found.'});
  }
  final currentChat = chats[chatIndex];

  if (currentChat.planMode) {
    return jsonEncode({
      'error': 'client_task_skip can ONLY be called during Execution Mode.',
    });
  }

  final taskId = service._arg(arguments, 'taskId');
  final reason = service._arg(arguments, 'reason');
  if (reason.trim().isEmpty) {
    return jsonEncode({
      'error': 'Skipping a task requires a reason.',
      'code': 'skip_reason_required',
    });
  }

  bool foundAndUpdated = false;
  final messages = [...currentChat.messages];

  for (var mIdx = 0; mIdx < messages.length; mIdx++) {
    final msg = messages[mIdx];
    if (msg.todoSteps.isEmpty) continue;

    final sIdx = msg.todoSteps.indexWhere((s) => s.id == taskId);
    if (sIdx != -1) {
      final steps = [...msg.todoSteps];
      final currentStep = steps[sIdx];

      if (currentStep.status != StepStatus.pending &&
          currentStep.status != StepStatus.failed) {
        return jsonEncode({
          'error':
              'Only pending or failed tasks can be skipped. Current status is: ${currentStep.status.name}',
          'code': 'invalid_skip_state',
        });
      }

      steps[sIdx] = currentStep.copyWith(
        status: StepStatus.skipped,
        stdout: 'Skipped: $reason',
        exitCode: null,
      );

      messages[mIdx] = msg.copyWith(todoSteps: steps);
      foundAndUpdated = true;
      break;
    }
  }

  if (!foundAndUpdated) {
    return jsonEncode({
      'error': 'Task step not found: $taskId',
    });
  }

  final updatedChat = currentChat.copyWith(
    messages: messages,
    updatedAt: DateTime.now(),
  );
  await provider.storageService.saveAiChat(updatedChat);

  return jsonEncode({
    'status': 'success',
    'taskId': taskId,
    'newStatus': StepStatus.skipped.name,
    'message': 'Task step successfully marked as skipped.',
  });
}
