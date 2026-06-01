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
    } catch (e) {
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
}
