import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });

  tearDownAll(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'construction failure does not start lazy pending initializers',
    () async {
      final events = <String>[];
      final repository = HangingConnectionRepository();
      final harness = await newRuntimeHarness(
        connectionRepository: repository,
        hostKeyRepository: FakeHostKeyRepository(),
        lanShareDatabaseFactory: () =>
            throw StateError('injected lan share failure'),
        disposeLogger: false,
        lifecycleObserver: events.add,
      );
      try {
        // Initializers start only after ownership transfers to a valid Runtime,
        // so a construction failure cannot leave a DB task behind cleanup.
        await expectLater(
          harness.createFuture.timeout(const Duration(seconds: 10)),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('injected lan share failure'),
            ),
          ),
        );
        // 回滚必须跑完整个优先级图，至少到达数据库(20)清理。
        final priorities = rollbackPriorities(events);
        expect(priorities, containsAll(<int>[80, 70, 60, 50, 40, 30, 20]));
        expect(repository.initializeCalls, 0);
      } finally {
        await harness.close();
      }
    },
  );

  test('construction failure rolls back in reverse priority order', () async {
    final events = <String>[];
    final harness = await newRuntimeHarness(
      lanShareDatabaseFactory: () =>
          throw StateError('injected lan share failure'),
      disposeLogger: false,
      lifecycleObserver: events.add,
    );
    try {
      await expectLater(harness.createFuture, throwsA(isA<StateError>()));

      final priorities = rollbackPriorities(events);
      expect(priorities, isNotEmpty);
      // 适配器(80) → Module(70) → Realtime(60) → SFTP(50) → SSH(40) →
      // metadata(35) → Network(30) → database(20) → settings(10)。
      expect(
        priorities.toSet(),
        containsAll(<int>[80, 70, 60, 50, 40, 35, 30, 20, 10]),
      );
      for (var i = 1; i < priorities.length; i++) {
        expect(
          priorities[i],
          lessThanOrEqualTo(priorities[i - 1]),
          reason: 'rollback must run in reverse priority order',
        );
      }
    } finally {
      await harness.close();
    }
  });

  test(
    'a throwing cleanup does not prevent later cleanups from running',
    () async {
      final events = <String>[];
      final network = FakeNetworkRuntime()
        ..disposeError = StateError('network dispose failed');
      final harness = await newRuntimeHarness(
        networkRuntime: network,
        lanShareDatabaseFactory: () =>
            throw StateError('injected lan share failure'),
        disposeLogger: false,
        lifecycleObserver: events.add,
      );
      try {
        await expectLater(harness.createFuture, throwsA(isA<StateError>()));

        // Network(30) dispose 抛错后，database(20)/settings(10) 仍被尝试。
        expect(network.disposeCalls, 1);
        final priorities = rollbackPriorities(events);
        expect(priorities, containsAll(<int>[20, 10]));
        // 后续优先级仍保持非递增，说明清理没有被 Network 的异常打断。
        final networkIndex = priorities.lastIndexOf(30);
        final databaseIndex = priorities.indexOf(20);
        expect(databaseIndex, greaterThan(networkIndex));
      } finally {
        await harness.close();
      }
    },
  );

  test(
    'original construction error is preserved over a cleanup error',
    () async {
      final network = FakeNetworkRuntime()
        ..disposeError = StateError('network dispose failed');
      final harness = await newRuntimeHarness(
        networkRuntime: network,
        lanShareDatabaseFactory: () =>
            throw StateError('injected construction failure'),
        disposeLogger: false,
      );
      try {
        await expectLater(
          harness.createFuture,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'injected construction failure',
            ),
          ),
        );
      } finally {
        await harness.close();
      }
    },
  );

  test('dispose releases resources in Module → Realtime → SFTP → SSH → '
      'Network → Database → Logger order', () async {
    final events = <String>[];
    final harness = await newRuntimeHarness(
      disposeLogger: true,
      lifecycleObserver: events.add,
    );
    try {
      final runtime = await harness.createFuture;
      await runtime.dispose();

      final starts = <String>[
        for (final event in events)
          if (event.endsWith('.start'))
            event.substring(0, event.length - '.start'.length),
      ];
      int indexOf(String name) {
        final index = starts.indexOf(name);
        expect(
          index,
          isNot(-1),
          reason: 'expected lifecycle start event $name in $starts',
        );
        return index;
      }

      final moduleIndex = indexOf('mcp-module.dispose');
      final realtimeIndex = indexOf('realtime.dispose');
      final sftpIndex = indexOf('sftp.dispose');
      final sshIndex = indexOf('ssh.close');
      final networkIndex = indexOf('network.dispose');
      final databaseIndex = indexOf('connection-database.dispose');
      final loggerIndex = indexOf('app-log.dispose');

      expect(moduleIndex, lessThan(realtimeIndex));
      expect(realtimeIndex, lessThan(sftpIndex));
      expect(sftpIndex, lessThan(sshIndex));
      expect(sshIndex, lessThan(networkIndex));
      expect(networkIndex, lessThan(databaseIndex));
      expect(databaseIndex, lessThan(loggerIndex));
    } finally {
      await harness.close();
    }
  });
}
