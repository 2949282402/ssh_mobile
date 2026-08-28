part of '../ssh_service.dart';

/// Owns the background-isolate event subscription and state projection updates.
extension _SshServiceBackground on SshService {
  Future<void> _startBackgroundBridge() => _backgroundBridge.start();

  void _handleBackgroundStateEvent(Map<String, dynamic> data) {
    if (_shutdownRequested) return;
    final String sessionId = data['sessionId'];
    final String stateName = data['state'];
    final String? error = data['errorMessage'];
    final state = SshConnectionState.values.firstWhere(
      (candidate) => candidate.name == stateName,
      orElse: () => SshConnectionState.disconnected,
    );

    final session = _sessions[sessionId];
    if (session == null) return;
    session.state = state;
    session.errorMessage = error;
    session.updatedAt = DateTime.now();

    if (state == SshConnectionState.connected) {
      unawaited(
        _completeBackgroundConnectAfterTelemetry(
          sessionId,
          _recordSessionConnectedTelemetry(session),
        ),
      );
    } else if (state == SshConnectionState.error) {
      unawaited(
        _completeBackgroundFailureAfterTelemetry(
          sessionId,
          _failSessionTelemetry(
            session,
            'connect',
            errorCode: _mapBackgroundErrorCode(error),
            errorMessage: error ?? 'Connection failed',
          ),
          error ?? 'Connection failed',
        ),
      );
    }

    _schedulePersistence(
      () => _saveTerminalHistoryRecord(session),
      description: 'Failed to save terminal history record',
    );
    if (state == SshConnectionState.error ||
        state == SshConnectionState.disconnected) {
      unawaited(_stopServiceIfIdle());
    }
    _notifySessionMetadataChanged();
  }

  Future<void> _completeBackgroundConnectAfterTelemetry(
    String sessionId,
    Future<void> telemetry,
  ) async {
    try {
      await telemetry;
    } on Object {
      // The telemetry producer already treats storage errors as best effort;
      // keep this guard at the completion boundary for custom clients.
    }
    final completer = _connectCompleters.remove(sessionId);
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  Future<void> _completeBackgroundFailureAfterTelemetry(
    String sessionId,
    Future<void> telemetry,
    String message,
  ) async {
    try {
      await telemetry;
    } on Object {
      // The telemetry producer already treats storage errors as best effort;
      // preserve the original SSH failure regardless of local telemetry state.
    }
    final completer = _connectCompleters.remove(sessionId);
    if (completer != null && !completer.isCompleted) {
      completer.completeError(StateError(message));
    }
  }

  void _handleBackgroundOutputEvent(Map<String, dynamic> data) {
    if (_shutdownRequested) return;
    final String sessionId = data['sessionId'];
    final String text = data['data'];
    final session = _sessions[sessionId];
    if (session == null) return;
    session.addOutput(text);
    unawaited(_historyService.append(sessionId, text));
  }

  void _handleBackgroundOverviewEvent(Map<String, dynamic> data) {
    if (_shutdownRequested) return;
    final overviewMap = data['overview'] as Map;
    final windowCount = data['windowCount'] as int;
    final byConnection = <String, SshConnectionOverview>{};
    for (final entry in overviewMap.entries) {
      final val = entry.value as Map;
      final latestStateName = val['latestState'] as String?;
      final state = latestStateName == null
          ? null
          : SshConnectionState.values.firstWhere(
              (candidate) => candidate.name == latestStateName,
              orElse: () => SshConnectionState.disconnected,
            );
      byConnection[entry.key as String] = SshConnectionOverview(
        count: val['count'] as int,
        latestState: state,
        hasConnected: val['hasConnected'] as bool,
      );
    }

    _backgroundOverviewSnapshot = SshServerOverviewSnapshot(
      byConnection: byConnection,
      windowCount: windowCount,
    );
    _refreshSessionsView();
    notify();
  }
}
