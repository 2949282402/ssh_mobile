import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/background_service_lifecycle.dart';

void main() {
  test('startService false releases acquired locks immediately', () async {
    final events = <String>[];
    final lifecycle = BackgroundServiceLifecycle(
      isRunning: () async => false,
      startService: () async {
        events.add('start');
        return false;
      },
      stoppedEvents: () => const Stream<void>.empty(),
      requestStop: () {},
      acquirePowerLocks: () async => events.add('acquire'),
      releasePowerLocks: () async => events.add('release'),
    );

    expect(await lifecycle.start(), isFalse);

    expect(events, <String>['acquire', 'start', 'release']);
    expect(lifecycle.powerLocksHeld, isFalse);
  });

  test('start exception preserves failure and still releases locks', () async {
    var releases = 0;
    final lifecycle = BackgroundServiceLifecycle(
      isRunning: () async => false,
      startService: () => throw StateError('injected start failure'),
      stoppedEvents: () => const Stream<void>.empty(),
      requestStop: () {},
      acquirePowerLocks: () async {},
      releasePowerLocks: () async => releases++,
    );

    await expectLater(
      lifecycle.start(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'injected start failure',
        ),
      ),
    );
    expect(releases, 1);
  });

  test(
    'stop subscribes before request and awaits ACK before release',
    () async {
      final events = <String>[];
      final stopped = StreamController<void>(sync: true);
      var running = false;
      final lifecycle = BackgroundServiceLifecycle(
        isRunning: () async => running,
        startService: () async {
          running = true;
          return true;
        },
        stoppedEvents: () => stopped.stream,
        requestStop: () {
          events.add('request-stop');
          running = false;
          stopped.add(null);
        },
        acquirePowerLocks: () async => events.add('acquire'),
        releasePowerLocks: () async => events.add('release'),
      );

      expect(await lifecycle.start(), isTrue);
      expect(await lifecycle.stop(), isTrue);

      expect(events, <String>['acquire', 'request-stop', 'release']);
      expect(lifecycle.powerLocksHeld, isFalse);
      await stopped.close();
    },
  );

  test('stop timeout remains bounded and releases locks', () async {
    final stopped = StreamController<void>();
    var releases = 0;
    final lifecycle = BackgroundServiceLifecycle(
      isRunning: () async => true,
      startService: () async => true,
      stoppedEvents: () => stopped.stream,
      requestStop: () {},
      acquirePowerLocks: () async {},
      releasePowerLocks: () async => releases++,
      stopTimeout: const Duration(milliseconds: 1),
    );

    await lifecycle.start();
    expect(await lifecycle.stop(), isFalse);

    expect(releases, 1);
    expect(stopped.hasListener, isFalse);
    await stopped.close();
  });

  test('stop failure still releases locks and preserves first error', () async {
    var releases = 0;
    final lifecycle = BackgroundServiceLifecycle(
      isRunning: () async => true,
      startService: () async => true,
      stoppedEvents: () => const Stream<void>.empty(),
      requestStop: () => throw StateError('injected stop failure'),
      acquirePowerLocks: () async {},
      releasePowerLocks: () async => releases++,
    );

    await lifecycle.start();
    await expectLater(lifecycle.stop(), throwsA(isA<StateError>()));

    expect(releases, 1);
    expect(lifecycle.powerLocksHeld, isFalse);
  });

  test('failed lock release remains owned and can be retried', () async {
    var releaseAttempts = 0;
    final lifecycle = BackgroundServiceLifecycle(
      isRunning: () async => false,
      startService: () async => true,
      stoppedEvents: () => const Stream<void>.empty(),
      requestStop: () {},
      acquirePowerLocks: () async {},
      releasePowerLocks: () async {
        releaseAttempts++;
        if (releaseAttempts == 1) {
          throw StateError('injected release failure');
        }
      },
    );

    await lifecycle.start();
    await expectLater(lifecycle.stop(), throwsA(isA<StateError>()));
    expect(lifecycle.powerLocksHeld, isTrue);

    expect(await lifecycle.stop(), isTrue);
    expect(releaseAttempts, 2);
    expect(lifecycle.powerLocksHeld, isFalse);
  });
}
