// RAG 跨层和跨 Feature Contract。
//
// 这些接口让 RAG Package 不依赖 AppSettings、StorageService 或 AppLogService
// 的实现；AI 只获得检索能力，页面通过 Module/Route Scope 获得完整服务。

import 'package:flutter/foundation.dart';

import 'rag_models.dart';

/// RAG 使用的设置和敏感 API Key 能力。
abstract interface class RagSettingsPort implements Listenable {
  bool get isEnglish;

  RagSearchMode get searchMode;

  Future<String?> getAliyunApiKey();

  Future<void> saveAliyunApiKey(String key);
}

/// RAG 结构化日志能力；不得在日志中写入 API Key、原文或向量。
abstract interface class RagLoggerPort {
  void info(String message, {String? details});

  void warning(String message, {String? details});

  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  });
}

/// 文本向量能力；由 Module 注入，便于隔离网络实现和离线测试。
abstract interface class RagEmbeddingPort {
  Future<List<List<double>>> getEmbeddings(
    List<String> texts, {
    String textType,
  });
}

/// 创建向量客户端的工厂；API Key 只在调用边界内传递，不写入日志或数据库。
typedef RagEmbeddingFactory =
    RagEmbeddingPort Function({required String apiKey, RagLoggerPort? logger});

/// AI 使用的最小 RAG 检索 Contract。
abstract interface class RagCapability implements Listenable {
  Future<List<RagChunk>> retrieve(
    String query, {
    int limit,
    Set<String>? filterDocumentIds,
    String? searchMode,
    String? aliyunApiKey,
  });
}
