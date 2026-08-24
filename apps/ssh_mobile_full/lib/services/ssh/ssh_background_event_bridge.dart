import 'dart:async';

/// Stream lookup used by the foreground SSH background-event bridge.
typedef SshBackgroundEventSource =
    Stream<Map<String, dynamic>?> Function(String event);

/// Owns foreground subscriptions to the background SSH isolate event bus.
///
/// Start/cancel transitions are serialized. A generation check drops callbacks
/// from an older subscription set as soon as cancellation begins, even if the
/// platform takes time to finish `StreamSubscription.cancel`.
final class SshBackgroundEventBridge {
  SshBackgroundEventBridge({
    required this.events,
    required this.onState,
    required this.onOutput,
    required this.onOverview,
    required this.onLog,
  });

  final SshBackgroundEventSource events;
  final void Function(Map<String, dynamic> data) onState;
  final void Function(Map<String, dynamic> data) onOutput;
  final void Function(Map<String, dynamic> data) onOverview;
  final void Function(Map<String, dynamic>? data) onLog;

  StreamSubscription<Map<String, dynamic>?>? _state;
  StreamSubscription<Map<String, dynamic>?>? _output;
  StreamSubscription<Map<String, dynamic>?>? _overview;
  StreamSubscription<Map<String, dynamic>?>? _log;
  Future<void> _transition = Future<void>.value();
  int _generation = 0;

  /// Number of event subscriptions currently owned by the bridge.
  int get activeSubscriptionCount => <Object?>[
    _state,
    _output,
    _overview,
    _log,
  ].where((subscription) => subscription != null).length;

  /// Replaces an older subscription set after its cancellation completes.
  Future<void> start() => _serialize(() async {
    await _cancelNow();
    final generation = ++_generation;
    try {
      _state = events('sshStateChanged').listen((data) {
        if (generation == _generation && data != null) onState(data);
      });
      _output = events('sshDataReceived').listen((data) {
        if (generation == _generation && data != null) onOutput(data);
      });
      _overview = events('sshOverviewUpdated').listen((data) {
        if (generation == _generation && data != null) onOverview(data);
      });
      _log = events('sshLogReceived').listen((data) {
        if (generation == _generation) onLog(data);
      });
    } catch (_) {
      await _cancelNow();
      rethrow;
    }
  });

  /// Invalidates callbacks immediately and awaits all subscription cleanup.
  Future<void> cancel() => _serialize(_cancelNow);

  Future<void> _cancelNow() async {
    _generation++;
    final subscriptions = <StreamSubscription<Map<String, dynamic>?>>[
      ?_state,
      ?_output,
      ?_overview,
      ?_log,
    ];
    _state = null;
    _output = null;
    _overview = null;
    _log = null;
    await Future.wait<void>(
      subscriptions.map((subscription) => subscription.cancel()),
    );
  }

  Future<void> _serialize(Future<void> Function() action) {
    final operation = _transition.then((_) => action());
    _transition = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }
}
