import 'dart:convert';
import 'package:feature_ai/src/domain/ai_compat.dart';
import 'package:feature_ai/src/chat/text_chunker.dart';

class AiChatSelectedConnectionContext {
  final String id;
  final String name;
  final String username;
  final String host;
  final int port;

  const AiChatSelectedConnectionContext({
    required this.id,
    required this.name,
    required this.username,
    required this.host,
    required this.port,
  });
}

class AiChatContextBuilder {
  const AiChatContextBuilder();

  String buildApprovedPlanExecutionContext({
    required String userText,
    required AiChatMessageRecord planMessage,
    required AppLanguage language,
  }) {
    final isEn = language == AppLanguage.en;
    final steps = planMessage.todoSteps
        .map(
          (step) => {
            'taskId': step.id,
            'name': step.name,
            'command': step.command,
            'description': step.description,
            if (step.connectionId?.trim().isNotEmpty == true)
              'connectionId': step.connectionId,
          },
        )
        .toList(growable: false);
    return [
      isEn ? 'Approved execution plan:' : '已批准执行计划：',
      isEn
          ? 'Use these persisted todoSteps as the source of truth. Execute them sequentially in order. Do not recreate task ids or reparse any earlier playbook text.'
          : '以下持久化 todoSteps 是唯一执行依据。请严格按顺序执行，不要重新创建 taskId，也不要重新解析旧的 playbook 文本。',
      isEn
          ? 'Call client_task_update with status="running" when each step starts, then update it to success, failed, or skipped with stdout/stderr when the step finishes.'
          : '每一步开始时调用 client_task_update(status="running")，完成后再更新为 success、failed 或 skipped，并尽量写入 stdout/stderr。',
      isEn ? 'Persisted steps:' : '持久化步骤：',
      jsonEncode(steps),
      '',
      isEn ? 'User execution trigger:' : '用户执行触发：',
      userText,
    ].join('\n');
  }

  String buildUserContextText({
    required String text,
    required AppLanguage language,
    required bool isEnglish,
    required List<AiChatSelectedConnectionContext> selectedConnections,
    List<RagChunk> ragChunks = const [],
    AiChatMessageRecord? approvedPlanMessage,
  }) {
    final lines = <String>[];
    if (selectedConnections.isNotEmpty) {
      final serverInfos = <String>[];
      for (final connection in selectedConnections) {
        serverInfos.add(
          '- ${connection.name} (id: ${connection.id}, host: ${connection.username}@${connection.host}:${connection.port})',
        );
      }
      if (serverInfos.isNotEmpty) {
        lines.add('Target servers:\n${serverInfos.join('\n')}');
      }
    }

    if (ragChunks.isNotEmpty) {
      final ragLines = <String>[];
      ragLines.add(
        isEnglish
            ? '【Ops Knowledge Base Reference Information】:'
            : '【运维知识库参考信息】：',
      );
      for (final chunk in ragChunks) {
        ragLines.add('---');
        ragLines.add(
          isEnglish
              ? 'Source: [${chunk.documentName}] (Chunk #${chunk.metadata['chunkIndex'] ?? 0})'
              : '来源: [${chunk.documentName}] (分块 #${chunk.metadata['chunkIndex'] ?? 0})',
        );
        ragLines.add('${isEnglish ? 'Content' : '内容'}:\n${chunk.text}');
      }
      ragLines.add('---');
      lines.add(ragLines.join('\n'));
    }

    final requestBlock =
        approvedPlanMessage != null && approvedPlanMessage.todoSteps.isNotEmpty
        ? buildApprovedPlanExecutionContext(
            userText: text,
            planMessage: approvedPlanMessage,
            language: language,
          )
        : 'User request:\n$text';
    if (lines.isEmpty) return requestBlock;
    return '${lines.join('\n\n')}\n\n$requestBlock';
  }

  String buildAssistantContextText(
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
    final preview = trimmed
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .runes
        .take(900);
    return '[Large ${trace.kind} output omitted from future context. '
        'The full trace remains visible in chat history. '
        'Length: ${trimmed.length} chars. '
        'Preview: ${String.fromCharCodes(preview)}]';
  }

  String _slimAssistantBody(String trimmed) {
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

  int _codeFenceCount(String text) {
    return RegExp(r'```').allMatches(text).length;
  }

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
