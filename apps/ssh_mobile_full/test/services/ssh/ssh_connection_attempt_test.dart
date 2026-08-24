import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/ssh/ssh_connection_attempt.dart';

void main() {
  group('SshConnectionAttemptOwner', () {
    test('rolls back partial resources in reverse ownership order', () async {
      final releases = <String>[];
      final owner = SshConnectionAttemptOwner()
        ..ownSocket(() => releases.add('socket'))
        ..ownClient(() => releases.add('client'))
        ..ownShell(() => releases.add('shell'));

      await owner.rollback();
      await owner.rollback();

      expect(releases, <String>['shell', 'client']);
    });

    test('runtime adoption replaces every partial release', () async {
      final releases = <String>[];
      final owner = SshConnectionAttemptOwner()
        ..ownSocket(() => releases.add('socket'))
        ..ownClient(() => releases.add('client'))
        ..ownShell(() => releases.add('shell'))
        ..ownRuntime(() async => releases.add('runtime'));

      await owner.rollback();

      expect(releases, <String>['runtime']);
    });

    test('one cleanup failure does not skip remaining resources', () async {
      final releases = <String>[];
      final owner = SshConnectionAttemptOwner()
        ..ownClient(() => releases.add('client'))
        ..ownShell(() {
          releases.add('shell');
          throw StateError('injected shell close failure');
        });

      await expectLater(owner.rollback(), throwsA(isA<StateError>()));

      expect(releases, <String>['shell', 'client']);
    });

    test('commit transfers ownership and rejects later mutation', () async {
      var releases = 0;
      final owner = SshConnectionAttemptOwner()
        ..ownClient(() => releases++)
        ..commit();

      await owner.rollback();

      expect(releases, 0);
      expect(() => owner.ownSocket(() {}), throwsA(isA<StateError>()));
    });

    test('socket remains owned until a client adopts it', () async {
      var socketReleases = 0;
      final owner = SshConnectionAttemptOwner()
        ..ownSocket(() => socketReleases++);

      await owner.rollback();

      expect(socketReleases, 1);
    });
  });

  group('SshSessionConnectGate', () {
    test('new generation supersedes old and stale finish is harmless', () {
      final gate = SshSessionConnectGate();
      final first = gate.begin('session-1');
      final second = gate.begin('session-1');

      expect(gate.isCurrent('session-1', first), isFalse);
      expect(gate.isCurrent('session-1', second), isTrue);

      gate.finish('session-1', first);
      expect(gate.isCurrent('session-1', second), isTrue);

      gate.finish('session-1', second);
      expect(gate.isCurrent('session-1', second), isFalse);
    });

    test('cancel is isolated by session and cancelAll invalidates all', () {
      final gate = SshSessionConnectGate();
      final first = gate.begin('session-1');
      final second = gate.begin('session-2');

      gate.cancel('session-1');
      expect(gate.isCurrent('session-1', first), isFalse);
      expect(gate.isCurrent('session-2', second), isTrue);

      gate.cancelAll();
      expect(gate.isCurrent('session-2', second), isFalse);
    });
  });
}
