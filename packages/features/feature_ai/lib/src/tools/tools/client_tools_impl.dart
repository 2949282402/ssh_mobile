part of '../ai_tool_service.dart';

Future<String> _webSearch(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments,
) async {
  final runtimeSnapshot =
      service._runtimeConnectionSnapshot ??
      await provider.storageService.loadAiRuntimeConnectionSnapshot();
  final settings = runtimeSnapshot.settings;
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
      apiKey: runtimeSnapshot.quarkApiKey,
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
  required String apiKey,
}) async {
  if (apiKey.trim().isEmpty) {
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
      'parameter': {'top_k': limit},
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
            final url =
                (item['link'] as String?)?.trim() ??
                (item['url'] as String?)?.trim() ??
                '';
            final snippet =
                (item['snippet'] as String?)?.trim() ??
                (item['description'] as String?)?.trim() ??
                '';
            if (title.isNotEmpty && url.isNotEmpty) {
              results.add(
                ClientWebViewSearchItem(
                  title: title,
                  url: url,
                  snippet: snippet,
                ),
              );
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

int _webSearchLimit(
  ClientToolsProvider provider,
  Object? requestedLimit,
  AiConnectionSettings settings,
) {
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
