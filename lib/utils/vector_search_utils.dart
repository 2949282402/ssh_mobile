import 'dart:convert';
import 'package:http/http.dart' as http;

import '../services/app_log_service.dart';

/// 阿里云 DashScope (通义千问) 文本向量模型 API 客户端
class AliyunEmbeddingClient {
  static const String endpoint =
      'https://dashscope.aliyuncs.com/api/v1/services/embeddings/text-embedding';
  static const String modelName = 'text-embedding-v3';

  final String apiKey;

  const AliyunEmbeddingClient({required this.apiKey});

  /// 获取一组文本 of 1024 维语义向量列表。
  /// [textType] 可为 'document'（用于建库分块）或 'query'（用于查询检索）
  Future<List<List<double>>> getEmbeddings(
    List<String> texts, {
    String textType = 'document',
  }) async {
    if (texts.isEmpty) return const [];

    final startedAt = DateTime.now();

    try {
      final uri = Uri.parse(endpoint);
      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode({
              'model': modelName,
              'input': {'texts': texts},
              'parameters': {
                'text_type': textType,
              }
            }),
          )
          .timeout(const Duration(seconds: 30));

      final responseBody = response.body;

      if (response.statusCode < 200 || response.statusCode >= 300) {
        AppLogService.instance.warning(
          'Aliyun DashScope Embedding request failed',
          details: 'status=${response.statusCode} body=$responseBody',
        );
        throw StateError(
          'DashScope Embedding API error (${response.statusCode}): $responseBody',
        );
      }

      final decoded = jsonDecode(responseBody) as Map<String, dynamic>;
      final output = decoded['output'] as Map<String, dynamic>?;
      if (output == null) {
        throw StateError('Invalid DashScope response: missing "output" field.');
      }

      final rawEmbeddings = output['embeddings'] as List<dynamic>?;
      if (rawEmbeddings == null) {
        throw StateError(
          'Invalid DashScope response: missing "embeddings" list.',
        );
      }

      // 提取并转换向量（按原文本顺序 text_index 对应排列）
      final embeddings = List<List<double>>.filled(texts.length, const []);
      for (final item in rawEmbeddings) {
        if (item is Map<String, dynamic>) {
          final textIndex = item['text_index'] as int? ?? 0;
          final rawVector = item['embedding'] as List<dynamic>? ?? [];
          final vector =
              rawVector.map((val) => (val as num).toDouble()).toList();

          if (textIndex >= 0 && textIndex < embeddings.length) {
            embeddings[textIndex] = vector;
          }
        }
      }

      AppLogService.instance.info(
        'Aliyun DashScope Embedding fetched',
        details:
            'textsCount=${texts.length} elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds}',
      );

      return embeddings;
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Aliyun DashScope Embedding request error',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }
}

/// 向量运算辅助工具
class VectorMath {
  const VectorMath._();

  /// 计算两向量的点积 (通义千问 Embedding 向量已归一化，点积即代表余弦相似度)
  static double dotProduct(List<double> a, List<double> b) {
    if (a.isEmpty || b.isEmpty || a.length != b.length) return 0.0;
    var dot = 0.0;
    final len = a.length;
    for (var i = 0; i < len; i++) {
      dot += a[i] * b[i];
    }
    return dot;
  }
}

/// 双模检索重排融合引擎 (Reciprocal Rank Fusion)
class RrfMerger {
  const RrfMerger._();

  /// 融合 BM25 检索列表与向量语义检索列表。
  /// [k] 是 RRF 的常数平滑因子（标准设为 60）。
  /// 返回重新排序并赋予 RRF 合并得分的元素 ID 列表。
  static List<String> merge({
    required List<String> bm25Rank,
    required List<String> vectorRank,
    int k = 60,
  }) {
    final rrfScores = <String, double>{};

    // 1. 累加 BM25 的排名贡献
    for (var i = 0; i < bm25Rank.length; i++) {
      final docId = bm25Rank[i];
      final rank = i + 1;
      rrfScores[docId] = (rrfScores[docId] ?? 0.0) + (1.0 / (k + rank));
    }

    // 2. 累加向量检索的排名贡献
    for (var i = 0; i < vectorRank.length; i++) {
      final docId = vectorRank[i];
      final rank = i + 1;
      rrfScores[docId] = (rrfScores[docId] ?? 0.0) + (1.0 / (k + rank));
    }

    // 3. 排序
    final sortedEntries = rrfScores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return sortedEntries.map((entry) => entry.key).toList();
  }
}
