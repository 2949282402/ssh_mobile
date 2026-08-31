import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/ssh_service.dart';

void main() {
  test('session summaries compare by value and provide empty fallbacks', () {
    const empty = SshConnectionOverview.empty;
    expect(empty, SshConnectionOverview.empty);
    expect(empty.hashCode, SshConnectionOverview.empty.hashCode);
    expect(
      SshConnectionOverview(
        count: 1,
        latestState: SshConnectionState.connected,
        hasConnected: true,
      ),
      isNot(empty),
    );
    expect(
      const SshServerOverviewSnapshot.empty().forConnection('missing'),
      SshConnectionOverview.empty,
    );
    const populated = SshServerOverviewSnapshot(
      byConnection: {
        'server-a': SshConnectionOverview(
          count: 1,
          latestState: SshConnectionState.connected,
          hasConnected: true,
        ),
      },
      windowCount: 1,
    );
    expect(populated, populated);
    expect(populated.hashCode, populated.hashCode);
    expect(
      populated,
      isNot(const SshServerOverviewSnapshot(byConnection: {}, windowCount: 1)),
    );
  });

  test('session caches output, trims overflow, and emits each chunk', () async {
    final controller = StreamController<String>.broadcast();
    final session = SshSession(
      id: 'session-1',
      connectionId: 'server-1',
      connectionName: 'Server',
      outputController: controller,
      tmuxSessionName: "tmux-'quoted",
    );
    final emitted = <String>[];
    final subscription = session.output.listen(emitted.add);

    session.addOutput('hello');
    expect(session.outputText, 'hello');
    expect(session.outputText, 'hello');
    expect(session.estimatedMemoryBytes, 10);
    expect(session.isConnected, isFalse);
    session.state = SshConnectionState.connected;
    expect(session.isConnected, isTrue);
    expect(
      session.tmuxKillCommand,
      "tmux kill-session -t 'tmux-'\"'\"'quoted'",
    );

    final oversized = 'x' * SshSession.maxOutputCacheChars;
    session.addOutput(oversized);
    expect(session.outputText, oversized);
    expect(session.estimatedMemoryBytes, SshSession.maxOutputCacheChars * 2);

    final overflowSession = SshSession(
      id: 'session-2',
      connectionId: 'server-1',
      connectionName: 'Server',
      outputController: StreamController<String>.broadcast(),
    );
    addTearDown(overflowSession.close);
    overflowSession.addOutput('a' * 150000);
    overflowSession.addOutput('b' * 100000);
    expect(overflowSession.outputText.length, SshSession.maxOutputCacheChars);
    expect(overflowSession.outputText, startsWith('a' * 100000));
    expect(overflowSession.outputText, endsWith('b' * 100000));

    final fullChunkSession = SshSession(
      id: 'session-2b',
      connectionId: 'server-1',
      connectionName: 'Server',
      outputController: StreamController<String>.broadcast(),
    );
    addTearDown(fullChunkSession.close);
    fullChunkSession.addOutput('a' * 50000);
    fullChunkSession.addOutput('b' * 150000);
    fullChunkSession.addOutput('c' * 50000);
    expect(fullChunkSession.outputText.length, SshSession.maxOutputCacheChars);
    expect(fullChunkSession.outputText, startsWith('b' * 150000));
    expect(fullChunkSession.outputText, endsWith('c' * 50000));

    final disconnected = SshSession(
      id: 'session-3',
      connectionId: 'server-1',
      connectionName: 'Server',
      outputController: StreamController<String>.broadcast(),
    );
    addTearDown(disconnected.close);
    expect(disconnected.tmuxKillCommand, isNull);
    disconnected.tmuxSessionName = '';
    expect(disconnected.tmuxKillCommand, isNull);

    await pumpEventQueue();
    expect(emitted, ['hello', oversized]);
    await session.close();
    await subscription.cancel();
  });

  test('remote command result preserves nullable exit codes', () {
    const result = RemoteCommandResult(
      exitCode: null,
      stdout: 'out',
      stderr: 'err',
    );
    expect(result.exitCode, isNull);
    expect(result.stdout, 'out');
    expect(result.stderr, 'err');
  });
}
