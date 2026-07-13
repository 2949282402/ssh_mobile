part of 'ai_chat_viewmodel.dart';

class _PlanApprovalSnapshot {
  final AiChatRecord chat;
  final DateTime assistantCreatedAt;
  final String fingerprint;

  const _PlanApprovalSnapshot({
    required this.chat,
    required this.assistantCreatedAt,
    required this.fingerprint,
  });
}

extension AiChatViewModelApprovals on AiChatViewModel {
  Future<ApprovePlanExecutionResult> approvePlanAndExecute(
    DateTime assistantCreatedAt, {
    bool forceAfterWarning = false,
  }) async {
    if (_sending || _planApprovalInFlight || _chatStateWritesInFlight > 0) {
      return const ApprovePlanExecutionAlreadySending();
    }
    final captured = _planApprovalSnapshotFor(assistantCreatedAt);
    if (captured == null) return const ApprovePlanExecutionNoPlan();

    _planApprovalInFlight = true;
    notify();
    ClientRuntimeHealthReport? healthReport;
    try {
      healthReport = await _clientHealthAdvisor.check(
        profile: ClientHealthCheckProfile.agentExecution,
      );
      _lastRuntimeHealthReport = healthReport;
      notify();

      if (!_isPlanApprovalSnapshotCurrent(captured)) {
        return ApprovePlanExecutionPlanChanged(healthReport: healthReport);
      }
      if (healthReport.status == ClientRuntimeHealthStatus.blocking) {
        return ApprovePlanExecutionBlocked(healthReport);
      }
      if (healthReport.status == ClientRuntimeHealthStatus.warning &&
          !forceAfterWarning) {
        return ApprovePlanExecutionWarning(healthReport);
      }

      final settings = await _storageService.loadAiConnectionSettings();
      final current = _matchingPlanApprovalSnapshot(captured);
      if (current == null) {
        return ApprovePlanExecutionPlanChanged(healthReport: healthReport);
      }
      if (!settings.hasApiKey) {
        return ApprovePlanExecutionApiKeyMissing(healthReport: healthReport);
      }

      final approvedAt = DateTime.now();
      final approvedPlan = AiApprovedPlanRef(
        assistantCreatedAt: assistantCreatedAt,
        approvedAt: approvedAt,
      );
      final approvedChat = current.chat.copyWith(
        planMode: false,
        approvedPlan: approvedPlan,
        updatedAt: approvedAt,
      );
      final isEn = _appSettings.language == AppLanguage.en;
      final sendResult = await _startTextGeneration(
        chat: approvedChat,
        targetText: isEn ? 'Execute the approved plan.' : '执行已批准的计划。',
        settings: settings,
        approvedPlanRef: approvedPlan,
        canCommit: () => _isPlanApprovalSnapshotCurrent(captured),
      );
      if (sendResult is SendTextSuccess) {
        return ApprovePlanExecutionStarted(healthReport: healthReport);
      }
      if (sendResult is SendTextTargetChanged) {
        return ApprovePlanExecutionPlanChanged(healthReport: healthReport);
      }
      if (sendResult is SendTextStartCancelled) {
        return ApprovePlanExecutionCancelled(healthReport: healthReport);
      }
      if (sendResult is SendTextAlreadySending) {
        return const ApprovePlanExecutionAlreadySending();
      }
      return ApprovePlanExecutionFailed(healthReport: healthReport);
    } catch (_) {
      AppLogService.instance.warning(
        'Plan approval preflight or execution start failed',
        details: 'chatId=${captured.chat.id}',
      );
      return ApprovePlanExecutionFailed(healthReport: healthReport);
    } finally {
      _planApprovalInFlight = false;
      notify();
    }
  }

  _PlanApprovalSnapshot? _planApprovalSnapshotFor(DateTime assistantCreatedAt) {
    if (_chatStateWritesInFlight > 0) return null;
    final chat = activeChat;
    if (chat == null ||
        _activeChatId != chat.id ||
        chat.planMode ||
        chat.approvedPlan != null) {
      return null;
    }
    final latestAssistant = latestAssistantMessageForChat(chat);
    if (latestAssistant == null ||
        latestAssistant.createdAt != assistantCreatedAt ||
        latestAssistant.todoSteps.isEmpty ||
        !latestAssistant.todoSteps.every(
          (step) => step.status == StepStatus.pending,
        )) {
      return null;
    }
    return _PlanApprovalSnapshot(
      chat: chat,
      assistantCreatedAt: assistantCreatedAt,
      fingerprint: _planApprovalFingerprint(chat, latestAssistant),
    );
  }

  _PlanApprovalSnapshot? _matchingPlanApprovalSnapshot(
    _PlanApprovalSnapshot captured,
  ) {
    final current = _planApprovalSnapshotFor(captured.assistantCreatedAt);
    if (current == null ||
        current.chat.id != captured.chat.id ||
        current.fingerprint != captured.fingerprint) {
      return null;
    }
    return current;
  }

  bool _isPlanApprovalSnapshotCurrent(_PlanApprovalSnapshot captured) {
    return _matchingPlanApprovalSnapshot(captured) != null;
  }

  String _planApprovalFingerprint(
    AiChatRecord chat,
    AiChatMessageRecord message,
  ) {
    return jsonEncode({
      'planMode': chat.planMode,
      'assistantCreatedAt': message.createdAt.toIso8601String(),
      'steps': message.todoSteps.map((step) => step.toJson()).toList(),
    });
  }

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
