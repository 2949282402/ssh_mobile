import 'dart:async';

/// Owns resources created by one SSH connection attempt until registry commit.
///
/// Ownership is progressively transferred from socket to client, then shell,
/// and finally the complete runtime. A failed or superseded attempt rolls back
/// the currently-owned resources in reverse order. One cleanup failure never
/// skips the remaining resources.
final class SshConnectionAttemptOwner {
  FutureOr<void> Function()? _socketRelease;
  FutureOr<void> Function()? _clientRelease;
  FutureOr<void> Function()? _shellRelease;
  FutureOr<void> Function()? _runtimeRelease;
  bool _finished = false;

  /// Takes ownership of a socket that has not yet been adopted by a client.
  void ownSocket(FutureOr<void> Function() release) {
    _ensureActive();
    _socketRelease = release;
  }

  /// Transfers socket ownership to the SSH client.
  void ownClient(FutureOr<void> Function() release) {
    _ensureActive();
    _socketRelease = null;
    _clientRelease = release;
  }

  /// Adds the shell opened by the owned client.
  void ownShell(FutureOr<void> Function() release) {
    _ensureActive();
    _shellRelease = release;
  }

  /// Transfers all partial resources to a complete runtime owner.
  void ownRuntime(FutureOr<void> Function() release) {
    _ensureActive();
    _socketRelease = null;
    _clientRelease = null;
    _shellRelease = null;
    _runtimeRelease = release;
  }

  /// Transfers the complete runtime to its session registry.
  void commit() {
    _ensureActive();
    _finished = true;
    _clear();
  }

  /// Releases all resources still owned by this attempt; repeated calls are safe.
  Future<void> rollback() async {
    if (_finished) return;
    _finished = true;
    final releases = <FutureOr<void> Function()>[
      ?_runtimeRelease,
      ?_shellRelease,
      ?_clientRelease,
      ?_socketRelease,
    ];
    _clear();

    Object? firstError;
    StackTrace? firstStackTrace;
    for (final release in releases) {
      try {
        await release();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  void _ensureActive() {
    if (_finished) {
      throw StateError('SSH connection attempt ownership is already finished.');
    }
  }

  void _clear() {
    _runtimeRelease = null;
    _shellRelease = null;
    _clientRelease = null;
    _socketRelease = null;
  }
}

/// Per-session generation gate for concurrent SSH connection attempts.
///
/// A newer attempt or explicit cancellation immediately invalidates older
/// tokens. Finishing a stale token cannot remove a newer generation.
final class SshSessionConnectGate {
  final Map<String, int> _current = <String, int>{};
  int _nextToken = 0;

  /// Starts a new generation and invalidates an older attempt for the session.
  int begin(String sessionId) {
    final token = ++_nextToken;
    _current[sessionId] = token;
    return token;
  }

  /// Invalidates the current generation for one session.
  void cancel(String sessionId) {
    _current.remove(sessionId);
  }

  /// Invalidates every in-flight generation during owner shutdown.
  void cancelAll() {
    _current.clear();
  }

  /// Whether [token] still represents the latest generation for [sessionId].
  bool isCurrent(String sessionId, int token) => _current[sessionId] == token;

  /// Completes a generation without disturbing a newer token.
  void finish(String sessionId, int token) {
    if (isCurrent(sessionId, token)) _current.remove(sessionId);
  }
}
