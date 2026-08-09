part of '../ai_storage_adapter.dart';

const int _maxBackupJsonChars = 10 * 1024 * 1024;
const int _maxBackupConnections = 200;
const int _maxBackupAiChats = 500;
const int _maxBackupAiSkills = 200;
const int _maxBackupPlaybooks = 200;
const int _maxBackupTerminalHistoryRecords = 500;
const int _maxBackupAgentRunMetrics = 1000;
const int _maxShortFieldChars = 128;
const int _maxHostChars = 255;
const int _maxChatMessageChars = 50000;

/// App 数据备份的导出/导入实现。
///
/// 备份只包含非敏感 Connection 快照和 AI/Terminal 元数据；密码、私钥、
/// API Key 及其安全存储引用永远不会进入 JSON。导入直接写入当前 Feature
/// Repository，不再依赖统一数据库，也不承诺旧数据库格式兼容。
extension AppBackupOps on AppAiStorageAdapter {
  /// 注册导入完成后的刷新回调。
  void addOnImportCallback(FutureOr<void> Function() callback) {
    registerOnImportCallback(callback);
  }

  /// 移除导入回调。
  void removeOnImportCallback(FutureOr<void> Function() callback) {
    unregisterOnImportCallback(callback);
  }

  Future<String> _exportAppDataJson() async {
    await init();
    final connectionPayloads = [
      for (final connection in connections)
        {...connection.toJson(), 'password': '', 'privateKey': ''},
    ];
    final settings = await loadAiConnectionSettings();
    final terminalHistory = await terminalMetadataStore
        .loadTerminalHistoryRecords();
    final payload = <String, dynamic>{
      'format': 'ssh_mobile_backup',
      'version': 3,
      'exportedAt': DateTime.now().toIso8601String(),
      'connections': connectionPayloads,
      'restorableTmuxSessions':
          (await terminalMetadataStore.loadRestorableTmuxSessions())
              .map((item) => item.toJson())
              .toList(growable: false),
      'terminalHistoryRecords': terminalHistory
          .map((item) => item.toJson())
          .toList(growable: false),
      'aiSettings': _settingsJson(settings),
      'appSettings': _preferenceJson(),
      'shortcutCommands': _shortcutJson(),
      'secretCache': {
        'enabled': isSecretCacheEnabled,
        'ttlSeconds': secretCacheTtl.inSeconds,
      },
      'aiChats': (await loadAiChats()).map((item) => item.toJson()).toList(),
      'aiSkills': (await loadAiSkills()).map((item) => item.toJson()).toList(),
      'agentRunMetrics': (await loadAgentRunMetrics())
          .map((item) => item.toJson())
          .toList(),
      'playbooks': (await loadPlaybooks())
          .map((item) => item.toJson())
          .toList(),
      'powerGuideSeen': powerGuideSeen,
    };
    AppLogService.instance.info(
      'App data exported',
      details:
          'connections=${connectionPayloads.length} chats=${(payload['aiChats'] as List).length} skills=${(payload['aiSkills'] as List).length} playbooks=${(payload['playbooks'] as List).length} secrets=omitted',
    );
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  Future<void> _importAppDataJson(String jsonText) async {
    await init();
    final decoded = _decodeAndValidateBackupJson(jsonText);
    final importedConnections = <ConnectionConfig>[];
    for (final item in _mapList(decoded['connections'])) {
      final config = ConnectionConfig.fromJson(item)
        ..password = null
        ..privateKey = null;
      importedConnections.add(config);
    }

    await deleteConnections(connections.map((item) => item.id));
    for (final connection in importedConnections) {
      await addConnection(connection);
    }

    await _importAiSettings(decoded['aiSettings']);
    await _importPreferences(decoded);
    // 模型列表是当前设备针对旧端点的运行时缓存，不属于备份数据；导入
    // 新配置后清除，避免页面继续展示与当前端点无关的模型。
    await clearCachedAiModels();
    await _importTerminalMetadata(decoded);
    await replaceAiChats([
      for (final item in _mapList(decoded['aiChats']))
        feature_ai.AiChatRecord.fromJson(item),
    ]);
    await _runExclusiveAiSkillOperation(
      () => _saveAiSkills([
        for (final item in _mapList(decoded['aiSkills']))
          feature_ai.AiSkillRecord.fromJson(item),
      ], immediate: true),
    );
    await replaceAgentRunMetrics([
      for (final item in _mapList(decoded['agentRunMetrics']))
        feature_ai.AgentRunMetrics.fromJson(item),
    ]);

    for (final existing in await loadPlaybooks()) {
      await deletePlaybook(existing.id);
    }
    for (final item in _mapList(decoded['playbooks'])) {
      await savePlaybook(feature_playbook.Playbook.fromJson(item));
    }

    for (final callback in List<FutureOr<void> Function()>.from(
      _onImportCallbacks,
    )) {
      await callback();
    }
    notifyStorageListeners();
    AppLogService.instance.info(
      'App data imported',
      details:
          'connections=${importedConnections.length} chats=${_mapList(decoded['aiChats']).length} skills=${_mapList(decoded['aiSkills']).length} playbooks=${_mapList(decoded['playbooks']).length}',
    );
  }

  Map<String, dynamic> _settingsJson(AiConnectionSettings settings) => {
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
    'quarkApiKey': '',
  };

  Map<String, dynamic> _preferenceJson() => {
    'language': _prefs?.getString('app_language'),
    'themeMode': _prefs?.getString('theme_mode'),
    'colorPalette': _prefs?.getString('color_palette'),
    'darkMode': _prefs?.getBool('dark_mode'),
    'fontFamily': _prefs?.getString('font_family'),
    'sftpDownloadLimitBytes': _prefs?.getInt('sftp_download_limit_bytes'),
    'sftpTextPreviewLimitBytes': _prefs?.getInt(
      'sftp_text_preview_limit_bytes',
    ),
    'sftpRichPreviewLimitBytes': _prefs?.getInt(
      'sftp_rich_preview_limit_bytes',
    ),
    'sftpTextEditLimitBytes': _prefs?.getInt('sftp_text_edit_limit_bytes'),
    'showServerNamesInNotifications': _prefs?.getBool(
      'show_server_names_in_notifications',
    ),
  };

  Map<String, dynamic> _shortcutJson() => {
    'usage': _prefs?.getString('shortcut_command_usage'),
    'customCommands': _prefs?.getString('custom_shortcut_commands'),
    'order': _prefs?.getString('shortcut_command_order'),
    'quickKeys': _prefs?.getString('terminal_keyboard_quick_keys'),
  };

  Future<void> _importAiSettings(Object? value) async {
    final settings = value is Map<String, dynamic>
        ? value
        : const <String, dynamic>{};
    await saveAiConnectionSettingsLegacy(
      baseUrl: settings['baseUrl'] as String? ?? 'https://api.deepseek.com',
      model: settings['model'] as String? ?? 'deepseek-v4-flash',
      helperModel: settings['helperModel'] as String?,
      auditModel: settings['auditModel'] as String?,
      modelFallbackPolicy: settings['modelFallbackPolicy'] as String?,
      contextWindowTokens: (settings['contextWindowTokens'] as num?)?.toInt(),
      timeoutSeconds: (settings['timeoutSeconds'] as num?)?.toInt(),
      deepSeekThinkingEnabled: settings['deepSeekThinkingEnabled'] as bool?,
      deepSeekReasoningEffort: settings['deepSeekReasoningEffort'] as String?,
      openAiReasoningEffort: settings['openAiReasoningEffort'] as String?,
      webSearchEnabled: settings['webSearchEnabled'] as bool?,
      webSearchMaxResults: (settings['webSearchMaxResults'] as num?)?.toInt(),
      webSearchEngine: settings['webSearchEngine'] as String?,
      quarkSearchEndpoint: settings['quarkSearchEndpoint'] as String?,
      multiAgentEnabled: settings['multiAgentEnabled'] as bool?,
      multiAgentMaxAgents: (settings['multiAgentMaxAgents'] as num?)?.toInt(),
      toolCallBudget: (settings['toolCallBudget'] as num?)?.toInt(),
      agentLoopMode: settings['agentLoopMode'] as String?,
      maxImageSizeBytes: (settings['maxImageSizeBytes'] as num?)?.toInt(),
      maxFileSizeBytes: (settings['maxFileSizeBytes'] as num?)?.toInt(),
      clearApiKey: true,
      clearQuarkApiKey: true,
    );
  }

  Future<void> _importPreferences(Map<String, dynamic> decoded) async {
    final prefs = _prefs!;
    final appSettings = decoded['appSettings'];
    if (appSettings is Map<String, dynamic>) {
      await _writeOptionalString(
        prefs,
        'app_language',
        appSettings['language'],
      );
      await _writeOptionalString(prefs, 'theme_mode', appSettings['themeMode']);
      await _writeOptionalString(
        prefs,
        'color_palette',
        appSettings['colorPalette'],
      );
      await _writeOptionalBool(prefs, 'dark_mode', appSettings['darkMode']);
      await _writeOptionalString(
        prefs,
        'font_family',
        appSettings['fontFamily'],
      );
      for (final key in const [
        'sftpDownloadLimitBytes',
        'sftpTextPreviewLimitBytes',
        'sftpRichPreviewLimitBytes',
        'sftpTextEditLimitBytes',
      ]) {
        final value = appSettings[key];
        if (value is num) {
          await prefs.setInt(_appPreferenceKey(key), value.toInt());
        }
      }
      await _writeOptionalBool(
        prefs,
        'show_server_names_in_notifications',
        appSettings['showServerNamesInNotifications'],
      );
    }
    final shortcuts = decoded['shortcutCommands'];
    if (shortcuts is Map<String, dynamic>) {
      await _writeOptionalString(
        prefs,
        'shortcut_command_usage',
        shortcuts['usage'],
      );
      await _writeOptionalString(
        prefs,
        'custom_shortcut_commands',
        shortcuts['customCommands'],
      );
      await _writeOptionalString(
        prefs,
        'shortcut_command_order',
        shortcuts['order'],
      );
      await _writeOptionalString(
        prefs,
        'terminal_keyboard_quick_keys',
        shortcuts['quickKeys'],
      );
    }
    final secretCache = decoded['secretCache'];
    if (secretCache is Map<String, dynamic>) {
      await _writeOptionalBool(
        prefs,
        'secret_cache_enabled',
        secretCache['enabled'],
      );
      final ttl = secretCache['ttlSeconds'];
      if (ttl is num) {
        await prefs.setInt('secret_cache_ttl_seconds', ttl.toInt());
      }
      await _loadSecretCacheSettings();
    }
    if (decoded['powerGuideSeen'] is bool) {
      _powerGuideSeen = decoded['powerGuideSeen'] as bool;
      await prefs.setBool(
        AppAiStorageAdapter._powerGuideSeenKey,
        _powerGuideSeen,
      );
    }
  }

  Future<void> _importTerminalMetadata(Map<String, dynamic> decoded) async {
    final restorable = [
      for (final item in _mapList(decoded['restorableTmuxSessions']))
        RestorableTmuxSession.fromJson(item),
    ];
    await terminalMetadataStore.clearRestorableTmuxSessions();
    for (final item in restorable) {
      await terminalMetadataStore.saveRestorableTmuxSession(item);
    }
    await terminalMetadataStore.replaceTerminalHistoryRecords([
      for (final item in _mapList(decoded['terminalHistoryRecords']))
        TerminalHistoryRecord.fromJson(item),
    ]);
  }

  String _appPreferenceKey(String exportedKey) => switch (exportedKey) {
    'sftpDownloadLimitBytes' => 'sftp_download_limit_bytes',
    'sftpTextPreviewLimitBytes' => 'sftp_text_preview_limit_bytes',
    'sftpRichPreviewLimitBytes' => 'sftp_rich_preview_limit_bytes',
    'sftpTextEditLimitBytes' => 'sftp_text_edit_limit_bytes',
    _ => exportedKey,
  };

  Future<void> _writeOptionalString(
    SharedPreferences prefs,
    String key,
    Object? value,
  ) async {
    if (value is String) await prefs.setString(key, value);
  }

  Future<void> _writeOptionalBool(
    SharedPreferences prefs,
    String key,
    Object? value,
  ) async {
    if (value is bool) await prefs.setBool(key, value);
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
  if (decoded is! Map<String, dynamic> ||
      decoded['format'] != 'ssh_mobile_backup') {
    throw StateError('Unsupported backup file.');
  }
  final version = decoded['version'];
  if (version is! num || version < 1 || version > 3) {
    throw StateError('Unsupported backup version.');
  }
  final connections = decoded['connections'];
  if (connections is! List) {
    throw StateError('Backup connections must be a list.');
  }
  _checkListLimit(decoded, 'connections', _maxBackupConnections);
  _checkListLimit(decoded, 'aiChats', _maxBackupAiChats);
  _checkListLimit(decoded, 'aiSkills', _maxBackupAiSkills);
  _checkListLimit(decoded, 'playbooks', _maxBackupPlaybooks);
  _checkListLimit(
    decoded,
    'terminalHistoryRecords',
    _maxBackupTerminalHistoryRecords,
  );
  _checkListLimit(decoded, 'agentRunMetrics', _maxBackupAgentRunMetrics);
  for (final item in connections) {
    if (item is! Map<String, dynamic>) {
      throw StateError('Backup connections must contain objects.');
    }
    _requireString(item, 'id', _maxShortFieldChars);
    _requireString(item, 'name', _maxShortFieldChars);
    _requireString(item, 'host', _maxHostChars);
    _requireString(item, 'username', _maxShortFieldChars);
  }
  for (final item in _mapList(decoded['aiChats'])) {
    for (final message in _mapList(item['messages'])) {
      final text = message['text'];
      if (text is String && text.length > _maxChatMessageChars) {
        throw StateError('Backup chat message is too large.');
      }
    }
  }
  return decoded;
}

List<Map<String, dynamic>> _mapList(Object? value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (item is Map<String, dynamic>) item,
  ];
}

void _checkListLimit(Map<String, dynamic> json, String key, int limit) {
  final value = json[key];
  if (value is List && value.length > limit) {
    throw StateError('Backup $key contains too many items.');
  }
}

void _requireString(Map<String, dynamic> json, String key, int limit) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty || value.length > limit) {
    throw StateError('Backup $key is invalid.');
  }
}
