import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:ssh_mobile/services/ssh_service.dart';
import '../test_utils/test_storage_adapter.dart';
import 'package:ssh_mobile/services/app_log_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SshService Log Bridge', () {
    late TestStorageAdapter storageService;
    late SshService sshService;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      storageService = TestStorageAdapter();
      sshService = createTestSshService(storageService);
      AppLogService.instance.clear();
    });

    tearDown(() async {
      await sshService.close();
      await storageService.shutdown();
      storageService.dispose();
      debugDefaultTargetPlatformOverride = null;
      AppLogService.instance.clear();
    });

    test(
      'bridges background service logs with redacted details and normalizedLevel',
      () {
        sshService.handleBackgroundLog({
          'level': 'service',
          'message': 'TMUX session initialized',
          'details': 'sessionId=123 tmux=true host=example.com',
        });

        expect(AppLogService.instance.entries.length, 1);
        final entry = AppLogService.instance.entries.first;
        expect(entry.message, '[Background] TMUX session initialized');
        expect(entry.normalizedLevel, AppLogLevel.service);
        expect(entry.details, 'sessionId=123 tmux=true [REDACTED]=[REDACTED]');
      },
    );

    test('does not retain SSH targets, identities, commands, or secrets', () {
      const host = 'ops-bridge.example.test';
      const username = 'deploy-user';
      const command =
          'ssh -p 2222 deploy-user@ops-bridge.example.test "cat /home/'
          'deploy-user/.ssh/id_rsa"';
      const token = 'bridge-token-placeholder';
      const password = 'bridge-password-placeholder';

      sshService.handleBackgroundLog({
        'level': 'service',
        'message':
            'SSH command failed host=$host username=$username command=$command',
        'details':
            'host=$host username=$username command=$command token=$token '
            'password=$password',
      });

      final entry = AppLogService.instance.entries.single;
      final diagnostics = [entry.message, entry.details, entry.text].join('\n');

      for (final fragment in [host, username, command, token, password]) {
        expect(
          diagnostics,
          isNot(contains(fragment)),
          reason: 'plaintext sensitive fragment leaked: $fragment',
        );
      }
      expect(diagnostics, contains('[REDACTED]'));
    });

    test('defaults to info level if none specified', () {
      sshService.handleBackgroundLog({
        'message': 'A background message without level',
      });

      expect(AppLogService.instance.entries.length, 1);
      final entry = AppLogService.instance.entries.first;
      expect(entry.message, '[Background] A background message without level');
      expect(entry.normalizedLevel, AppLogLevel.info);
      expect(entry.details, isNull);
    });

    test('coalesces concurrent connects for the same session id', () async {
      final first = sshService.connect(
        'missing-connection',
        sessionId: 'shared-session',
      );
      final second = sshService.connect(
        'missing-connection',
        sessionId: 'shared-session',
      );

      expect(identical(first, second), isTrue);
      await first;
    });

    test(
      'rejects a concurrent target change for the same session id',
      () async {
        final first = sshService.connect(
          'missing-connection-a',
          sessionId: 'shared-session',
        );

        await expectLater(
          sshService.connect(
            'missing-connection-b',
            sessionId: 'shared-session',
          ),
          throwsA(isA<StateError>()),
        );
        await first;
      },
    );

    test('close is awaitable, idempotent, and rejects late connects', () async {
      final first = sshService.close();
      final second = sshService.close();

      expect(identical(first, second), isTrue);
      await first;
      expect(sshService.activeSubscriptionCount, 0);
      expect(sshService.activeTimerCount, 0);
      expect(sshService.leaseCount, 0);

      await expectLater(
        sshService.connect('missing-connection', sessionId: 'late-session'),
        throwsA(isA<StateError>()),
      );
    });

    test('close waits for an in-flight pooled session creation', () async {
      final sessionGate = Completer<ssh_core.SshSession>();
      final acquire = sshService.acquire(
        sessionId: 'pooled-session',
        create: () => sessionGate.future,
      );
      final acquireExpectation = expectLater(
        acquire,
        throwsA(isA<StateError>()),
      );
      var closeCompleted = false;
      final closing = sshService.close().whenComplete(
        () => closeCompleted = true,
      );

      await Future<void>.delayed(Duration.zero);
      expect(closeCompleted, isFalse);

      sessionGate.complete(
        ssh_core.SshSession(
          id: 'pooled-session',
          connectionId: 'connection-1',
          connectionName: 'Server',
        ),
      );
      await acquireExpectation;
      await closing;
      expect(closeCompleted, isTrue);
    });
  });
}
