part of 'ai_chat_viewmodel.dart';

class _PlanApprovalSnapshot {
  final AiChatRecord chat;
  final DateTime assistantCreatedAt;
  final String fingerprint;
  final _ChatTurnInputSnapshot turnInput;
  final AiRuntimeConnectionSnapshot? runtimeConnection;

  const _PlanApprovalSnapshot({
    required this.chat,
    required this.assistantCreatedAt,
    required this.fingerprint,
    required this.turnInput,
    this.runtimeConnection,
  });

  _PlanApprovalSnapshot withRuntimeConnection(
    AiRuntimeConnectionSnapshot value,
  ) {
    return _PlanApprovalSnapshot(
      chat: chat,
      assistantCreatedAt: assistantCreatedAt,
      fingerprint: fingerprint,
      turnInput: turnInput,
      runtimeConnection: value,
    );
  }
}

extension AiChatViewModelApprovals on AiChatViewModel {
  Future<ApprovePlanExecutionResult> approvePlanAndExecute(
    DateTime assistantCreatedAt, {
    bool forceAfterWarning = false,
  }) async {
    if (_sending || _planApprovalInFlight || _chatStateWritesInFlight > 0) {
      return const ApprovePlanExecutionAlreadySending();
    }
    _PlanApprovalSnapshot captured;
    if (forceAfterWarning) {
      final continuation = _pendingPlanWarningSnapshot;
      _pendingPlanWarningSnapshot = null;
      if (continuation == null ||
          continuation.assistantCreatedAt != assistantCreatedAt ||
          !_isPlanApprovalSnapshotCurrent(continuation)) {
        return const ApprovePlanExecutionPlanChanged();
      }
      captured = continuation;
    } else {
      _pendingPlanWarningSnapshot = null;
      final fresh = _planApprovalSnapshotFor(assistantCreatedAt);
      if (fresh == null) return const ApprovePlanExecutionNoPlan();
      captured = fresh;
    }

    _planApprovalInFlight = true;
    notify();
    ClientRuntimeHealthReport? healthReport;
    var preserveWarningContinuation = false;
    try {
      if (captured.runtimeConnection == null) {
        captured = captured.withRuntimeConnection(
          await _storageService.loadAiRuntimeConnectionSnapshot(),
        );
        if (!_isPlanApprovalSnapshotCurrent(captured)) {
          return const ApprovePlanExecutionPlanChanged();
        }
      }
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
        _pendingPlanWarningSnapshot = captured;
        preserveWarningContinuation = true;
        return ApprovePlanExecutionWarning(healthReport);
      }

      final current = _matchingPlanApprovalSnapshot(captured);
      if (current == null) {
        return ApprovePlanExecutionPlanChanged(healthReport: healthReport);
      }
      final runtimeConnection = captured.runtimeConnection!;
      if (!runtimeConnection.hasApiKey) {
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
      final strings = AiStrings(captured.turnInput.language);
      final sendResult = await _startTextGeneration(
        chat: approvedChat,
        targetText: strings.executeApprovedPlan,
        runtimeConnection: runtimeConnection,
        approvedPlanRef: approvedPlan,
        turnInputSnapshot: captured.turnInput,
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
      if (!preserveWarningContinuation &&
          identical(_pendingPlanWarningSnapshot, captured)) {
        _pendingPlanWarningSnapshot = null;
      }
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
    final latestAssistant = approvablePlanMessageForChat(chat);
    if (latestAssistant == null ||
        latestAssistant.createdAt != assistantCreatedAt) {
      return null;
    }
    return _PlanApprovalSnapshot(
      chat: chat,
      assistantCreatedAt: assistantCreatedAt,
      fingerprint: _planApprovalFingerprint(chat, latestAssistant),
      turnInput: _captureTurnInputSnapshot(
        chatId: chat.id,
        includeAttachments: false,
      ),
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
