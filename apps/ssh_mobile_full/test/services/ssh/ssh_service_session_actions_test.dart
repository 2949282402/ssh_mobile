import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ssh_mobile/services/ssh_service.dart';

import 'ssh_service_scenario_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SshService session actions and history', () {
    late SshServiceScenarioHarness harness;

    setUp(() async {
      harness = SshServiceScenarioHarness();
      await harness.setUp();
    });

    tearDown(() async {
      await harness.tearDown();
    });

    test('failed open cleans up and returns null', () async {
      await harness.ssh.ensureInitialized();

      final sessionId = await harness.ssh.openSession('missing-connection');

      expect(sessionId, isNull);
      expect(harness.ssh.getSession('missing-connection-any'), isNull);
    });

    test(
      'history metadata, rename, font size, and disconnect cover session actions',
      () async {
        await harness.ssh.ensureInitialized();
        harness.pendingConnects.add(
          harness.ssh.connect('missing-connection', sessionId: 's1'),
        );
        harness.pendingConnects.add(
          harness.ssh.connect('missing-connection', sessionId: 's2'),
        );
        for (final pending in harness.pendingConnects) {
          await pending;
        }
        final first = harness.ssh.getSession('s1')!;
        final second = harness.ssh.getSession('s2')!;
        first.state = SshConnectionState.connected;
        second.state = SshConnectionState.connected;
        first.tmuxSessionName = 'restorable-tmux';

        harness.ssh.resizeTerminal('s1', 120, 40);
        harness.ssh.sendData('s1', 'echo hello\r');
        harness.ssh.sendBytes('s1', Uint8List.fromList(<int>[1, 2, 3]));

        expect(harness.ssh.renameSession('s1', 'Renamed Window'), isTrue);
        expect(first.displayName, 'Renamed Window');
        expect(harness.ssh.renameSession('s2', 'Renamed Window'), isFalse);
        expect(harness.ssh.renameSession('missing', 'ignored'), isFalse);
        expect(harness.ssh.renameSession('s1', '   '), isFalse);

        harness.ssh.setSessionFontSize('s1', 999);
        expect(first.fontSize, SshSession.maxTerminalFontSize);
        harness.ssh.setSessionFontSize('missing', 10);

        expect(await harness.ssh.loadSessionHistoryText('s1'), isEmpty);
        final record = TerminalHistoryRecord(
          sessionId: 's1',
          connectionId: first.connectionId,
          connectionName: first.connectionName,
          displayName: first.displayName,
          tmuxSessionName: first.tmuxSessionName,
          state: first.state.name,
          errorMessage: first.errorMessage,
          createdAt: first.createdAt,
          updatedAt: first.updatedAt,
        );
        await harness.storage.saveTerminalHistoryRecord(record);
        final records = await harness.ssh.loadTerminalHistoryRecords();
        expect(records, hasLength(1));
        expect(records.single.sessionId, 's1');
        await harness.ssh.removeTerminalHistoryRecord('s1');
        expect(await harness.ssh.loadTerminalHistoryRecords(), isEmpty);

        expect(harness.ssh.hasConnectedSession(first.connectionId), isTrue);
        expect(
          harness.ssh.latestSessionForConnection(first.connectionId)?.id,
          's2',
        );
        expect(harness.ssh.sessionCountForConnection(first.connectionId), 2);

        await harness.ssh.disconnectSession('s1');
        expect(harness.ssh.getSession('s1'), isNull);
        await harness.ssh.disconnectSessionsForConnection(first.connectionId);
        expect(harness.ssh.sessions, isEmpty);
        expect(harness.ssh.hasConnectedSession(first.connectionId), isFalse);
        expect(harness.ssh.sessionCountForConnection(first.connectionId), 0);
      },
    );
  });
}
