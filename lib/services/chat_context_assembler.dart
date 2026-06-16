import 'approved_plan_context.dart';
import 'app_settings.dart';
import 'operational_memory_retriever.dart';
import 'storage_service.dart';
import '../utils/text_chunker.dart';

class ChatContextAssembler {
  final StorageService storageService;

  const ChatContextAssembler({
    required this.storageService,
  });

  Future<String?> buildUserContext({
    required String userText,
    required AppLanguage language,
    Set<String> selectedConnectionIds = const {},
    List<RagChunk> ragChunks = const [],
    List<OperationalMemoryHit> memoryHits = const [],
    AiChatMessageRecord? approvedPlanMessage,
  }) async {
    final lines = <String>[];
    if (selectedConnectionIds.isNotEmpty) {
      final serverInfos = <String>[];
      for (final id in selectedConnectionIds) {
        final connection = storageService.getConnection(id);
        if (connection == null) continue;
        serverInfos.add(
          '- ${connection.name} (id: ${connection.id}, host: ${connection.username}@${connection.host}:${connection.port})',
        );
      }
      if (serverInfos.isNotEmpty) {
        lines.add('Target servers:\n${serverInfos.join('\n')}');
      }
    }

    if (ragChunks.isNotEmpty) {
      final ragLines = <String>[
        language == AppLanguage.en ? '[RAG reference]' : '【RAG 参考】',
      ];
      for (final chunk in ragChunks) {
        ragLines.add('---');
        ragLines.add(
          language == AppLanguage.en
              ? 'Source: [${chunk.documentName}] (Chunk #${chunk.metadata['chunkIndex'] ?? 0})'
              : '来源: [${chunk.documentName}] (分块 #${chunk.metadata['chunkIndex'] ?? 0})',
        );
        ragLines.add(chunk.text);
      }
      lines.add(ragLines.join('\n'));
    }

    if (memoryHits.isNotEmpty) {
      final memoryLines = <String>[
        language == AppLanguage.en
            ? '[Operational memory references]'
            : '【运维经验记忆】',
      ];
      for (final hit in memoryHits) {
        memoryLines
          ..add('---')
          ..add('${hit.sourceType}: ${hit.title}')
          ..add(hit.content);
      }
      lines.add(memoryLines.join('\n'));
    }

    final requestBlock =
        approvedPlanMessage != null && approvedPlanMessage.todoSteps.isNotEmpty
            ? buildApprovedPlanExecutionContext(
                userText: userText,
                planMessage: approvedPlanMessage,
                language: language,
              )
            : 'User request:\n$userText';
    if (lines.isEmpty) return requestBlock;
    return '${lines.join('\n\n')}\n\n$requestBlock';
  }

  String buildAssistantContext(
    String text, {
    List<AiMessageTrace> traces = const [],
  }) {
    final trimmed = text.trim();
    final body = trimmed.isEmpty
        ? trimmed
        : !_shouldOmitAssistantBody(trimmed)
            ? trimmed
            : _slimAssistantBody(trimmed);
    if (traces.isEmpty) return body;

    final buffer = StringBuffer();
    if (body.isNotEmpty) {
      buffer.writeln(body);
      buffer.writeln();
    }
    buffer.writeln('Assistant execution memory:');
    for (final trace in traces) {
      buffer
        ..writeln('[${trace.kind}] ${trace.title}')
        ..writeln(_traceMemoryContent(trace))
        ..writeln();
    }
    return buffer.toString().trimRight();
  }

  String _traceMemoryContent(AiMessageTrace trace) {
    final trimmed = trace.content.trim();
    if (trimmed.length <= 2500) return trimmed;
    final preview =
        trimmed.replaceAll(RegExp(r'\s+'), ' ').trim().runes.take(900);
    return '[Large ${trace.kind} output omitted from future context. '
        'The full trace remains visible in chat history. '
        'Length: ${trimmed.length} chars. '
        'Preview: ${String.fromCharCodes(preview)}]';
  }

  String _slimAssistantBody(String trimmed) {
    final preview =
        trimmed.replaceAll(RegExp(r'\s+'), ' ').trim().runes.take(420);
    final type = _largeAssistantBodyType(trimmed);
    return '[Large $type output omitted from future context. '
        'The full content remains visible in chat history. '
        'Length: ${trimmed.length} chars. '
        'Preview: ${String.fromCharCodes(preview)}]';
  }

  bool _shouldOmitAssistantBody(String text) {
    final lowerText = text.toLowerCase();
    if (text.length > 6000) return true;
    if (text.length > 2500 && _codeFenceCount(text) >= 2) return true;
    if (text.length > 2500 &&
        (lowerText.contains('<html') || lowerText.contains('<!doctype'))) {
      return true;
    }
    if (text.length > 3000 && _markdownDocumentScore(text) >= 10) return true;
    return false;
  }

  String _largeAssistantBodyType(String text) {
    final lowerText = text.toLowerCase();
    if (lowerText.contains('<html') || lowerText.contains('<!doctype')) {
      return 'HTML';
    }
    if (_codeFenceCount(text) >= 2) return 'code/document';
    if (_markdownDocumentScore(text) >= 10) return 'Markdown/document';
    return 'document';
  }

  int _codeFenceCount(String text) => RegExp(r'```').allMatches(text).length;

  int _markdownDocumentScore(String text) {
    var score = 0;
    for (final line in text.split('\n')) {
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('#')) score += 2;
      if (trimmed.startsWith('|')) score++;
      if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) score++;
      if (RegExp(r'^\d+\. ').hasMatch(trimmed)) score++;
    }
    return score;
  }
}
