// RAG Package 测试替身。
//
// 测试使用内存数据库和临时缓存目录，不读取真实 API Key、平台目录或网络，
// 用来验证 Module/Repository 的边界和 Service 的本地检索行为。

import 'dart:io';

import 'package:feature_rag/feature_rag.dart';
import 'package:flutter/foundation.dart';

final class FakeRagSettings extends ChangeNotifier implements RagSettingsPort {
  FakeRagSettings({this.apiKey = '', this.mode = RagSearchMode.bm25});

  String apiKey;
  RagSearchMode mode;

  @override
  bool isEnglish = false;

  @override
  RagSearchMode get searchMode => mode;

  @override
  Future<String?> getAliyunApiKey() async => apiKey;

  @override
  Future<void> saveAliyunApiKey(String key) async {
    apiKey = key;
    notifyListeners();
  }
}

final class RecordingRagLogger implements RagLoggerPort {
  final List<String> messages = [];

  @override
  void info(String message, {String? details}) {
    messages.add('info:$message');
  }

  @override
  void warning(String message, {String? details}) {
    messages.add('warning:$message');
  }

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {
    messages.add('error:$message');
  }
}

/// 按关键词返回二维向量，验证 Service 的向量和混合检索而不访问网络。
final class FakeRagEmbedding implements RagEmbeddingPort {
  @override
  Future<List<List<double>>> getEmbeddings(
    List<String> texts, {
    String textType = 'document',
  }) async {
    return [
      for (final text in texts)
        text.toLowerCase().contains('nginx') ? const [1, 0] : const [0, 1],
    ];
  }
}

Future<RagCacheStore> createTestCacheStore({
  RagCachePolicy policy = const RagCachePolicy(),
}) async {
  final directory = await Directory.systemTemp.createTemp('rag-feature-test-');
  return RagCacheStore(policy: policy, directoryFactory: () async => directory);
}
