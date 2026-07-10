part of '../llm_chat_screen.dart';

@immutable
class _ChatShellSnapshot {
  final bool loading;
  final bool hasActiveChat;
  final String? activeChatId;

  const _ChatShellSnapshot({
    required this.loading,
    required this.hasActiveChat,
    required this.activeChatId,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ChatShellSnapshot &&
          runtimeType == other.runtimeType &&
          loading == other.loading &&
          hasActiveChat == other.hasActiveChat &&
          activeChatId == other.activeChatId;

  @override
  int get hashCode => Object.hash(loading, hasActiveChat, activeChatId);
}

@immutable
class _ChatHeaderSnapshot {
  final String chatId;
  final String title;
  final int contextTokens;
  final int contextWindowTokens;
  final bool sending;

  const _ChatHeaderSnapshot({
    required this.chatId,
    required this.title,
    required this.contextTokens,
    required this.contextWindowTokens,
    required this.sending,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ChatHeaderSnapshot &&
          runtimeType == other.runtimeType &&
          chatId == other.chatId &&
          title == other.title &&
          contextTokens == other.contextTokens &&
          contextWindowTokens == other.contextWindowTokens &&
          sending == other.sending;

  @override
  int get hashCode =>
      Object.hash(chatId, title, contextTokens, contextWindowTokens, sending);
}

@immutable
class _ChatMessagesSnapshot {
  final String chatId;
  final List<AiChatMessageRecord> messages;
  final bool sending;

  const _ChatMessagesSnapshot({
    required this.chatId,
    required this.messages,
    required this.sending,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ChatMessagesSnapshot &&
          runtimeType == other.runtimeType &&
          chatId == other.chatId &&
          listEquals(messages, other.messages) &&
          sending == other.sending;

  @override
  int get hashCode => Object.hash(chatId, Object.hashAll(messages), sending);
}

@immutable
class _ComposerSnapshot {
  final String chatId;
  final bool planMode;
  final bool sending;
  final bool hasPendingAttachments;
  final int pendingAttachmentsCount;
  final Set<String> selectedConnectionIds;
  final int connectionsCount;

  const _ComposerSnapshot({
    required this.chatId,
    required this.planMode,
    required this.sending,
    required this.hasPendingAttachments,
    required this.pendingAttachmentsCount,
    required this.selectedConnectionIds,
    required this.connectionsCount,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ComposerSnapshot &&
          runtimeType == other.runtimeType &&
          chatId == other.chatId &&
          planMode == other.planMode &&
          sending == other.sending &&
          hasPendingAttachments == other.hasPendingAttachments &&
          pendingAttachmentsCount == other.pendingAttachmentsCount &&
          setEquals(selectedConnectionIds, other.selectedConnectionIds) &&
          connectionsCount == other.connectionsCount;

  @override
  int get hashCode => Object.hash(
    chatId,
    planMode,
    sending,
    hasPendingAttachments,
    pendingAttachmentsCount,
    Object.hashAll(selectedConnectionIds),
    connectionsCount,
  );
}

@immutable
class _ToolApprovalSnapshot {
  final String chatId;
  final PendingToolApproval? pendingApproval;

  const _ToolApprovalSnapshot({
    required this.chatId,
    required this.pendingApproval,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ToolApprovalSnapshot &&
          runtimeType == other.runtimeType &&
          chatId == other.chatId &&
          pendingApproval == other.pendingApproval;

  @override
  int get hashCode => Object.hash(chatId, pendingApproval);
}

@immutable
class _HistoryPanelSnapshot {
  final List<AiChatRecord> savedHistoryChats;
  final String? activeChatId;
  final bool historyLoading;

  const _HistoryPanelSnapshot({
    required this.savedHistoryChats,
    required this.activeChatId,
    required this.historyLoading,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _HistoryPanelSnapshot &&
          runtimeType == other.runtimeType &&
          activeChatId == other.activeChatId &&
          historyLoading == other.historyLoading &&
          listEquals(savedHistoryChats, other.savedHistoryChats);

  @override
  int get hashCode => Object.hash(
    activeChatId,
    historyLoading,
    Object.hashAll(savedHistoryChats),
  );
}
