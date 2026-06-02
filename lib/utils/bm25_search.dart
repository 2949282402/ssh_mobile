import 'dart:math' as math;
import 'text_chunker.dart';

class ScoredRagChunk {
  final RagChunk chunk;
  final double score;

  const ScoredRagChunk({
    required this.chunk,
    required this.score,
  });
}

/// 纯 Dart 实现的轻量级 BM25 搜索引擎。
/// 专为移动端文档检索优化，无需外部 C++/Native 依赖，完全离线计算。
/// 对英文/代码命令使用分词，对中文使用单字+双字（Bigram）混合分词，确保对专业运维术语、特定命令参数的高查准与高查全。
class Bm25SearchEngine {
  final double k1;
  final double b;

  // 倒排索引：term -> { chunkId -> termFrequency }
  final Map<String, Map<String, int>> invertedIndex = {};

  // 各分块文档的长度：chunkId -> tokenCount
  final Map<String, int> docLengths = {};

  // 全局分块映射：chunkId -> RagChunk
  final Map<String, RagChunk> chunks = {};

  // 总文档数
  int totalDocs = 0;

  // 平均文档长度
  double avgDocLength = 0.0;

  Bm25SearchEngine({
    this.k1 = 1.2,
    this.b = 0.75,
  });

  /// 清空索引
  void clear() {
    invertedIndex.clear();
    docLengths.clear();
    chunks.clear();
    totalDocs = 0;
    avgDocLength = 0.0;
  }

  /// 针对移动端运维场景的混合分词器。
  /// 支持英文字母、数字和特定符号（如命令参数 `-` 或 IP 地址 `.` 保持原样以提高搜索精度）。
  /// 中文采用 Unigram (单字) + Bigram (双字) 混合分词，彻底摆脱外部中文分词字典。
  List<String> tokenize(String text) {
    if (text.isEmpty) return const [];
    final cleanText = text.toLowerCase();
    final tokens = <String>[];

    // 按标点符号和空格分块，但保留特殊字符（如中文字符，英文单词，数字）
    // RegExp 匹配中文字符：[一-龥]
    // 匹配英文和数字单词：[a-z0-9_-]+ (允许中划线/下划线作为命令一部分，例如 `apt-get`, `systemctl`)
    final matches = RegExp(r'[a-z0-9_\-\.]+|(?:[一-龥]+)').allMatches(cleanText);

    for (final match in matches) {
      final part = match.group(0);
      if (part == null || part.isEmpty) continue;

      if (RegExp(r'[一-龥]').hasMatch(part)) {
        // 中文部分：Unigram + Bigram
        final chars = part.split('');
        for (var i = 0; i < chars.length; i++) {
          tokens.add(chars[i]); // 单字
          if (i < chars.length - 1) {
            tokens.add(chars[i] + chars[i + 1]); // 双字邻词
          }
        }
      } else {
        // 英文及命令部分
        var token = part;
        // 清理末尾的点或逗号等标点符号（例如句子结尾的 "context." 应该识别为 "context"）
        while (token.endsWith('.') ||
            token.endsWith(',') ||
            token.endsWith(';') ||
            token.endsWith(':')) {
          if (token.length <= 1) break;
          token = token.substring(0, token.length - 1);
        }
        if (token.length >= 2) {
          tokens.add(token);
        }
      }
    }

    return tokens;
  }

  /// 批量添加文档分块并重建索引统计
  void addChunks(List<RagChunk> newChunks) {
    for (final chunk in newChunks) {
      _addChunkWithoutRecalc(chunk);
    }
    _recalculateAvgDocLength();
  }

  void _addChunkWithoutRecalc(RagChunk chunk) {
    chunks[chunk.id] = chunk;
    final tokens = tokenize(chunk.text);
    docLengths[chunk.id] = tokens.length;
    totalDocs++;

    for (final token in tokens) {
      final termMap = invertedIndex.putIfAbsent(token, () => {});
      termMap[chunk.id] = (termMap[chunk.id] ?? 0) + 1;
    }
  }

  void _recalculateAvgDocLength() {
    if (totalDocs == 0) {
      avgDocLength = 0.0;
      return;
    }
    final totalLength = docLengths.values.fold(0, (sum, len) => sum + len);
    avgDocLength = totalLength / totalDocs;
  }

  /// 计算给定 Term 的逆文档频率 IDF
  double _calculateIdf(String term) {
    final docsWithTerm = invertedIndex[term]?.length ?? 0;
    // 标准 BM25 IDF 公式，附带 0.5 平滑
    final numerator = totalDocs - docsWithTerm + 0.5;
    final denominator = docsWithTerm + 0.5;
    // 增加 1.0 偏移防止极度常见词得分变成负数
    return math.log(1.0 + math.max(0.0, numerator) / denominator);
  }

  /// 在当前索引的文档中搜索 query
  List<ScoredRagChunk> search(String query, {int limit = 5}) {
    if (totalDocs == 0 || query.trim().isEmpty) return const [];

    final queryTokens = tokenize(query);
    if (queryTokens.isEmpty) return const [];

    final scores = <String, double>{}; // chunkId -> score

    for (final token in queryTokens) {
      final matches = invertedIndex[token];
      if (matches == null || matches.isEmpty) continue;

      final idf = _calculateIdf(token);
      if (idf <= 0.0) continue;

      for (final entry in matches.entries) {
        final chunkId = entry.key;
        final tf = entry.value;
        final docLen = docLengths[chunkId] ?? 0;

        // BM25 评分公式：
        // score = idf * (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * (docLen / avgDocLen)))
        final numerator = tf * (k1 + 1.0);
        final denominator = tf + k1 * (1.0 - b + b * (docLen / avgDocLength));
        final termScore = idf * (numerator / denominator);

        scores[chunkId] = (scores[chunkId] ?? 0.0) + termScore;
      }
    }

    final scoredList = scores.entries
        .map((entry) => ScoredRagChunk(
              chunk: chunks[entry.key]!,
              score: entry.value,
            ))
        .toList();

    // 按得分从高到低排序
    scoredList.sort((a, b) => b.score.compareTo(a.score));

    return scoredList.take(limit).toList();
  }

  /// 将搜索引擎的索引和文档结构序列化为 JSON Map
  Map<String, dynamic> toJson() {
    return {
      'totalDocs': totalDocs,
      'avgDocLength': avgDocLength,
      'docLengths': docLengths,
      'chunks': chunks.map((k, v) => MapEntry(k, v.toJson())),
      'invertedIndex': invertedIndex,
    };
  }

  /// 从序列化的 JSON Map 重建搜索引擎
  void loadFromJson(Map<String, dynamic> json) {
    clear();
    totalDocs = json['totalDocs'] as int? ?? 0;
    avgDocLength = (json['avgDocLength'] as num? ?? 0.0).toDouble();

    final rawDocLengths = json['docLengths'] as Map<String, dynamic>? ?? {};
    rawDocLengths.forEach((k, v) {
      docLengths[k] = v as int;
    });

    final rawChunks = json['chunks'] as Map<String, dynamic>? ?? {};
    rawChunks.forEach((k, v) {
      chunks[k] = RagChunk.fromJson(v as Map<String, dynamic>);
    });

    final rawIndex = json['invertedIndex'] as Map<String, dynamic>? ?? {};
    rawIndex.forEach((k, v) {
      if (v is Map<String, dynamic>) {
        final termMap = <String, int>{};
        v.forEach((docId, tf) {
          termMap[docId] = tf as int;
        });
        invertedIndex[k] = termMap;
      }
    });
  }
}
