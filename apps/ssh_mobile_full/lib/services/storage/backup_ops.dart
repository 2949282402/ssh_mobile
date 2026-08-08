part of '../storage_service.dart';

const int _maxBackupJsonChars = 10 * 1024 * 1024;
const int _maxBackupConnections = 200;
const int _maxBackupAiChats = 500;
const int _maxBackupAiSkills = 200;
const int _maxBackupPlaybooks = 200;
const int _maxBackupTerminalHistoryRecords = 500;
const int _maxBackupAgentRunMetrics = 1000;
const int _maxBackupSftpPaths = 1000;
const int _maxShortFieldChars = 128;
const int _maxHostChars = 255;
const int _maxPromptChars = 20000;
const int _maxRemotePathChars = 2048;
const int _maxPlaybookContentChars = 100000;
const int _maxChatMessageChars = 50000;

extension BackupOps on StorageService {
  void addOnImportCallback(FutureOr<void> Function() callback) {
    registerOnImportCallback(callback);
  }

  void removeOnImportCallback(FutureOr<void> Function() callback) {
    unregisterOnImportCallback(callback);
  }

  Future<String> _exportAppDataJson() async {
    if (!_initialized || _prefs == null) {
      throw StateError('Storage service is not initialized yet.');
    }
    final connectionPayloads = <Map<String, dynamic>>[];
    for (final connection in _connections) {
      // Backup files are portable user data, not secret vaults. Keep credential
      // fields present but empty so imports know the user must reconfigure them.
      connectionPayloads.add({
        ...connection.toJson(),
        'password': '',
        'privateKey': '',
      });
    }
    final settings = await loadAiConnectionSettings();
    final sftpRecentPaths = <Map<String, dynamic>>[];
    final sftpFavoritePaths = <Map<String, dynamic>>[];
    for (final connection in _connections) {
      sftpRecentPaths.addAll(
        (await loadRecentPaths(
          connection.id,
        )).map((item) => item.toJson()).toList(),
      );
      sftpFavoritePaths.addAll(
        (await loadFavoritePaths(
          connection.id,
        )).map((item) => item.toJson()).toList(),
      );
    }
    final payload = {
      'format': 'ssh_mobile_backup',
      'version': 2,
      'exportedAt': DateTime.now().toIso8601String(),
      'connections': connectionPayloads,
      'restorableTmuxSessions': (await loadRestorableTmuxSessions())
          .map((item) => item.toJson())
          .toList(),
      'terminalHistoryRecords': (await loadTerminalHistoryRecords())
          .map((item) => item.toJson())
          .toList(),
      'aiSettings': {
        'baseUrl': settings.baseUrl,
        'model': settings.model,
        'helperModel': settings.helperModel,
        'auditModel': settings.auditModel,
        'modelFallbackPolicy': settings.modelFallbackPolicy,
        'contextWindowTokens': settings.contextWindowTokens,
        'timeoutSeconds': settings.timeoutSeconds,
        'deepSeekThinkingEnabled': settings.deepSeekThinkingEnabled,
        'deepSeekReasoningEffort': settings.deepSeekReasoningEffort,
        'openAiReasoningEffort': settings.openAiReasoningEffort,
        'webSearchEnabled': settings.webSearchEnabled,
        'webSearchMaxResults': settings.webSearchMaxResults,
        'webSearchEngine': settings.webSearchEngine,
        'quarkSearchEndpoint': settings.quarkSearchEndpoint,
        'multiAgentEnabled': settings.multiAgentEnabled,
        'multiAgentMaxAgents': settings.multiAgentMaxAgents,
        'toolCallBudget': settings.toolCallBudget,
        'agentLoopMode': settings.agentLoopMode,
        'maxImageSizeBytes': settings.maxImageSizeBytes,
        'maxFileSizeBytes': settings.maxFileSizeBytes,
        'apiKey': '',
      },
      'appSettings': {
        'language': _prefs!.getString('app_language'),
        'themeMode': _prefs!.getString('theme_mode'),
        'colorPalette': _prefs!.getString('color_palette'),
        'darkMode': _prefs!.getBool('dark_mode'),
        'fontFamily': _prefs!.getString('font_family'),
        'sftpDownloadLimitBytes': _prefs!.getInt('sftp_download_limit_bytes'),
        'sftpTextPreviewLimitBytes': _prefs!.getInt(
          'sftp_text_preview_limit_bytes',
        ),
        'sftpRichPreviewLimitBytes': _prefs!.getInt(
          'sftp_rich_preview_limit_bytes',
        ),
        'sftpTextEditLimitBytes': _prefs!.getInt('sftp_text_edit_limit_bytes'),
        'showServerNamesInNotifications': _prefs!.getBool(
          'show_server_names_in_notifications',
        ),
      },
      'shortcutCommands': {
        'usage': _prefs!.getString('shortcut_command_usage'),
        'customCommands': _prefs!.getString('custom_shortcut_commands'),
        'order': _prefs!.getString('shortcut_command_order'),
        'quickKeys': _prefs!.getString('terminal_keyboard_quick_keys'),
      },
      'secretCache': {
        'enabled': _prefs!.getBool('secret_cache_enabled'),
        'ttlSeconds': _prefs!.getInt('secret_cache_ttl_seconds'),
      },
      'aiChats': (await loadAiChats()).map((item) => item.toJson()).toList(),
      'aiSkills': (await loadAiSkills()).map((item) => item.toJson()).toList(),
      'agentRunMetrics': (await loadAgentRunMetrics())
          .map((item) => item.toJson())
          .toList(),
      'playbooks': (await loadPlaybooks())
          .map((item) => item.toJson())
          .toList(),
      'sftpRecentPaths': sftpRecentPaths,
      'sftpFavoritePaths': sftpFavoritePaths,
      'powerGuideSeen': _powerGuideSeen,
    };
    AppLogService.instance.info(
      'App data exported',
      details:
          'connections=${connectionPayloads.length} chats=${(payload['aiChats'] as List).length} skills=${(payload['aiSkills'] as List).length} playbooks=${(payload['playbooks'] as List).length} secrets=omitted',
    );
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  Future<void> _importAppDataJson(String jsonText) async {
    if (!_initialized || _prefs == null) {
      throw StateError('Storage service is not initialized yet.');
    }
    final decoded = _decodeAndValidateBackupJson(jsonText);

    await _runExclusiveConnectionOperation(() async {
      final importedConnections = <ConnectionConfig>[];
      for (final item
          in (decoded['connections'] as List<dynamic>? ?? const [])) {
        if (item is! Map<String, dynamic>) continue;
        final config = ConnectionConfig.fromJson(item);
        importedConnections.add(config);
        _clearSecretCacheForConnection(config.id);
        await _deleteSecure('pwd_${config.id}');
        await _deleteSecure('key_${config.id}');
      }

      for (final old in _connections) {
        if (importedConnections.any((item) => item.id == old.id)) continue;
        _clearSecretCacheForConnection(old.id);
        await _deleteSecure('pwd_${old.id}');
        await _deleteSecure('key_${old.id}');
      }
      _connections = importedConnections;
      _refreshConnectionsView();
      await _saveConnections();
    });
    await clearCachedAiModels();
    await _writeStringListPref(StorageService._aiBaseUrlHistoryKey, const []);

    final aiSettings = decoded['aiSettings'];
    if (aiSettings is Map<String, dynamic>) {
      // Backups are not a credential transport. Clear any current cached key
      // and ignore hand-edited or legacy apiKey values from imported files.
      await saveAiConnectionSettings(
        baseUrl: aiSettings['baseUrl'] as String? ?? 'https://api.deepseek.com',
        model: aiSettings['model'] as String? ?? 'deepseek-v4-flash',
        helperModel: aiSettings['helperModel'] as String?,
        auditModel: aiSettings['auditModel'] as String?,
        modelFallbackPolicy: aiSettings['modelFallbackPolicy'] as String?,
        contextWindowTokens: (aiSettings['contextWindowTokens'] as num?)
            ?.toInt(),
        timeoutSeconds: (aiSettings['timeoutSeconds'] as num?)?.toInt(),
        deepSeekThinkingEnabled: aiSettings['deepSeekThinkingEnabled'] as bool?,
        deepSeekReasoningEffort:
            aiSettings['deepSeekReasoningEffort'] as String?,
        openAiReasoningEffort: aiSettings['openAiReasoningEffort'] as String?,
        webSearchEnabled: aiSettings['webSearchEnabled'] as bool?,
        webSearchMaxResults: (aiSettings['webSearchMaxResults'] as num?)
            ?.toInt(),
        webSearchEngine: aiSettings['webSearchEngine'] as String?,
        quarkSearchEndpoint: aiSettings['quarkSearchEndpoint'] as String?,
        multiAgentEnabled: aiSettings['multiAgentEnabled'] as bool?,
        multiAgentMaxAgents: (aiSettings['multiAgentMaxAgents'] as num?)
            ?.toInt(),
        toolCallBudget: (aiSettings['toolCallBudget'] as num?)?.toInt(),
        agentLoopMode: aiSettings['agentLoopMode'] as String?,
        maxImageSizeBytes: (aiSettings['maxImageSizeBytes'] as num?)?.toInt(),
        maxFileSizeBytes: (aiSettings['maxFileSizeBytes'] as num?)?.toInt(),
      );
      await _clearAiApiKeySecret();
      await _deleteSecure(StorageService._quarkApiKeySecureKey);
    } else {
      await _clearAiApiKeySecret();
      await _deleteSecure(StorageService._quarkApiKeySecureKey);
    }

    final appSettings = decoded['appSettings'];
    if (appSettings is Map<String, dynamic>) {
      if (appSettings['language'] != null) {
        await _prefs!.setString(
          'app_language',
          appSettings['language'] as String,
        );
      }
      if (appSettings['themeMode'] != null) {
        await _prefs!.setString(
          'theme_mode',
          appSettings['themeMode'] as String,
        );
      }
      if (appSettings['colorPalette'] != null) {
        await _prefs!.setString(
          'color_palette',
          appSettings['colorPalette'] as String,
        );
      }
      if (appSettings['darkMode'] != null) {
        await _prefs!.setBool('dark_mode', appSettings['darkMode'] as bool);
      }
      if (appSettings['fontFamily'] != null) {
        await _prefs!.setString(
          'font_family',
          appSettings['fontFamily'] as String,
        );
      }
      if (appSettings['sftpDownloadLimitBytes'] != null) {
        await _prefs!.setInt(
          'sftp_download_limit_bytes',
          (appSettings['sftpDownloadLimitBytes'] as num).toInt(),
        );
      }
      if (appSettings['sftpTextPreviewLimitBytes'] != null) {
        await _prefs!.setInt(
          'sftp_text_preview_limit_bytes',
          (appSettings['sftpTextPreviewLimitBytes'] as num).toInt(),
        );
      }
      if (appSettings['sftpRichPreviewLimitBytes'] != null) {
        await _prefs!.setInt(
          'sftp_rich_preview_limit_bytes',
          (appSettings['sftpRichPreviewLimitBytes'] as num).toInt(),
        );
      }
      if (appSettings['sftpTextEditLimitBytes'] != null) {
        await _prefs!.setInt(
          'sftp_text_edit_limit_bytes',
          (appSettings['sftpTextEditLimitBytes'] as num).toInt(),
        );
      }
      if (appSettings['showServerNamesInNotifications'] != null) {
        await _prefs!.setBool(
          'show_server_names_in_notifications',
          appSettings['showServerNamesInNotifications'] as bool,
        );
      }
    }

    final shortcutCommands = decoded['shortcutCommands'];
    if (shortcutCommands is Map<String, dynamic>) {
      if (shortcutCommands['usage'] != null) {
        await _prefs!.setString(
          'shortcut_command_usage',
          shortcutCommands['usage'] as String,
        );
      }
      if (shortcutCommands['customCommands'] != null) {
        await _prefs!.setString(
          'custom_shortcut_commands',
          shortcutCommands['customCommands'] as String,
        );
      }
      if (shortcutCommands['order'] != null) {
        await _prefs!.setString(
          'shortcut_command_order',
          shortcutCommands['order'] as String,
        );
      }
      if (shortcutCommands['quickKeys'] != null) {
        await _prefs!.setString(
          'terminal_keyboard_quick_keys',
          shortcutCommands['quickKeys'] as String,
        );
      }
    }

    final secretCache = decoded['secretCache'];
    if (secretCache is Map<String, dynamic>) {
      if (secretCache['enabled'] != null) {
        await _prefs!.setBool(
          'secret_cache_enabled',
          secretCache['enabled'] as bool,
        );
      }
      if (secretCache['ttlSeconds'] != null) {
        await _prefs!.setInt(
          'secret_cache_ttl_seconds',
          (secretCache['ttlSeconds'] as num).toInt(),
        );
      }

      // Update in-memory values immediately
      _secretCacheEnabled =
          _prefs!.getBool(StorageService._secretCacheEnabledKey) ?? true;
      final ttlSeconds = _prefs!.getInt(
        StorageService._secretCacheTtlSecondsKey,
      );
      if (ttlSeconds != null) {
        _secretCacheTtl = _normalizeSecretCacheTtl(
          Duration(seconds: ttlSeconds),
        );
      } else {
        _secretCacheTtl = StorageService._defaultSecretCacheTtl;
      }
    }

    await _saveRestorableTmuxSessions(
      ((decoded['restorableTmuxSessions'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(RestorableTmuxSession.fromJson)
          .toList(),
      immediate: true,
    );
    await _saveTerminalHistoryRecords(
      ((decoded['terminalHistoryRecords'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(TerminalHistoryRecord.fromJson)
          .toList(),
      immediate: true,
    );
    await replaceAiChats(
      ((decoded['aiChats'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(AiChatRecord.fromJson)
          .toList(),
    );
    final importedAiSkills =
        ((decoded['aiSkills'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(AiSkillRecord.fromJson)
            .toList();
    await _runExclusiveAiSkillOperation(
      () => _saveAiSkills(importedAiSkills, immediate: true),
    );
    final importedMetrics =
        ((decoded['agentRunMetrics'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(AgentRunMetrics.fromJson)
            .toList();
    await replaceAgentRunMetrics(importedMetrics);
    final importedPlaybooks =
        ((decoded['playbooks'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(Playbook.fromJson)
            .toList();
    await _runExclusivePlaybookOperation(
      () => _savePlaybooks(importedPlaybooks, immediate: true),
    );
    await _replaceDriftSftpPathHistory(
      recentPaths: ((decoded['sftpRecentPaths'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(SftpRecentPathRecord.fromJson)
          .toList(),
      favoritePaths:
          ((decoded['sftpFavoritePaths'] as List<dynamic>?) ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(SftpFavoritePathRecord.fromJson)
              .toList(),
    );
    _powerGuideSeen = decoded['powerGuideSeen'] as bool? ?? _powerGuideSeen;
    await _prefs?.setBool(StorageService._powerGuideSeenKey, _powerGuideSeen);
    AppLogService.instance.info(
      'App data imported',
      details:
          'connections=${_connections.length} chats=${((decoded['aiChats'] as List<dynamic>?) ?? const []).length} skills=${((decoded['aiSkills'] as List<dynamic>?) ?? const []).length} playbooks=${((decoded['playbooks'] as List<dynamic>?) ?? const []).length} highRisk=${_backupHighRiskSections(decoded).join(',')}',
    );
  }
}

Map<String, dynamic> _decodeAndValidateBackupJson(String jsonText) {
  if (jsonText.length > _maxBackupJsonChars) {
    throw StateError('Backup file is too large.');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(jsonText);
  } catch (_) {
    throw StateError('Malformed backup JSON.');
  }
  if (decoded is! Map<String, dynamic>) {
    throw StateError('Unsupported backup file.');
  }
  if (decoded['format'] != 'ssh_mobile_backup') {
    throw StateError('Unsupported backup file.');
  }
  final version = decoded['version'];
  if (version is! num || version < 1 || version > 2) {
    throw StateError('Unsupported backup version.');
  }
  _validateBackupSchema(decoded);
  return decoded;
}

void _validateBackupSchema(Map<String, dynamic> decoded) {
  final connections = _requiredList(decoded, 'connections');
  _checkCount('connections', connections, _maxBackupConnections);
  for (final item in connections) {
    if (item is! Map<String, dynamic>) {
      throw StateError('Backup connections must contain objects.');
    }
    _requireString(item, 'id', _maxShortFieldChars);
    _requireString(item, 'name', _maxShortFieldChars);
    _requireString(item, 'host', _maxHostChars);
    _requireString(item, 'username', _maxShortFieldChars);
    _optionalStringLimit(item, 'jumpHost', _maxHostChars);
    _optionalStringLimit(item, 'jumpUsername', _maxShortFieldChars);
    _optionalStringLimit(item, 'group', _maxShortFieldChars);
    item['password'] = '';
    item['privateKey'] = '';
  }

  final aiSettings = decoded['aiSettings'];
  if (aiSettings != null && aiSettings is! Map<String, dynamic>) {
    throw StateError('Backup aiSettings must be an object.');
  }
  if (aiSettings is Map<String, dynamic>) {
    _optionalStringLimit(aiSettings, 'baseUrl', 2048);
    _optionalStringLimit(aiSettings, 'model', 256);
    _optionalStringLimit(aiSettings, 'helperModel', 256);
    _optionalStringLimit(aiSettings, 'auditModel', 256);
    _optionalStringLimit(aiSettings, 'agentLoopMode', _maxShortFieldChars);
    _optionalStringLimit(aiSettings, 'customSystemPrompt', _maxPromptChars);
    _optionalStringLimit(aiSettings, 'customPlannerPrompt', _maxPromptChars);
    _optionalStringLimit(aiSettings, 'customOperatorPrompt', _maxPromptChars);
    _optionalStringLimit(aiSettings, 'customExplorePrompt', _maxPromptChars);
    _optionalStringLimit(aiSettings, 'customReviewerPrompt', _maxPromptChars);
    _optionalStringLimit(aiSettings, 'customSummarizerPrompt', _maxPromptChars);
    _optionalStringLimit(
      aiSettings,
      'customCoordinatorPrompt',
      _maxPromptChars,
    );
    aiSettings['apiKey'] = '';
    aiSettings['quarkApiKey'] = '';
  }

  final appSettings = decoded['appSettings'];
  if (appSettings != null && appSettings is! Map<String, dynamic>) {
    throw StateError('Backup appSettings must be an object.');
  }
  if (appSettings is Map<String, dynamic>) {
    _optionalStringLimit(appSettings, 'language', _maxShortFieldChars);
    _optionalStringLimit(appSettings, 'themeMode', _maxShortFieldChars);
    _optionalStringLimit(appSettings, 'colorPalette', _maxShortFieldChars);
    _optionalStringLimit(appSettings, 'fontFamily', _maxShortFieldChars);
    _optionalBool(appSettings, 'darkMode');
    _optionalBool(appSettings, 'showServerNamesInNotifications');
  }

  final shortcuts = decoded['shortcutCommands'];
  if (shortcuts != null && shortcuts is! Map<String, dynamic>) {
    throw StateError('Backup shortcutCommands must be an object.');
  }
  if (shortcuts is Map<String, dynamic>) {
    _optionalStringLimit(shortcuts, 'usage', _maxPromptChars);
    _optionalStringLimit(shortcuts, 'customCommands', _maxPlaybookContentChars);
    _optionalStringLimit(shortcuts, 'order', _maxPromptChars);
    _optionalStringLimit(shortcuts, 'quickKeys', _maxPromptChars);
  }

  _validateOptionalList(
    decoded,
    'restorableTmuxSessions',
    _maxBackupTerminalHistoryRecords,
  );
  final terminalHistory = _validateOptionalList(
    decoded,
    'terminalHistoryRecords',
    _maxBackupTerminalHistoryRecords,
  );
  for (final item in terminalHistory) {
    if (item is Map<String, dynamic>) {
      _optionalStringLimit(item, 'displayName', _maxShortFieldChars);
      _optionalStringLimit(item, 'connectionName', _maxShortFieldChars);
      _optionalStringLimit(item, 'errorMessage', _maxPromptChars);
    }
  }

  final aiChats = _validateOptionalList(decoded, 'aiChats', _maxBackupAiChats);
  for (final chat in aiChats) {
    if (chat is! Map<String, dynamic>) {
      throw StateError('Backup aiChats must contain objects.');
    }
    _requireString(chat, 'id', _maxShortFieldChars);
    _optionalStringLimit(chat, 'title', _maxShortFieldChars);
    final messages = chat['messages'];
    if (messages != null && messages is! List) {
      throw StateError('Backup chat messages must be a list.');
    }
    for (final message in (messages as List<dynamic>? ?? const [])) {
      if (message is! Map<String, dynamic>) {
        throw StateError('Backup chat messages must contain objects.');
      }
      _optionalStringLimit(message, 'text', _maxChatMessageChars);
      _optionalStringLimit(message, 'contextText', _maxChatMessageChars);
    }
  }

  final skills = _validateOptionalList(decoded, 'aiSkills', _maxBackupAiSkills);
  for (final skill in skills) {
    if (skill is! Map<String, dynamic>) {
      throw StateError('Backup aiSkills must contain objects.');
    }
    _requireString(skill, 'id', _maxShortFieldChars);
    _optionalStringLimit(skill, 'name', _maxShortFieldChars);
    _optionalStringLimit(skill, 'description', _maxPromptChars);
    _optionalStringLimit(skill, 'content', _maxPlaybookContentChars);
  }

  _validateOptionalList(decoded, 'agentRunMetrics', _maxBackupAgentRunMetrics);

  final playbooks = _validateOptionalList(
    decoded,
    'playbooks',
    _maxBackupPlaybooks,
  );
  for (final playbook in playbooks) {
    if (playbook is! Map<String, dynamic>) {
      throw StateError('Backup playbooks must contain objects.');
    }
    _requireString(playbook, 'id', _maxShortFieldChars);
    _optionalStringLimit(playbook, 'name', _maxShortFieldChars);
    _optionalStringLimit(playbook, 'description', _maxPromptChars);
    final steps = playbook['steps'];
    if (steps != null && steps is! List) {
      throw StateError('Backup playbook steps must be a list.');
    }
    for (final step in (steps as List<dynamic>? ?? const [])) {
      if (step is! Map<String, dynamic>) {
        throw StateError('Backup playbook steps must contain objects.');
      }
      _optionalStringLimit(step, 'name', _maxShortFieldChars);
      _optionalStringLimit(step, 'command', _maxPlaybookContentChars);
      _optionalStringLimit(step, 'description', _maxPromptChars);
    }
  }

  final sftpRecentPaths = _validateOptionalList(
    decoded,
    'sftpRecentPaths',
    _maxBackupSftpPaths,
  );
  for (final path in sftpRecentPaths) {
    if (path is! Map<String, dynamic>) {
      throw StateError('Backup sftpRecentPaths must contain objects.');
    }
    _requireString(path, 'connectionId', _maxShortFieldChars);
    _requireString(path, 'path', _maxRemotePathChars);
  }

  final sftpFavoritePaths = _validateOptionalList(
    decoded,
    'sftpFavoritePaths',
    _maxBackupSftpPaths,
  );
  for (final path in sftpFavoritePaths) {
    if (path is! Map<String, dynamic>) {
      throw StateError('Backup sftpFavoritePaths must contain objects.');
    }
    _requireString(path, 'connectionId', _maxShortFieldChars);
    _requireString(path, 'path', _maxRemotePathChars);
    _optionalStringLimit(path, 'name', _maxShortFieldChars);
  }
}

List<dynamic> _requiredList(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value is! List) {
    throw StateError('Backup $key must be a list.');
  }
  return value;
}

List<dynamic> _validateOptionalList(
  Map<String, dynamic> map,
  String key,
  int maxCount,
) {
  final value = map[key];
  if (value == null) return const [];
  if (value is! List) {
    throw StateError('Backup $key must be a list.');
  }
  _checkCount(key, value, maxCount);
  return value;
}

void _checkCount(String key, List<dynamic> value, int maxCount) {
  if (value.length > maxCount) {
    throw StateError('Backup $key exceeds the supported item limit.');
  }
}

void _requireString(Map<String, dynamic> map, String key, int maxChars) {
  final value = map[key];
  if (value is! String || value.trim().isEmpty) {
    throw StateError('Backup $key must be a non-empty string.');
  }
  if (value.length > maxChars) {
    throw StateError('Backup $key is too long.');
  }
}

void _optionalStringLimit(Map<String, dynamic> map, String key, int maxChars) {
  final value = map[key];
  if (value == null) return;
  if (value is! String) {
    throw StateError('Backup $key must be a string.');
  }
  if (value.length > maxChars) {
    throw StateError('Backup $key is too long.');
  }
}

void _optionalBool(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value != null && value is! bool) {
    throw StateError('Backup $key must be a boolean.');
  }
}

List<String> _backupHighRiskSections(Map<String, dynamic> decoded) {
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
  if (aiSettings is Map<String, dynamic> &&
      (aiSettings['useCustomPrompts'] == true ||
          _hasNonEmptyCustomPrompt(aiSettings))) {
    sections.add('customPrompts');
  }
  return sections;
}

bool _hasNonEmptyCustomPrompt(Map<String, dynamic> aiSettings) {
  const keys = [
    'customSystemPrompt',
    'customPlannerPrompt',
    'customOperatorPrompt',
    'customExplorePrompt',
    'customReviewerPrompt',
    'customSummarizerPrompt',
    'customCoordinatorPrompt',
  ];
  return keys.any((key) {
    final value = aiSettings[key];
    return value is String && value.trim().isNotEmpty;
  });
}
