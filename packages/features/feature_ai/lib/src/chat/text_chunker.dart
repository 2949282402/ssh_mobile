// AI 内部使用的文档块和文本切分器。
//
// RAG Feature 只通过 app_core.RagCapability 向 AI 提供结果；这里保留
// AI 原有的富元数据模型，避免把 RAG Feature 的实现类型反向带入 AI。

import 'package:app_core/app_core.dart';

/// AI 上下文使用的文档块摘要。
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
}

/// 将长文本按滑动窗口切分为 AI 文档块。
final class TextChunker {
  const TextChunker._();

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

    var start = 0;
    var chunkIndex = 0;
    final textLength = text.length;
    while (start < textLength) {
      var end = start + chunkSize;
      if (end >= textLength) {
        end = textLength;
      } else {
        final checkRange = (chunkSize * 0.20).toInt().clamp(20, 150);
        var boundaryIndex = -1;
        for (var i = end; i > end - checkRange && i > start; i--) {
          final char = text[i - 1];
          if (char == '\n') {
            boundaryIndex = i;
            break;
          }
          if ('.。?!！;'.contains(char) && boundaryIndex == -1) {
            boundaryIndex = i;
          }
        }
        if (boundaryIndex != -1) end = boundaryIndex;
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

      final step = (end - start) - chunkOverlap;
      start += step <= 0 ? end - start : step;
    }
    return chunks;
  }
}

/// 将 Core Contract 的结果转换为 AI 内部文档块。
RagChunk ragChunkFromCapability(RagCapabilityChunk chunk) {
  final metadata = Map<String, dynamic>.from(chunk.metadata);
  return RagChunk(
    id: metadata['id'] as String? ?? '',
    documentId: metadata['documentId'] as String? ?? '',
    documentName: chunk.documentName,
    text: chunk.text,
    pageNumber: (metadata['pageNumber'] as num?)?.toInt() ?? 1,
    charStartIndex: (metadata['charStartIndex'] as num?)?.toInt() ?? 0,
    charEndIndex:
        (metadata['charEndIndex'] as num?)?.toInt() ?? chunk.text.length,
    metadata: metadata,
  );
}
