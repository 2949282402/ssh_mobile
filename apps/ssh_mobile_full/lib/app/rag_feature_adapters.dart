// App Shell 到 RAG Feature 的适配器。
//
// 这些适配器把 AppSettings、Secure Storage 和 AppLogService 转换为公开
// Contract；RAG Package 不直接依赖旧 App 实现，也不拥有这些资源。

import 'package:feature_rag/feature_rag.dart' as feature_rag;
import 'package:app_core/app_core.dart' as app_core;
import 'package:flutter/foundation.dart';

import '../services/app_log_service.dart';
import '../services/app_settings.dart';
import '../services/ai_storage_adapter.dart';

/// 提供 RAG 所需的语言、搜索模式和 DashScope Key。
final class AppRagSettingsAdapter extends ChangeNotifier
    implements feature_rag.RagSettingsPort {
  AppRagSettingsAdapter(this._settings, this._storage) {
    _settings.addListener(notifyListeners);
  }

  final AppSettings _settings;
  final AppAiStorageAdapter _storage;
  bool _disposed = false;

  @override
  bool get isEnglish => _settings.isEnglish;

  @override
  feature_rag.RagSearchMode get searchMode =>
      feature_rag.RagSearchMode.fromValue(_settings.ragSearchMode);

  @override
  Future<String?> getAliyunApiKey() => _storage.getAliyunApiKey();

  @override
  Future<void> saveAliyunApiKey(String key) => _storage.saveAliyunApiKey(key);

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _settings.removeListener(notifyListeners);
    super.dispose();
  }
}

/// 将 AppLogService 的结构化日志能力注入 RAG。
final class AppRagLoggerAdapter implements feature_rag.RagLoggerPort {
  const AppRagLoggerAdapter(this._logger);

  final AppLogService _logger;

  @override
  void info(String message, {String? details}) {
    _logger.info(message, details: details);
  }

  @override
  void warning(String message, {String? details}) {
    _logger.warning(message, details: details);
  }

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {
    _logger.error(
      message,
      error: error,
      stackTrace: stackTrace,
      details: details,
    );
  }
}

/// 将 RAG Feature 的检索结果转换为 Core AI Capability。
///
/// AI 只接收正文和稳定元数据，不获得 RagService、Repository 或缓存句柄，
/// 从而保持 Feature 之间通过 Contract 通信。
final class AppAiRagCapabilityAdapter implements app_core.RagCapability {
  const AppAiRagCapabilityAdapter(this._service);

  final feature_rag.RagCapability _service;

  @override
  Future<List<app_core.RagCapabilityChunk>> retrieve(
    app_core.RagQuery request,
  ) async {
    final chunks = await _service.retrieve(
      request.query,
      limit: request.limit,
      searchMode: request.searchMode,
      aliyunApiKey: request.apiKey,
    );
    return List.unmodifiable(
      chunks.map(
        (chunk) => app_core.RagCapabilityChunk(
          documentName: chunk.documentName,
          text: chunk.text,
          metadata: {
            'id': chunk.id,
            'documentId': chunk.documentId,
            'pageNumber': chunk.pageNumber,
            'charStartIndex': chunk.charStartIndex,
            'charEndIndex': chunk.charEndIndex,
            ...chunk.metadata,
          },
        ),
      ),
    );
  }
}
