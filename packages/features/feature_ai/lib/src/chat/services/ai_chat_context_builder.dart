import 'package:feature_ai/src/domain/ai_compat.dart';
import 'package:feature_ai/src/chat/text_chunker.dart';
import 'package:feature_ai/src/chat/chat_context_assembler.dart';
import 'package:feature_ai/src/chat/services/approved_plan_context.dart'
    as approved_plan;

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
  }) => approved_plan.buildApprovedPlanExecutionContext(
    userText: userText,
    planMessage: planMessage,
    language: language,
  );

  String buildUserContextText({
    required String text,
    required AppLanguage language,
    required bool isEnglish,
    required List<AiChatSelectedConnectionContext> selectedConnections,
    List<RagChunk> ragChunks = const [],
    AiChatMessageRecord? approvedPlanMessage,
  }) {
    final serverInfos = selectedConnections
        .map(
          (connection) =>
              '- ${connection.name} (id: ${connection.id}, host: ${connection.username}@${connection.host}:${connection.port})',
        )
        .toList(growable: false);
    return ChatContextAssembler.buildUserContextText(
      userText: text,
      isEnglish: isEnglish,
      language: language,
      serverInfos: serverInfos,
      ragChunks: ragChunks,
      approvedPlanMessage: approvedPlanMessage,
    );
  }

  String buildAssistantContextText(
    String text, {
    List<AiMessageTrace> traces = const [],
  }) => ChatContextAssembler.buildAssistantContextText(text, traces: traces);
}
