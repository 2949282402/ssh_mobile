import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/app_runtime_initialization_owner.dart';

void main() {
  test(
    'registration is lazy and normal wait joins every initializer',
    () async {
      final started = <String>[];
      final first = Completer<void>();
      final owner = AppRuntimeInitializationOwner(onError: (_, _, _) {});
      owner.add(
        description: 'first',
        start: (_) async {
          started.add('first');
          await first.future;
        },
      );
      owner.add(description: 'second', start: (_) => started.add('second'));

      expect(started, isEmpty);
      owner.start();
      await Future<void>.delayed(Duration.zero);
      expect(started, <String>['first', 'second']);

      var waitCompleted = false;
      final wait = owner.wait().then((_) => waitCompleted = true);
      await Future<void>.delayed(Duration.zero);
      expect(waitCompleted, isFalse);
      first.complete();
      await wait;
      expect(waitCompleted, isTrue);
    },
  );

  test('ordinary task error is reported without failing the barrier', () async {
    final reports = <String>[];
    final owner = AppRuntimeInitializationOwner(
      onError: (description, _, _) => reports.add(description),
    );
    owner.add(
      description: 'injected initializer',
      start: (_) => throw StateError('injected failure'),
    );

    owner.start();
    await owner.wait();

    expect(reports, <String>['injected initializer']);
  });

  test(
    'cancel runs all callbacks in reverse and awaits cooperative task',
    () async {
      final events = <String>[];
      final owner = AppRuntimeInitializationOwner(
        cancellationTimeout: const Duration(milliseconds: 1),
        onError: (description, _, _) => events.add(description),
      );
      owner.add(
        description: 'first',
        start: (signal) async {
          await signal.whenCancelled;
          events.add('task-settled');
        },
        cancel: () => events.add('cancel-first'),
      );
      owner.add(
        description: 'second',
        start: (_) => Completer<void>().future,
        cancel: () {
          events.add('cancel-second');
          throw StateError('injected cancel failure');
        },
      );
      owner.start();

      final settled = await owner.cancelAndWait();

      expect(settled, isFalse);
      expect(events.take(3), <String>[
        'cancel-second',
        'Runtime initializer cancellation failed',
        'cancel-first',
      ]);
      expect(events, contains('task-settled'));
    },
  );

  test('bounded cancellation suppresses errors that arrive later', () async {
    final task = Completer<void>();
    final reports = <String>[];
    final owner = AppRuntimeInitializationOwner(
      cancellationTimeout: const Duration(milliseconds: 1),
      onError: (description, _, _) => reports.add(description),
    );
    owner.add(description: 'late task', start: (_) => task.future);
    owner.start();

    expect(await owner.cancelAndWait(), isFalse);
    task.completeError(StateError('late failure'));
    await Future<void>.delayed(Duration.zero);

    expect(reports, isEmpty);
    expect(await owner.cancelAndWait(), isFalse);
  });

  test(
    'cancelling before start prevents task access and later registration',
    () async {
      var starts = 0;
      final owner = AppRuntimeInitializationOwner(onError: (_, _, _) {});
      owner.add(description: 'never starts', start: (_) => starts++);

      expect(await owner.cancelAndWait(), isTrue);
      owner.start();

      expect(starts, 0);
      expect(
        () => owner.add(description: 'late', start: (_) {}),
        throwsA(isA<StateError>()),
      );
    },
  );
}
