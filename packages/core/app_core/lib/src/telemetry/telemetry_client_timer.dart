part of 'telemetry_client.dart';

/// Callback used by [TelemetryTimerFactory].
typedef TelemetryTimerCallback = FutureOr<void> Function();

/// Small timer contract owned by [TelemetryClient].
abstract interface class TelemetryTimer {
  bool get isActive;

  void cancel();
}

/// Creates one-shot and periodic timers for telemetry state machines.
abstract interface class TelemetryTimerFactory {
  TelemetryTimer schedule(Duration delay, TelemetryTimerCallback callback);

  TelemetryTimer schedulePeriodic(
    Duration interval,
    TelemetryTimerCallback callback,
  );
}

/// Default timer adapter backed by `dart:async`.
final class DartTelemetryTimerFactory implements TelemetryTimerFactory {
  const DartTelemetryTimerFactory();

  @override
  TelemetryTimer schedule(Duration delay, TelemetryTimerCallback callback) {
    return _DartTelemetryTimer(
      Timer(delay, () => unawaited(_swallowTimerErrors(callback))),
    );
  }

  @override
  TelemetryTimer schedulePeriodic(
    Duration interval,
    TelemetryTimerCallback callback,
  ) {
    return _DartTelemetryTimer(
      Timer.periodic(interval, (_) => unawaited(_swallowTimerErrors(callback))),
    );
  }
}

Future<void> _swallowTimerErrors(TelemetryTimerCallback callback) async {
  try {
    await callback();
  } on Object {
    // Timer callbacks are background work. Client diagnostics capture errors;
    // a timer must never surface an unhandled zone error.
  }
}

final class _DartTelemetryTimer implements TelemetryTimer {
  const _DartTelemetryTimer(this._timer);

  final Timer _timer;

  @override
  bool get isActive => _timer.isActive;

  @override
  void cancel() => _timer.cancel();
}
