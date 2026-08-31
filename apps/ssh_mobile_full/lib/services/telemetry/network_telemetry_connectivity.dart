import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

/// Platform connectivity input used by the App Scope telemetry owner.
///
/// Keeping the input behind a small contract makes the transition semantics
/// testable without making [TelemetryClient] depend on a platform plugin.
abstract interface class TelemetryConnectivitySource {
  Future<bool> readConnectivity();

  Stream<bool> get changes;
}

/// [connectivity_plus] adapter used by the production App Scope.
final class PlatformTelemetryConnectivitySource
    implements TelemetryConnectivitySource {
  PlatformTelemetryConnectivitySource({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  @override
  Future<bool> readConnectivity() async {
    final results = await _connectivity.checkConnectivity();
    return _hasConnectivity(results);
  }

  @override
  Stream<bool> get changes =>
      _connectivity.onConnectivityChanged.map(_hasConnectivity).distinct();

  static bool _hasConnectivity(Iterable<ConnectivityResult> results) {
    return results.any((result) => result != ConnectivityResult.none);
  }
}

/// Converts platform connectivity changes into telemetry recovery triggers.
///
/// A false-to-true transition invokes [TelemetryClient.onNetworkRecovered]. An
/// initially online client is treated as recovered once so a backlog from a
/// previous process can flush without waiting for the periodic timer.
final class TelemetryConnectivityMonitor {
  TelemetryConnectivityMonitor({required this.client, required this.source});

  final TelemetryClient client;
  final TelemetryConnectivitySource source;

  StreamSubscription<bool>? _subscription;
  Future<void>? _startFuture;
  bool? _connected;
  int _observedChangeCount = 0;
  bool _started = false;
  bool _disposed = false;

  /// Starts the monitor once; concurrent callers share the same operation.
  Future<void> start() {
    if (_disposed) return Future<void>.value();
    final inFlight = _startFuture;
    if (inFlight != null) return inFlight;

    final operation = _start();
    late final Future<void> tracked;
    tracked = operation.whenComplete(() {
      if (identical(_startFuture, tracked)) _startFuture = null;
    });
    _startFuture = tracked;
    return tracked;
  }

  Future<void> _start() async {
    if (_started || _disposed) return;
    _started = true;
    try {
      _subscription = source.changes.listen(
        _handleConnectivity,
        onError: _handleSourceError,
      );
    } on Object {
      // A platform stream can be unavailable on a partially initialized host;
      // the periodic telemetry timer remains the fallback flush mechanism.
    }

    final changesAtReadStart = _observedChangeCount;
    try {
      final connected = await source.readConnectivity();
      if (!_disposed && changesAtReadStart == _observedChangeCount) {
        final wasConnected = _connected;
        _connected = connected;
        if (wasConnected == null && connected) {
          client.onNetworkRecovered();
        }
      }
    } on Object {
      // Treat the first subsequent online event as recovery when the initial
      // platform query is unavailable.
      if (!_disposed && changesAtReadStart == _observedChangeCount) {
        _connected = false;
      }
    }
  }

  void _handleConnectivity(bool connected) {
    if (_disposed) return;
    _observedChangeCount++;
    final wasConnected = _connected;
    _connected = connected;
    if ((wasConnected == false || wasConnected == null) && connected) {
      client.onNetworkRecovered();
    }
  }

  void _handleSourceError(Object error, StackTrace stackTrace) {}

  /// Stops the platform subscription and prevents late recovery callbacks.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) await subscription.cancel();
  }
}
