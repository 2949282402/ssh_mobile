import 'dart:async';

import 'package:connection_core/connection_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart';

void main() {
  group('SshSessionManagerImpl', () {
    test(
      'concurrent ensureInitialized calls share one initialization',
      () async {
        final runtime = _FakeRuntime();
        final manager = SshSessionManagerImpl(
          runtime: runtime,
          sessionPool: SshSessionPool(idleTimeout: Duration.zero),
        );

        final first = manager.ensureInitialized();
        final second = manager.ensureInitialized();
        expect(identical(first, second), isTrue);
        runtime.completeInitialization();
        await Future.wait([first, second]);
        expect(runtime.initializeCount, 1);
        expect(manager.initialized, isTrue);

        await manager.close();
        expect(runtime.disposeCount, 1);
        await manager.close();
        expect(runtime.disposeCount, 1);
      },
    );

    test('initialization failure resets state and can retry', () async {
      final runtime = _FakeRuntime(failFirstInitialization: true);
      final manager = SshSessionManagerImpl(runtime: runtime);

      await expectLater(manager.ensureInitialized(), throwsStateError);
      expect(manager.initialized, isFalse);
      final retry = manager.ensureInitialized();
      runtime.completeInitialization();
      await retry;
      expect(manager.initialized, isTrue);
      expect(runtime.initializeCount, 2);
      await manager.close();
    });

    test(
      'multiple consumers share a session and idle cleanup closes its stream',
      () async {
        final runtime = _FakeRuntime();
        final manager = SshSessionManagerImpl(
          runtime: runtime,
          sessionPool: SshSessionPool(
            idleTimeout: const Duration(milliseconds: 10),
          ),
        );
        var creates = 0;
        final firstFuture = manager.acquire(
          sessionId: 'session-a',
          create: () async {
            creates++;
            return SshSession(
              id: 'session-a',
              connectionId: 'connection-a',
              connectionName: 'Server A',
            );
          },
        );
        runtime.completeInitialization();
        final first = await firstFuture;
        final done = Completer<void>();
        first.session.output.listen((_) {}, onDone: done.complete);
        final second = await manager.acquire(
          sessionId: 'session-a',
          create: () async {
            creates++;
            return SshSession(
              id: 'session-a',
              connectionId: 'connection-a',
              connectionName: 'Server A',
            );
          },
        );

        expect(identical(first.session, second.session), isTrue);
        expect(creates, 1);
        await first.release();
        expect(second.isReleased, isFalse);
        await second.release();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await done.future;

        await manager.close();
      },
    );

    test('pool exposes idle timer count for lifecycle diagnostics', () async {
      final pool = SshSessionPool(
        idleTimeout: const Duration(milliseconds: 20),
      );
      final lease = await pool.acquire(
        sessionId: 'session-a',
        create: () async => SshSession(
          id: 'session-a',
          connectionId: 'connection-a',
          connectionName: 'Server A',
        ),
      );

      expect(pool.idleTimerCount, 0);
      await lease.release();
      expect(pool.idleTimerCount, 1);
      await pool.close();
      expect(pool.idleTimerCount, 0);
    });
  });

  group('SshClientFactory contracts', () {
    test('answers one hidden password prompt only', () {
      final responses =
          SshClientFactory.keyboardInteractiveResponsesForPassword(
            const _KeyboardRequest([_KeyboardPrompt('Password: ', false)]),
            'secret',
          );
      expect(responses, ['secret']);
      expect(
        SshClientFactory.keyboardInteractiveResponsesForPassword(
          const _KeyboardRequest([
            _KeyboardPrompt('Password: ', false),
            _KeyboardPrompt('Verification code: ', false),
          ]),
          'secret',
        ),
        isNull,
      );
    });

    test('target binding excludes secrets and detects route edits', () {
      final config = ConnectionConfig(
        id: 'connection-a',
        name: 'Server A',
        host: 'EXAMPLE.com',
        username: 'root',
        password: 'secret',
        privateKey: 'private-key',
      );
      final binding = SshTargetBinding.fromConfig(config);
      expect(binding.fingerprint, isNot(contains('secret')));
      expect(binding.config.password, isNull);
      expect(binding.config.privateKey, isNull);
      expect(binding.matches(config), isTrue);
      expect(
        binding.matches(config.copyWith(host: 'other.example.com')),
        isFalse,
      );
    });
  });
}

final class _FakeRuntime implements SshRuntimeAdapter {
  _FakeRuntime({this.failFirstInitialization = false});

  final bool failFirstInitialization;
  final StreamController<SshRuntimeEvent> _events =
      StreamController<SshRuntimeEvent>.broadcast();
  Completer<void>? _initializationCompleter;
  int initializeCount = 0;
  int disposeCount = 0;

  @override
  bool get supportsBackgroundService => false;

  @override
  Stream<SshRuntimeEvent> get events => _events.stream;

  @override
  Future<void> ensureInitialized() {
    initializeCount++;
    if (failFirstInitialization && initializeCount == 1) {
      return Future<void>.error(StateError('initialization failed'));
    }
    final completer = Completer<void>();
    _initializationCompleter = completer;
    return completer.future;
  }

  void completeInitialization() {
    _initializationCompleter?.complete();
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    await _events.close();
  }
}

final class _KeyboardRequest {
  const _KeyboardRequest(this.prompts);

  final List<_KeyboardPrompt> prompts;
}

final class _KeyboardPrompt {
  const _KeyboardPrompt(this.promptText, this.echo);

  final String promptText;
  final bool echo;
}
