import 'package:feature_ai/src/chat/services/approved_plan_context.dart';
import 'package:feature_ai/src/domain/ai_compat.dart';
import 'operational_memory_retriever.dart';
import 'package:feature_ai/src/chat/text_chunker.dart';

class ChatContextAssembler {
  final AiStoragePort storageService;

  const ChatContextAssembler({required this.storageService});

  Future<String?> buildUserContext({
    required String userText,
    required AppLanguage language,
    Set<String> selectedConnectionIds = const {},
    Map<String, ConnectionTargetBinding> connectionTargets = const {},
    List<RagChunk> ragChunks = const [],
    List<OperationalMemoryHit> memoryHits = const [],
    AiChatMessageRecord? approvedPlanMessage,
  }) async {
    final serverInfos = <String>[];
    if (connectionTargets.isNotEmpty || selectedConnectionIds.isNotEmpty) {
      final frozenTargets = connectionTargets.values;
      if (frozenTargets.isNotEmpty) {
        for (final target in frozenTargets) {
          final connection = target.config;
          serverInfos.add(
            '- ${connection.name} (id: ${connection.id}, host: ${connection.username}@${connection.host}:${connection.port})',
          );
        }
      } else {
        for (final id in selectedConnectionIds) {
          final connection = storageService.getConnection(id);
          if (connection == null) continue;
          serverInfos.add(
            '- ${connection.name} (id: ${connection.id}, host: ${connection.username}@${connection.host}:${connection.port})',
          );
        }
      }
    }
    return buildUserContextText(
      userText: userText,
      isEnglish: language == AppLanguage.en,
      language: language,
      serverInfos: serverInfos,
      ragChunks: ragChunks,
      memoryHits: memoryHits,
      approvedPlanMessage: approvedPlanMessage,
    );
  }

  /// Canonical user-turn representation shared by live and compatibility
  /// callers. Retrieved RAG and memory content is always visibly delimited as
  /// untrusted data before it reaches the provider request.
  static String buildUserContextText({
    required String userText,
    required bool isEnglish,
    AppLanguage? language,
    List<String> serverInfos = const [],
    List<RagChunk> ragChunks = const [],
    List<OperationalMemoryHit> memoryHits = const [],
    AiChatMessageRecord? approvedPlanMessage,
  }) {
    final lines = <String>[];
    if (serverInfos.isNotEmpty) {
      lines.add('Target servers:\n${serverInfos.join('\n')}');
    }

    if (ragChunks.isNotEmpty) {
      final ragLines = <String>[
        '<UNTRUSTED_RAG_DATA>',
        isEnglish
            ? '[RAG reference]\n【Ops Knowledge Base Reference Information】:'
            : '【RAG 参考】\n【运维知识库参考信息】：',
      ];
      for (final chunk in ragChunks) {
        ragLines.add('---');
        ragLines.add(
          isEnglish
              ? 'Source: [${_sanitizeUntrustedText(chunk.documentName)}] '
                    '(Chunk #${chunk.metadata['chunkIndex'] ?? 0})'
              : '来源: [${_sanitizeUntrustedText(chunk.documentName)}] '
                    '(分块 #${chunk.metadata['chunkIndex'] ?? 0})',
        );
        ragLines.add(
          '${isEnglish ? 'Content' : '内容'}:\n${_sanitizeUntrustedText(chunk.text)}',
        );
      }
      ragLines.add('</UNTRUSTED_RAG_DATA>');
      lines.add(ragLines.join('\n'));
    }

    if (memoryHits.isNotEmpty) {
      final memoryLines = <String>[
        '<UNTRUSTED_OPERATIONAL_MEMORY>',
        isEnglish ? '[Operational memory references]' : '【运维经验记忆】',
      ];
      for (final hit in memoryHits) {
        memoryLines
          ..add('---')
          ..add(
            '${_sanitizeUntrustedText(hit.sourceType)}: '
            '${_sanitizeUntrustedText(hit.title)}',
          )
          ..add(_sanitizeUntrustedText(hit.content));
      }
      memoryLines.add('</UNTRUSTED_OPERATIONAL_MEMORY>');
      lines.add(memoryLines.join('\n'));
    }

    final requestLanguage =
        language ?? (isEnglish ? AppLanguage.en : AppLanguage.zh);
    final requestBlock =
        approvedPlanMessage != null && approvedPlanMessage.todoSteps.isNotEmpty
        ? buildApprovedPlanExecutionContext(
            userText: userText,
            planMessage: approvedPlanMessage,
            language: requestLanguage,
          )
        : 'User request:\n$userText';
    if (lines.isEmpty) return requestBlock;
    return '${lines.join('\n\n')}\n\n$requestBlock';
  }

  static String _sanitizeUntrustedText(String value) {
    // Keep retrieved content readable while making it impossible for a
    // document to close or open one of the control delimiters above.
    return value.replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  }

  String buildAssistantContext(
    String text, {
    List<AiMessageTrace> traces = const [],
  }) {
    return buildAssistantContextText(text, traces: traces);
  }

  /// Canonical assistant-history representation used by both the live
  /// orchestrator and persisted-message mapper.
  static String buildAssistantContextText(
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

  static String _traceMemoryContent(AiMessageTrace trace) {
    final trimmed = trace.content.trim();
    final content = trimmed.length <= 2500
        ? trimmed
        : '[Large ${trace.kind} output omitted from future context. '
              'The full trace remains visible in chat history. '
              'Length: ${trimmed.length} chars. '
              'Preview: ${String.fromCharCodes(trimmed.replaceAll(RegExp(r'\s+'), ' ').trim().runes.take(900))}]';
    final boundary = switch (trace.kind) {
      'rag_context' => 'UNTRUSTED_RAG_DATA',
      'memory_context' => 'UNTRUSTED_OPERATIONAL_MEMORY',
      _ => null,
    };
    if (boundary == null) return content;
    return '<$boundary>\n${_sanitizeUntrustedText(content)}\n</$boundary>';
  }

  static String _slimAssistantBody(String trimmed) {
    final preview = trimmed
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .runes
        .take(420);
    final type = _largeAssistantBodyType(trimmed);
    return '[Large $type output omitted from future context. '
        'The full content remains visible in chat history. '
        'Length: ${trimmed.length} chars. '
        'Preview: ${String.fromCharCodes(preview)}]';
  }

  static bool _shouldOmitAssistantBody(String text) {
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

  static String _largeAssistantBodyType(String text) {
    final lowerText = text.toLowerCase();
    if (lowerText.contains('<html') || lowerText.contains('<!doctype')) {
      return 'HTML';
    }
    if (_codeFenceCount(text) >= 2) return 'code/document';
    if (_markdownDocumentScore(text) >= 10) return 'Markdown/document';
    return 'document';
  }

  static int _codeFenceCount(String text) =>
      RegExp(r'```').allMatches(text).length;

  static int _markdownDocumentScore(String text) {
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
