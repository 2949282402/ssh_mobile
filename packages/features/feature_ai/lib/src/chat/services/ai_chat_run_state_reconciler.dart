import 'package:feature_ai/src/domain/ai_compat.dart';

/// Reconciles state persisted by client tools with the in-memory streaming UI.
///
/// Client task tools write TODO progress directly to storage while generation
/// traces and response text are accumulated in memory. The persisted task and
/// plan fields therefore win, while the in-memory message payload keeps the
/// latest streaming content.
class AiChatRunStateReconciler {
  const AiChatRunStateReconciler();

  AiChatRecord reconcile({
    required AiChatRecord memoryChat,
    required AiChatRecord persistedChat,
  }) {
    if (memoryChat.id != persistedChat.id) return memoryChat;

    final persistedMessages = <String, AiChatMessageRecord>{
      for (final message in persistedChat.messages)
        _messageKey(message): message,
    };
    final messages = memoryChat.messages
        .map((message) {
          final persisted = persistedMessages[_messageKey(message)];
          if (persisted == null) return message;
          return message.copyWith(todoSteps: persisted.todoSteps);
        })
        .toList(growable: false);

    final updatedAt = memoryChat.updatedAt.isAfter(persistedChat.updatedAt)
        ? memoryChat.updatedAt
        : persistedChat.updatedAt;
    return memoryChat.copyWith(
      messages: messages,
      updatedAt: updatedAt,
      planMode: persistedChat.planMode,
      approvedPlan: persistedChat.approvedPlan,
      clearApprovedPlan: persistedChat.approvedPlan == null,
    );
  }

  String _messageKey(AiChatMessageRecord message) {
    // Drift 以毫秒精度保存消息时间；匹配前统一精度，避免流式期间由工具
    // 写入的 TODO 状态在 Repository 重新加载同一条消息时丢失。
    return '${message.role}:${message.createdAt.millisecondsSinceEpoch}';
  }
}
