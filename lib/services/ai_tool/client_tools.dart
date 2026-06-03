part of '../ai_tool_service.dart';

extension _ClientTools on AiToolService {
  Future<String> _webSearch(Map<String, dynamic> arguments) async {
    final settings = await storageService.loadAiConnectionSettings();
    if (!settings.webSearchEnabled) {
      return jsonEncode({
        'execution': 'client',
        'target': 'client_webview',
        'provider': 'local_webview',
        'error': 'Web search is not enabled in LLM settings.',
      });
    }

    final query = _arg(arguments, 'query');
    final limit = _webSearchLimit(arguments['limit'], settings);

    if (settings.webSearchEngine == AiWebSearchEngine.quark) {
      final result = await _executeQuarkCloudSearch(
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

  Future<String> _clientSetAlarm(Map<String, dynamic> arguments) async {
    final result = await clientSystemToolService.setAlarm(
      triggerAt: _optionalString(arguments, 'triggerAt'),
      delaySeconds: _optionalInt(arguments, 'delaySeconds'),
      delayMinutes: _optionalInt(arguments, 'delayMinutes'),
      label: _optionalString(arguments, 'label'),
      useSystemAlarm: _optionalBool(arguments, 'useSystemAlarm') ?? true,
    );
    return jsonEncode(result);
  }

  Future<String> _clientCancelAlarm(Map<String, dynamic> arguments) async {
    return jsonEncode(
      await clientSystemToolService.cancelAlarm(_arg(arguments, 'alarmId')),
    );
  }

  Future<String> _clientSetClipboard(Map<String, dynamic> arguments) async {
    return jsonEncode(
      await clientSystemToolService.setClipboard(_arg(arguments, 'text')),
    );
  }

  Future<String> _clientSaveExperienceSkill(
    Map<String, dynamic> arguments,
  ) async {
    final summary = _arg(arguments, 'summary');
    final conciseSummary = _coerceConciseSkillSummary(summary);
    final title = _optionalString(arguments, 'title') ??
        _defaultExperienceSkillTitle(conciseSummary);
    final details = _optionalString(arguments, 'content');
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

  Future<String> _clientQueryLogs(Map<String, dynamic> arguments) async {
    final result = await clientSystemToolService.queryLogs(
      level: _optionalString(arguments, 'level'),
      contains: _optionalString(arguments, 'contains'),
      limit: _optionalInt(arguments, 'limit') ?? 50,
    );
    return jsonEncode(result);
  }

  Future<String> _clientDeleteLogEntries(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Deleting client log entries requires user approval.',
      });
    }
    final ids = _intList(arguments['ids']);
    return jsonEncode(await clientSystemToolService.deleteLogEntries(ids));
  }

  Future<String> _clientClearLogs(
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

  Future<String> _clientExportAppBackup(Map<String, dynamic> arguments) async {
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
    Map<String, dynamic> arguments,
  ) async {
    final chatId = clientWebViewSessionId;
    final maxChars = _optionalInt(arguments, 'maxChars') ??
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

  Future<String> _clientWebViewGetState(Map<String, dynamic> arguments) async {
    final chatId = clientWebViewSessionId;
    if (chatId == null || chatId.trim().isEmpty) {
      return jsonEncode(_missingChatSessionPayload());
    }
    return jsonEncode((await clientWebViewService.getState(chatId)).toJson());
  }

  Future<String> _clientWebViewNavigate(Map<String, dynamic> arguments) async {
    final chatId = clientWebViewSessionId;
    if (chatId == null || chatId.trim().isEmpty) {
      return jsonEncode(_missingChatSessionPayload());
    }
    final result = await clientWebViewService.navigate(
      chatId,
      action: _arg(arguments, 'action'),
      input: _optionalString(arguments, 'input'),
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

  List<AiTool> _getClientTools(AiConnectionSettings searchSettings) {
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
          handler: _webSearch,
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
        handler: _clientSetClipboard,
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
        handler: _clientSaveExperienceSkill,
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
        handler: _clientSetAlarm,
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
        handler: _clientCancelAlarm,
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
        handler: _clientQueryLogs,
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
        handler: (arguments) => _clientDeleteLogEntries(
          arguments,
          approvedWrite: false,
        ),
      ),
      AiTool(
        name: 'client_clear_logs',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Clear all client log entries. This changes local app state and requires user approval.',
        properties: const {},
        handler: (arguments) =>
            _clientClearLogs(arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'client_export_app_backup',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Export a credential-free app backup file to the client device. The tool saves the file locally and returns only summary metadata.',
        properties: const {},
        handler: _clientExportAppBackup,
      ),
      AiTool(
        name: 'client_import_app_backup',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Import an app backup file chosen through the client file picker. Credential fields in the backup are ignored and never exposed to the model. This replaces local saved data and requires user approval.',
        properties: const {},
        handler: (arguments) => _clientImportAppBackup(
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
        handler: _clientWebViewGetPageText,
      ),
      AiTool(
        name: 'client_webview_get_state',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Get the current WebView state for the page bound to this chat session.',
        properties: const {},
        handler: _clientWebViewGetState,
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
        handler: _clientWebViewNavigate,
      ),
      AiTool(
        name: 'app_get_operational_settings',
        description:
            'Return app operational settings that affect tools and server operations, including SFTP limits, secret-cache settings, AI timeout, web-search settings, and multi-agent settings. Does not reveal API keys.',
        properties: const {},
        handler: _appGetOperationalSettings,
      ),
      AiTool(
        name: 'app_update_operational_settings',
        description:
            'Update app operational settings that affect tools and server operations, including SFTP limits, secret-cache settings, AI timeout, web-search settings, and multi-agent settings. This changes local app state and requires user approval.',
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
        },
        handler: (arguments) => _appUpdateOperationalSettings(
          arguments,
          approvedWrite: false,
        ),
      ),
      AiTool(
        name: 'app_clear_secret_cache',
        description:
            'Clear the in-memory secret cache for saved SSH credentials and the active LLM API key without revealing any secret values.',
        properties: const {},
        handler: _appClearSecretCache,
      ),
    ];
  }
}
