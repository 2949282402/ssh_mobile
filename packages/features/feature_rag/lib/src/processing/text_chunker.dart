// 文档块模型位于 domain，分块器只负责切分，不重复定义数据类型。
import '../domain/rag_models.dart';

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
