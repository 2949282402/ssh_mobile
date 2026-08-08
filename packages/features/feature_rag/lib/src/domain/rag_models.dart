// RAG Feature 的领域模型。
//
// 模型区分数据库中的元数据、搜索索引快照和文件缓存中的文档块，避免把
// 大段原文或向量正文误写入 rag.db。

/// RAG 支持的检索模式。
enum RagSearchMode {
  bm25('bm25'),
  vector('vector'),
  hybrid('hybrid');

  const RagSearchMode(this.value);

  final String value;

  /// 将设置或请求中的字符串安全转换为模式。
  static RagSearchMode fromValue(String? value) {
    for (final mode in values) {
      if (mode.value == value?.trim().toLowerCase()) return mode;
    }
    return RagSearchMode.bm25;
  }
}

/// 知识库文档的轻量元数据，不包含文档原文。
final class RagDocumentMetadata {
  const RagDocumentMetadata({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.sizeBytes,
    required this.uploadedAt,
    required this.chunkCount,
  });

  final String id;
  final String name;
  final String mimeType;
  final int sizeBytes;
  final DateTime uploadedAt;
  final int chunkCount;

  /// 转为只含元数据的 JSON，禁止加入 text 或 embedding。
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'mimeType': mimeType,
    'sizeBytes': sizeBytes,
    'uploadedAt': uploadedAt.toIso8601String(),
    'chunkCount': chunkCount,
  };

  factory RagDocumentMetadata.fromJson(Map<String, dynamic> json) {
    return RagDocumentMetadata(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      uploadedAt:
          DateTime.tryParse(json['uploadedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      chunkCount: (json['chunkCount'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 文档块；正文和向量只存在受限文件缓存中，不进入数据库表。
final class RagChunk {
  const RagChunk({
    required this.id,
    required this.documentId,
    required this.documentName,
    required this.text,
    this.pageNumber = 1,
    required this.charStartIndex,
    required this.charEndIndex,
    this.metadata = const {},
  });

  final String id;
  final String documentId;
  final String documentName;
  final String text;
  final int pageNumber;
  final int charStartIndex;
  final int charEndIndex;
  final Map<String, dynamic> metadata;

  Map<String, dynamic> toJson() => {
    'id': id,
    'documentId': documentId,
    'documentName': documentName,
    'text': text,
    'pageNumber': pageNumber,
    'charStartIndex': charStartIndex,
    'charEndIndex': charEndIndex,
    'metadata': metadata,
  };

  factory RagChunk.fromJson(Map<String, dynamic> json) {
    final rawMetadata = json['metadata'];
    return RagChunk(
      id: json['id'] as String? ?? '',
      documentId: json['documentId'] as String? ?? '',
      documentName: json['documentName'] as String? ?? '',
      text: json['text'] as String? ?? '',
      pageNumber: (json['pageNumber'] as num?)?.toInt() ?? 1,
      charStartIndex: (json['charStartIndex'] as num?)?.toInt() ?? 0,
      charEndIndex: (json['charEndIndex'] as num?)?.toInt() ?? 0,
      metadata: rawMetadata is Map
          ? rawMetadata.map((key, value) => MapEntry(key.toString(), value))
          : const {},
    );
  }
}

/// 数据库保存的倒排索引快照；不包含 [RagChunk] 正文。
final class RagIndexMetadata {
  const RagIndexMetadata({
    required this.totalDocs,
    required this.avgDocLength,
    required this.docLengths,
    required this.invertedIndex,
    required this.updatedAt,
  });

  final int totalDocs;
  final double avgDocLength;
  final Map<String, int> docLengths;
  final Map<String, Map<String, int>> invertedIndex;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'totalDocs': totalDocs,
    'avgDocLength': avgDocLength,
    'docLengths': docLengths,
    'invertedIndex': invertedIndex,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory RagIndexMetadata.fromJson(Map<String, dynamic> json) {
    final rawLengths = json['docLengths'];
    final docLengths = <String, int>{};
    if (rawLengths is Map) {
      for (final entry in rawLengths.entries) {
        final value = entry.value;
        if (value is num) docLengths[entry.key.toString()] = value.toInt();
      }
    }

    final rawIndex = json['invertedIndex'];
    final invertedIndex = <String, Map<String, int>>{};
    if (rawIndex is Map) {
      for (final entry in rawIndex.entries) {
        if (entry.value is! Map) continue;
        final termMap = <String, int>{};
        for (final match in (entry.value as Map).entries) {
          final value = match.value;
          if (value is num) termMap[match.key.toString()] = value.toInt();
        }
        invertedIndex[entry.key.toString()] = termMap;
      }
    }

    return RagIndexMetadata(
      totalDocs: (json['totalDocs'] as num?)?.toInt() ?? 0,
      avgDocLength: (json['avgDocLength'] as num?)?.toDouble() ?? 0,
      docLengths: docLengths,
      invertedIndex: invertedIndex,
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// 文档块文件缓存的索引信息。
final class RagCacheMetadata {
  const RagCacheMetadata({
    required this.documentId,
    required this.fileName,
    required this.sizeBytes,
    required this.createdAt,
    required this.lastAccessedAt,
    required this.expiresAt,
  });

  final String documentId;
  final String fileName;
  final int sizeBytes;
  final DateTime createdAt;
  final DateTime lastAccessedAt;
  final DateTime expiresAt;

  RagCacheMetadata copyWith({
    int? sizeBytes,
    DateTime? lastAccessedAt,
    DateTime? expiresAt,
  }) {
    return RagCacheMetadata(
      documentId: documentId,
      fileName: fileName,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      createdAt: createdAt,
      lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
      expiresAt: expiresAt ?? this.expiresAt,
    );
  }
}

/// Module 初始化时从 Repository 读取的聚合快照。
final class RagRepositorySnapshot {
  const RagRepositorySnapshot({
    required this.documents,
    required this.index,
    required this.cacheEntries,
  });

  final List<RagDocumentMetadata> documents;
  final RagIndexMetadata? index;
  final List<RagCacheMetadata> cacheEntries;
}
