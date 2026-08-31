import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ssh_mobile/services/terminal_session_metadata_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('persists, replaces, sorts, and removes terminal metadata', () async {
    final store = TerminalSessionMetadataStore();
    addTearDown(store.dispose);
    final firstTime = DateTime.utc(2026, 1, 1);
    final secondTime = firstTime.add(const Duration(minutes: 1));

    final first = RestorableTmuxSession(
      sessionId: 'session-1',
      connectionId: 'connection-1',
      displayName: 'First',
      tmuxSessionName: 'first',
      fontSize: 13,
      updatedAt: firstTime,
    );
    final replacement = RestorableTmuxSession(
      sessionId: 'session-1',
      connectionId: 'connection-2',
      displayName: 'Replacement',
      tmuxSessionName: 'replacement',
      fontSize: 15,
      updatedAt: secondTime,
    );
    await store.saveRestorableTmuxSession(first);
    await store.saveRestorableTmuxSession(replacement);
    expect(
      (await store.loadRestorableTmuxSessions()).single.displayName,
      'Replacement',
    );

    final older = TerminalHistoryRecord(
      sessionId: 'history-1',
      connectionId: 'connection-1',
      connectionName: 'Server',
      displayName: 'Older',
      tmuxSessionName: null,
      state: 'disconnected',
      errorMessage: 'network',
      createdAt: firstTime,
      updatedAt: firstTime,
    );
    final newer = TerminalHistoryRecord(
      sessionId: 'history-2',
      connectionId: 'connection-1',
      connectionName: 'Server',
      displayName: 'Newer',
      tmuxSessionName: 'tmux-2',
      state: 'connected',
      errorMessage: null,
      createdAt: secondTime,
      updatedAt: secondTime,
    );
    await store.saveTerminalHistoryRecord(older);
    await store.saveTerminalHistoryRecord(newer);
    expect(
      (await store.loadTerminalHistoryRecords()).map(
        (record) => record.sessionId,
      ),
      ['history-2', 'history-1'],
    );

    await store.removeTerminalHistoryRecord('history-1');
    expect(
      (await store.loadTerminalHistoryRecords()).single.sessionId,
      'history-2',
    );
    await store.replaceTerminalHistoryRecords([older, newer]);
    expect(
      (await store.loadTerminalHistoryRecords()).first.sessionId,
      'history-2',
    );

    await store.removeRestorableTmuxSessionsForConnection('connection-2');
    expect(await store.loadRestorableTmuxSessions(), isEmpty);
    await store.clearRestorableTmuxSessions();

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(TerminalSessionMetadataStore.restorableSessionsKey),
      isNull,
    );
    expect(
      prefs.getString(TerminalSessionMetadataStore.historyRecordsKey),
      contains('history-2'),
    );
  });

  test('decodes persisted records and safely ignores malformed data', () async {
    final now = DateTime.utc(2026, 2, 1);
    SharedPreferences.setMockInitialValues({
      TerminalSessionMetadataStore.restorableSessionsKey: jsonEncode([
        {
          'sessionId': 'session-1',
          'connectionId': 'connection-1',
          'fontSize': 18,
          'updatedAt': now.toIso8601String(),
        },
        'ignored',
      ]),
      TerminalSessionMetadataStore.historyRecordsKey: '{invalid-json',
    });
    final store = TerminalSessionMetadataStore();
    addTearDown(store.dispose);

    final restorable = await store.loadRestorableTmuxSessions();
    expect(restorable.single.sessionId, 'session-1');
    expect(restorable.single.displayName, 'SSH');
    expect(restorable.single.tmuxSessionName, 'ssh_mobile');
    expect(restorable.single.fontSize, 18);
    expect(await store.loadTerminalHistoryRecords(), isEmpty);

    final first = store.initialize();
    expect(identical(first, store.initialize()), isTrue);
    await store.initFuture;
  });

  test('round-trips JSON defaults and dispose is idempotent', () async {
    final restorable = RestorableTmuxSession.fromJson(<String, dynamic>{});
    expect(restorable.sessionId, isEmpty);
    expect(restorable.connectionId, isEmpty);
    expect(restorable.displayName, 'SSH');
    expect(restorable.tmuxSessionName, 'ssh_mobile');
    expect(restorable.fontSize, 14);
    expect(restorable.toJson(), containsPair('sessionId', isEmpty));

    final history = TerminalHistoryRecord.fromJson(<String, dynamic>{});
    expect(history.connectionName, 'SSH');
    expect(history.displayName, 'SSH');
    expect(history.state, 'disconnected');
    expect(history.tmuxSessionName, isNull);
    expect(history.errorMessage, isNull);
    expect(history.toJson(), containsPair('state', 'disconnected'));

    final store = TerminalSessionMetadataStore();
    await store.initialize();
    await store.dispose();
    await store.dispose();
    expect(await store.loadRestorableTmuxSessions(), isEmpty);
  });
}
