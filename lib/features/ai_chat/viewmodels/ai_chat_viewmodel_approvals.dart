part of 'ai_chat_viewmodel.dart';

extension AiChatViewModelApprovals on AiChatViewModel {
  Future<AiToolApprovalDecision> _requestToolApproval({
    required String chatId,
    required AiToolApprovalRequest request,
    required AiChatStatusTranslator translator,
  }) {
    final completer = Completer<AiToolApprovalDecision>();
    final prompt = translator.translateAwaitingApproval(request.connectionName);
    _updateStreamingAssistantStatus(prompt);

    _pendingApproval = PendingToolApproval(
      chatId: chatId,
      request: request,
      completer: completer,
    );
    notify();
    _triggerScroll();
    return completer.future;
  }

  void resolvePendingApproval({required bool approved}) {
    final pending = _pendingApproval;
    if (pending == null || pending.completer.isCompleted) return;
    _pendingApproval = null;
    notify();
    pending.completer.complete(
      approved
          ? const AiToolApprovalDecision.approved()
          : const AiToolApprovalDecision.rejected(),
    );
  }

}
