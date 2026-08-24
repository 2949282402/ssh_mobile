import 'dart:async';

/// Owns the UI-isolate foreground-service ACK and power-lock lifecycle.
///
/// Platform operations are injected so the ordering can be verified without a
/// native plugin. Start/stop calls are serialized, a failed `startService`
/// releases locks immediately, and stop always cancels its ACK subscription and
/// releases locks even when another cleanup step fails.
final class BackgroundServiceLifecycle {
  BackgroundServiceLifecycle({
    required this.isRunning,
    required this.startService,
    required this.stoppedEvents,
    required this.requestStop,
    required this.acquirePowerLocks,
    required this.releasePowerLocks,
    this.stopTimeout = const Duration(seconds: 60),
  });

  final Future<bool> Function() isRunning;
  final Future<bool> Function() startService;
  final Stream<void> Function() stoppedEvents;
  final FutureOr<void> Function() requestStop;
  final Future<void> Function() acquirePowerLocks;
  final Future<void> Function() releasePowerLocks;
  final Duration stopTimeout;

  Future<void> _transition = Future<void>.value();
  bool _powerLocksHeld = false;

  /// Whether this lifecycle owner currently holds the platform power locks.
  bool get powerLocksHeld => _powerLocksHeld;

  /// Acquires locks and starts the service, returning false on plugin refusal.
  Future<bool> start() => _serialize(_start);

  Future<bool> _start() async {
    if (!_powerLocksHeld) {
      await acquirePowerLocks();
      _powerLocksHeld = true;
    }

    try {
      if (await isRunning()) return true;
      final started = await startService();
      if (!started) await _releaseLocks();
      return started;
    } catch (error, stackTrace) {
      try {
        await _releaseLocks();
      } catch (_) {
        // Preserve the start failure; release is still attempted.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Requests stop and returns whether the isolate acknowledged before timeout.
  Future<bool> stop() => _serialize(_stop);

  Future<bool> _stop() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    var acknowledged = true;
    StreamSubscription<void>? subscription;

    Future<void> attempt(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    try {
      if (await isRunning()) {
        final stopped = Completer<void>();
        subscription = stoppedEvents().listen((_) {
          if (!stopped.isCompleted) stopped.complete();
        });
        await requestStop();
        try {
          await stopped.future.timeout(stopTimeout);
        } on TimeoutException {
          acknowledged = false;
        }
      }
    } catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    } finally {
      final ownedSubscription = subscription;
      if (ownedSubscription != null) {
        await attempt(ownedSubscription.cancel);
      }
      await attempt(_releaseLocks);
    }

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
    return acknowledged;
  }

  Future<void> _releaseLocks() async {
    if (!_powerLocksHeld) return;
    await releasePowerLocks();
    // 只有平台确认释放后才清除所有权；失败时保留状态，后续 stop 可重试，
    // 避免逻辑状态谎报“已释放”而永久遗留 wake/Wi-Fi lock。
    _powerLocksHeld = false;
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _transition = _transition.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
