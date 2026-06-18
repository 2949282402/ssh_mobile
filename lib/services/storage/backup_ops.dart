part of '../storage_service.dart';

extension BackupOps on StorageService {
  void addOnImportCallback(VoidCallback callback) {
    _onImportCallbacks.add(callback);
  }

  void removeOnImportCallback(VoidCallback callback) {
    _onImportCallbacks.remove(callback);
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
        'maxImageSizeBytes': settings.maxImageSizeBytes,
        'maxFileSizeBytes': settings.maxFileSizeBytes,
        'apiKey': '',
      },
      'appSettings': {
        'language': _prefs!.getString('app_language'),
        'themeMode': _prefs!.getString('theme_mode'),
        'darkMode': _prefs!.getBool('dark_mode'),
        'fontFamily': _prefs!.getString('font_family'),
        'sftpDownloadLimitBytes': _prefs!.getInt('sftp_download_limit_bytes'),
        'sftpTextPreviewLimitBytes':
            _prefs!.getInt('sftp_text_preview_limit_bytes'),
        'sftpRichPreviewLimitBytes':
            _prefs!.getInt('sftp_rich_preview_limit_bytes'),
        'sftpTextEditLimitBytes': _prefs!.getInt('sftp_text_edit_limit_bytes'),
      },
      'shortcutCommands': {
        'usage': _prefs!.getString('shortcut_command_usage'),
        'customCommands': _prefs!.getString('custom_shortcut_commands'),
        'order': _prefs!.getString('shortcut_command_order'),
      },
      'secretCache': {
        'enabled': _prefs!.getBool('secret_cache_enabled'),
        'ttlSeconds': _prefs!.getInt('secret_cache_ttl_seconds'),
      },
      'aiChats': (await loadAiChats()).map((item) => item.toJson()).toList(),
      'aiSkills': (await loadAiSkills()).map((item) => item.toJson()).toList(),
      'agentRunMetrics':
          (await loadAgentRunMetrics()).map((item) => item.toJson()).toList(),
      'playbooks':
          (await loadPlaybooks()).map((item) => item.toJson()).toList(),
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
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != 'ssh_mobile_backup') {
      throw StateError('Unsupported backup file.');
    }

    final importedConnections = <ConnectionConfig>[];
    for (final item in (decoded['connections'] as List<dynamic>? ?? const [])) {
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
        contextWindowTokens:
            (aiSettings['contextWindowTokens'] as num?)?.toInt(),
        timeoutSeconds: (aiSettings['timeoutSeconds'] as num?)?.toInt(),
        deepSeekThinkingEnabled: aiSettings['deepSeekThinkingEnabled'] as bool?,
        deepSeekReasoningEffort:
            aiSettings['deepSeekReasoningEffort'] as String?,
        openAiReasoningEffort: aiSettings['openAiReasoningEffort'] as String?,
        webSearchEnabled: aiSettings['webSearchEnabled'] as bool?,
        webSearchMaxResults:
            (aiSettings['webSearchMaxResults'] as num?)?.toInt(),
        webSearchEngine: aiSettings['webSearchEngine'] as String?,
        quarkSearchEndpoint: aiSettings['quarkSearchEndpoint'] as String?,
        multiAgentEnabled: aiSettings['multiAgentEnabled'] as bool?,
        multiAgentMaxAgents:
            (aiSettings['multiAgentMaxAgents'] as num?)?.toInt(),
        toolCallBudget: (aiSettings['toolCallBudget'] as num?)?.toInt(),
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
        await _prefs!
            .setString('app_language', appSettings['language'] as String);
      }
      if (appSettings['themeMode'] != null) {
        await _prefs!
            .setString('theme_mode', appSettings['themeMode'] as String);
      }
      if (appSettings['darkMode'] != null) {
        await _prefs!.setBool('dark_mode', appSettings['darkMode'] as bool);
      }
      if (appSettings['fontFamily'] != null) {
        await _prefs!
            .setString('font_family', appSettings['fontFamily'] as String);
      }
      if (appSettings['sftpDownloadLimitBytes'] != null) {
        await _prefs!.setInt('sftp_download_limit_bytes',
            (appSettings['sftpDownloadLimitBytes'] as num).toInt());
      }
      if (appSettings['sftpTextPreviewLimitBytes'] != null) {
        await _prefs!.setInt('sftp_text_preview_limit_bytes',
            (appSettings['sftpTextPreviewLimitBytes'] as num).toInt());
      }
      if (appSettings['sftpRichPreviewLimitBytes'] != null) {
        await _prefs!.setInt('sftp_rich_preview_limit_bytes',
            (appSettings['sftpRichPreviewLimitBytes'] as num).toInt());
      }
      if (appSettings['sftpTextEditLimitBytes'] != null) {
        await _prefs!.setInt('sftp_text_edit_limit_bytes',
            (appSettings['sftpTextEditLimitBytes'] as num).toInt());
      }
    }

    final shortcutCommands = decoded['shortcutCommands'];
    if (shortcutCommands is Map<String, dynamic>) {
      if (shortcutCommands['usage'] != null) {
        await _prefs!.setString(
            'shortcut_command_usage', shortcutCommands['usage'] as String);
      }
      if (shortcutCommands['customCommands'] != null) {
        await _prefs!.setString('custom_shortcut_commands',
            shortcutCommands['customCommands'] as String);
      }
      if (shortcutCommands['order'] != null) {
        await _prefs!.setString(
            'shortcut_command_order', shortcutCommands['order'] as String);
      }
    }

    final secretCache = decoded['secretCache'];
    if (secretCache is Map<String, dynamic>) {
      if (secretCache['enabled'] != null) {
        await _prefs!
            .setBool('secret_cache_enabled', secretCache['enabled'] as bool);
      }
      if (secretCache['ttlSeconds'] != null) {
        await _prefs!.setInt('secret_cache_ttl_seconds',
            (secretCache['ttlSeconds'] as num).toInt());
      }

      // Update in-memory values immediately
      _secretCacheEnabled =
          _prefs!.getBool(StorageService._secretCacheEnabledKey) ?? true;
      final ttlSeconds =
          _prefs!.getInt(StorageService._secretCacheTtlSecondsKey);
      if (ttlSeconds != null) {
        _secretCacheTtl =
            _normalizeSecretCacheTtl(Duration(seconds: ttlSeconds));
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
    await _saveAiChats(
      ((decoded['aiChats'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(AiChatRecord.fromJson)
          .toList(),
      immediate: true,
    );
    await _saveAiSkills(
      ((decoded['aiSkills'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(AiSkillRecord.fromJson)
          .toList(),
      immediate: true,
    );
    final importedMetrics =
        ((decoded['agentRunMetrics'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(AgentRunMetrics.fromJson)
            .toList();
    _agentRunMetricsCache = List.unmodifiable(importedMetrics);
    await _writeProtectedPrefBuffered(
      StorageService._agentRunMetricsKey,
      jsonEncode(importedMetrics.map((item) => item.toJson()).toList()),
      immediate: true,
    );
    await _savePlaybooks(
      ((decoded['playbooks'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(Playbook.fromJson)
          .toList(),
      immediate: true,
    );
    _powerGuideSeen = decoded['powerGuideSeen'] as bool? ?? _powerGuideSeen;
    await _prefs?.setBool(StorageService._powerGuideSeenKey, _powerGuideSeen);
    AppLogService.instance.info(
      'App data imported',
      details:
          'connections=${_connections.length} chats=${((decoded['aiChats'] as List<dynamic>?) ?? const []).length} skills=${((decoded['aiSkills'] as List<dynamic>?) ?? const []).length} playbooks=${((decoded['playbooks'] as List<dynamic>?) ?? const []).length}',
    );
    for (final callback in _onImportCallbacks) {
      try {
        callback();
      } catch (e) {
        AppLogService.instance
            .error('Error invoking import callback', error: e);
      }
    }
  }
}
