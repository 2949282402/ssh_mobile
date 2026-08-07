part of '../../ai_tool_service.dart';

Future<String> _clientQueryLogs(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments,
) async {
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
    await provider.clientSystemToolService.deleteLogEntries(ids),
  );
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

Future<String> _clientExportAppBackup(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments,
) async {
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
  final maxChars =
      service._optionalInt(arguments, 'maxChars') ??
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

Future<String> _clientWebViewGetState(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments,
) async {
  final chatId = provider.clientWebViewSessionId;
  if (chatId == null || chatId.trim().isEmpty) {
    return jsonEncode(_missingChatSessionPayload(provider));
  }
  return jsonEncode(
    (await provider.clientWebViewService.getState(chatId)).toJson(),
  );
}

Future<String> _clientWebViewNavigate(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments,
) async {
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

Map<String, dynamic> _missingChatSessionPayload(ClientToolsProvider provider) {
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
  ClientToolsProvider provider,
  String jsonText,
) {
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
    'playbooks': (decoded['playbooks'] as List<dynamic>? ?? const []).length,
    'hasAiSettings': aiSettings != null,
    'credentialFieldsIgnored': hasCredentialFields,
    'highRiskContent': _backupHighRiskSections(provider, decoded),
  };
}

List<String> _backupHighRiskSections(
  ClientToolsProvider provider,
  Map<String, dynamic> decoded,
) {
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
    'sftpDownloadLimitBytes':
        service.appSettings?.sftpDownloadLimitBytes ??
        AppSettings.defaultSftpDownloadLimitBytes,
    'sftpTextEditLimitBytes':
        service.appSettings?.sftpTextEditLimitBytes ??
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
  final nextDownloadLimit = service._optionalInt(
    arguments,
    'sftpDownloadLimitBytes',
  );
  if (nextDownloadLimit != null && service.appSettings != null) {
    await service.appSettings!.setSftpDownloadLimitBytes(nextDownloadLimit);
  }
  final nextEditLimit = service._optionalInt(
    arguments,
    'sftpTextEditLimitBytes',
  );
  if (nextEditLimit != null && service.appSettings != null) {
    await service.appSettings!.setSftpTextEditLimitBytes(nextEditLimit);
  }

  final secretCacheEnabled = service._optionalBool(
    arguments,
    'secretCacheEnabled',
  );
  if (secretCacheEnabled != null) {
    await provider.storageService.setSecretCacheEnabled(secretCacheEnabled);
  }

  final secretCacheTtlMinutes = service._optionalInt(
    arguments,
    'secretCacheTtlMinutes',
  );
  if (secretCacheTtlMinutes != null) {
    await provider.storageService.setSecretCacheTtl(
      Duration(minutes: secretCacheTtlMinutes),
    );
  }

  final aiRequestTimeoutSeconds = service._optionalInt(
    arguments,
    'aiRequestTimeoutSeconds',
  );
  final webSearchEnabled = service._optionalBool(arguments, 'webSearchEnabled');
  final webSearchMaxResults = service._optionalInt(
    arguments,
    'webSearchMaxResults',
  );
  final multiAgentEnabled = service._optionalBool(
    arguments,
    'multiAgentEnabled',
  );
  final multiAgentMaxAgents = service._optionalInt(
    arguments,
    'multiAgentMaxAgents',
  );
  final postToolReviewEnabled = service._optionalBool(
    arguments,
    'postToolReviewEnabled',
  );
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
