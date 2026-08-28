part of '../ssh_service.dart';

/// Projects the mutable SSH session registry into stable UI snapshots.
final class _SshSessionProjection {
  const _SshSessionProjection();

  ({List<SshSession> sessions, SshServerOverviewSnapshot overview}) project(
    Iterable<SshSession> source,
  ) {
    final sessions = source.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final byConnection = <String, SshConnectionOverview>{};
    for (final session in sessions) {
      final id = session.connectionId;
      final current = byConnection[id];
      byConnection[id] = SshConnectionOverview(
        count: (current?.count ?? 0) + 1,
        latestState: _latestState(current?.latestState, session.state),
        hasConnected:
            (current?.hasConnected ?? false) ||
            session.state == SshConnectionState.connected,
      );
    }
    return (
      sessions: List<SshSession>.unmodifiable(sessions),
      overview: SshServerOverviewSnapshot(
        byConnection: byConnection,
        windowCount: sessions.length,
      ),
    );
  }

  SshConnectionState _latestState(
    SshConnectionState? current,
    SshConnectionState next,
  ) {
    const precedence = <SshConnectionState, int>{
      SshConnectionState.disconnected: 0,
      SshConnectionState.error: 1,
      SshConnectionState.connecting: 2,
      SshConnectionState.connected: 3,
    };
    if (current == null) return next;
    return precedence[next]! > precedence[current]! ? next : current;
  }
}

/// Maintains the immutable session list and mixed-transport overview.
extension _SshServiceOverview on SshService {
  void _refreshSessionsViewState() {
    final projection = _sessionProjection.project(_sessions.values);
    _sessionsView = projection.sessions;
    final background = _backgroundOverviewSnapshot;
    final hasBackgroundSessions = _sessionUsesBackgroundService.values.any(
      (uses) => uses,
    );
    if (background != null && hasBackgroundSessions) {
      final nativeSessions = _sessions.entries
          .where((entry) => !_usesBackgroundForSession(entry.key))
          .map((entry) => entry.value);
      final nativeOverview = _sessionProjection
          .project(nativeSessions)
          .overview;
      _serverOverviewSnapshot = _mergeOverview(background, nativeOverview);
    } else if (!hasBackgroundSessions) {
      _backgroundOverviewSnapshot = null;
      _serverOverviewSnapshot = projection.overview;
    }
  }

  SshServerOverviewSnapshot _mergeOverview(
    SshServerOverviewSnapshot background,
    SshServerOverviewSnapshot native,
  ) {
    final byConnection = <String, SshConnectionOverview>{
      ...background.byConnection,
    };
    for (final entry in native.byConnection.entries) {
      final current = byConnection[entry.key];
      if (current == null) {
        byConnection[entry.key] = entry.value;
        continue;
      }
      byConnection[entry.key] = SshConnectionOverview(
        count: current.count + entry.value.count,
        latestState: _latestOverviewState(
          current.latestState,
          entry.value.latestState,
        ),
        hasConnected: current.hasConnected || entry.value.hasConnected,
      );
    }
    return SshServerOverviewSnapshot(
      byConnection: byConnection,
      windowCount: background.windowCount + native.windowCount,
    );
  }

  SshConnectionState? _latestOverviewState(
    SshConnectionState? current,
    SshConnectionState? next,
  ) {
    if (current == null) return next;
    if (next == null) return current;
    const precedence = <SshConnectionState, int>{
      SshConnectionState.disconnected: 0,
      SshConnectionState.error: 1,
      SshConnectionState.connecting: 2,
      SshConnectionState.connected: 3,
    };
    return precedence[next]! > precedence[current]! ? next : current;
  }
}
