// App Shell 到 RAG Feature 的适配器。
//
// 这些适配器把 AppSettings、Secure Storage 和 AppLogService 转换为公开
// Contract；RAG Package 不直接依赖旧 App 实现，也不拥有这些资源。

import 'package:feature_rag/feature_rag.dart' as feature_rag;
import 'package:flutter/foundation.dart';

import '../services/app_log_service.dart';
import '../services/app_settings.dart';
import '../services/storage_service.dart';

/// 提供 RAG 所需的语言、搜索模式和 DashScope Key。
final class AppRagSettingsAdapter extends ChangeNotifier
    implements feature_rag.RagSettingsPort {
  AppRagSettingsAdapter(this._settings, this._storage) {
    _settings.addListener(notifyListeners);
  }

  final AppSettings _settings;
  final StorageService _storage;
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
