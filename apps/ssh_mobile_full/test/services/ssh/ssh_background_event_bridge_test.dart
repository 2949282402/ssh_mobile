import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/ssh/ssh_background_event_bridge.dart';

void main() {
  test(
    'owns all event subscriptions and drops callbacks after cancel',
    () async {
      final source = _EventSource();
      final states = <Map<String, dynamic>>[];
      final outputs = <Map<String, dynamic>>[];
      final overviews = <Map<String, dynamic>>[];
      final logs = <Map<String, dynamic>?>[];
      final bridge = SshBackgroundEventBridge(
        events: source.events,
        onState: states.add,
        onOutput: outputs.add,
        onOverview: overviews.add,
        onLog: logs.add,
      );

      await bridge.start();
      expect(bridge.activeSubscriptionCount, 4);

      source.add('sshStateChanged', {'state': 'connected'});
      source.add('sshDataReceived', {'data': 'output'});
      source.add('sshOverviewUpdated', {'windowCount': 1});
      source.add('sshLogReceived', {'message': 'ready'});
      expect(states, hasLength(1));
      expect(outputs, hasLength(1));
      expect(overviews, hasLength(1));
      expect(logs, hasLength(1));

      await bridge.cancel();
      expect(bridge.activeSubscriptionCount, 0);
      source.add('sshStateChanged', {'state': 'late'});
      expect(states, hasLength(1));

      await bridge.cancel();
      await source.close();
    },
  );

  test(
    'restart replaces rather than duplicates the subscription set',
    () async {
      final source = _EventSource();
      var stateCallbacks = 0;
      final bridge = SshBackgroundEventBridge(
        events: source.events,
        onState: (_) => stateCallbacks++,
        onOutput: (_) {},
        onOverview: (_) {},
        onLog: (_) {},
      );

      await Future.wait<void>(<Future<void>>[bridge.start(), bridge.start()]);
      expect(bridge.activeSubscriptionCount, 4);

      source.add('sshStateChanged', {'state': 'connected'});
      expect(stateCallbacks, 1);

      await bridge.cancel();
      await source.close();
    },
  );
}

final class _EventSource {
  final Map<String, StreamController<Map<String, dynamic>?>> _controllers = {};

  Stream<Map<String, dynamic>?> events(String event) => _controllers
      .putIfAbsent(
        event,
        () => StreamController<Map<String, dynamic>?>.broadcast(sync: true),
      )
      .stream;

  void add(String event, Map<String, dynamic>? data) {
    _controllers[event]!.add(data);
  }

  Future<void> close() => Future.wait<void>(
    _controllers.values.map((controller) => controller.close()),
  );
}
