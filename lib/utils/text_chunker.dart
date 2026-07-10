class RagChunk {
  final String id;
  final String documentId;
  final String documentName;
  final String text;
  final int pageNumber;
  final int charStartIndex;
  final int charEndIndex;
  final Map<String, dynamic> metadata;

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

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'documentId': documentId,
      'documentName': documentName,
      'text': text,
      'pageNumber': pageNumber,
      'charStartIndex': charStartIndex,
      'charEndIndex': charEndIndex,
      'metadata': metadata,
    };
  }

  factory RagChunk.fromJson(Map<String, dynamic> json) {
    return RagChunk(
      id: json['id'] as String? ?? '',
      documentId: json['documentId'] as String? ?? '',
      documentName: json['documentName'] as String? ?? '',
      text: json['text'] as String? ?? '',
      pageNumber: json['pageNumber'] as int? ?? 1,
      charStartIndex: json['charStartIndex'] as int? ?? 0,
      charEndIndex: json['charEndIndex'] as int? ?? 0,
      metadata: json['metadata'] as Map<String, dynamic>? ?? const {},
    );
  }
}

class TextChunker {
  /// 将长文本按滑动窗口算法切分为 RagChunk。
  static List<RagChunk> split({
    required String text,
    required String documentId,
    required String documentName,
    int chunkSize = 600,
    int chunkOverlap = 120,
    int pageNumber = 1,
    Map<String, dynamic> baseMetadata = const {},
  }) {
    final chunks = <RagChunk>[];
    if (text.trim().isEmpty) return chunks;

    int start = 0;
    int chunkIndex = 0;
    final textLength = text.length;

    while (start < textLength) {
      int end = start + chunkSize;
      if (end >= textLength) {
        end = textLength;
      } else {
        // 智能切分：在最后 20% 的空间里寻找句子结束符或换行符作为截断点，保持语句相对完整
        final checkRange = (chunkSize * 0.20).toInt().clamp(20, 150);
        int boundaryIndex = -1;
        for (int i = end; i > end - checkRange && i > start; i--) {
          final char = text[i - 1];
          if (char == '\n') {
            boundaryIndex = i;
            break;
          } else if (char == '.' ||
              char == '。' ||
              char == '?' ||
              char == '？' ||
              char == '!' ||
              char == '！' ||
              char == ';') {
            if (boundaryIndex == -1) {
              boundaryIndex = i;
            }
          }
        }
        if (boundaryIndex != -1) {
          end = boundaryIndex;
        }
      }

      final chunkText = text.substring(start, end).trim();
      if (chunkText.isNotEmpty) {
        chunks.add(
          RagChunk(
            id: '${documentId}_c${chunkIndex++}',
            documentId: documentId,
            documentName: documentName,
            text: chunkText,
            pageNumber: pageNumber,
            charStartIndex: start,
            charEndIndex: end,
            metadata: {...baseMetadata, 'chunkIndex': chunkIndex - 1},
          ),
        );
      }

      // 前进：移动步长为 (当前分块大小 - 重叠大小)
      final step = (end - start) - chunkOverlap;
      if (step <= 0) {
        start = end;
      } else {
        start += step;
      }
    }

    return chunks;
  }
}
