// Full App System Admin SSH adapter 的 argv/stdin 与输出硬上限测试。

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:connection_core/connection_core.dart';
import 'package:feature_system_admin/feature_system_admin.dart' as admin;
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart';
import 'package:ssh_mobile/app/system_admin_feature_adapters.dart';

void main() {
  test('adapter rejects a stale target before opening a client', () async {
    final repository = _FakeConnectionRepository();
    final target = _target();
    var connectorCalls = 0;
    final adapter = AppSystemAdminSshAdapter.forTesting(
      repository,
      connector: (_, _) async {
        connectorCalls++;
        return _StaticExecClient(_FakeExecProcess());
      },
    );

    await expectLater(adapter.acquire(target), throwsStateError);
    expect(connectorCalls, 0);
  });

  test(
    'adapter binds Host Key confirmation and returns the exact target',
    () async {
      final config = _target().config;
      final repository = _FakeConnectionRepository()..current = config;
      SshHostKeyConfirmation? capturedConfirmation;
      final client = _StaticExecClient(_FakeExecProcess());
      final adapter = AppSystemAdminSshAdapter.forTesting(
        repository,
        connector: (candidate, confirmation) async {
          expect(candidate.id, config.id);
          capturedConfirmation = confirmation;
          return client;
        },
      );
      var prompts = 0;

      final lease = await adapter.acquire(
        SshTargetBinding.fromConfig(config),
        onUnknownHostKey: (_) async {
          prompts++;
          return true;
        },
      );
      final request = _hostKeyRequest(config);
      expect(await capturedConfirmation!(request), isTrue);
      expect(prompts, 1);
      expect(lease.targetBinding.matches(repository.current), isTrue);

      repository.current = config.copyWith(host: 'changed.example.test');
      expect(await capturedConfirmation!(request), isFalse);
      expect(prompts, 1);
      await lease.release();
      expect(client.closed, isTrue);
    },
  );

  test(
    'adapter closes a client when the target changes during connect',
    () async {
      final config = _target().config;
      final repository = _FakeConnectionRepository()..current = config;
      final client = _StaticExecClient(_FakeExecProcess());
      final adapter = AppSystemAdminSshAdapter.forTesting(
        repository,
        connector: (_, confirmation) async {
          expect(confirmation, isNull);
          repository.current = config.copyWith(port: config.port + 1);
          return client;
        },
      );

      await expectLater(
        adapter.acquire(SshTargetBinding.fromConfig(config)),
        throwsStateError,
      );
      expect(client.closed, isTrue);
    },
  );

  test(
    'argv is quoted per word and password bytes use only process stdin',
    () async {
      final process = _FakeExecProcess();
      final client = _FakeExecClient(process);
      final lease = AppSystemAdminSshLease(client, targetBinding: _target());
      final input = Uint8List.fromList(
        utf8.encode(r'''operator:S3cr'et;$HOME
'''),
      );

      final result = await lease.run(
        admin.SystemAdminCommand.argv(
          'printf',
          arguments: <String>["a'b", '; touch /tmp/pwned'],
          standardInputBytes: input,
        ),
        timeout: const Duration(seconds: 1),
      );

      expect(result.exitCode, 0);
      expect(client.executedCommands.single, contains("'printf'"));
      expect(client.executedCommands.single, contains("'a'\"'\"'b'"));
      expect(client.executedCommands.single, contains("'; touch /tmp/pwned'"));
      expect(client.executedCommands.single, isNot(contains('S3cr')));
      expect(process.stdinBytes, input);
      expect(process.stdinClosed, isTrue);

      await lease.release();
    },
  );

  test(
    'combined stdout and stderr over the hard cap closes the lease',
    () async {
      final process = _FakeExecProcess(
        stdoutChunks: <Uint8List>[
          Uint8List(admin.SystemAdminCommand.maxOutputBytes),
        ],
        stderrChunks: <Uint8List>[
          Uint8List.fromList(utf8.encode('remote-secret-output')),
        ],
      );
      final client = _FakeExecClient(process);
      final lease = AppSystemAdminSshLease(client, targetBinding: _target());

      Object? failure;
      try {
        await lease.run(
          admin.SystemAdminCommand.argv('journalctl'),
          timeout: const Duration(seconds: 1),
        );
      } catch (error) {
        failure = error;
      }

      expect(failure, isA<admin.SystemAdminOutputLimitException>());
      expect(
        failure.toString(),
        'System Admin command output exceeded the '
        '${admin.SystemAdminCommand.maxOutputBytes}-byte limit.',
      );
      expect(failure.toString(), isNot(contains('remote-secret-output')));
      expect(lease.isReleased, isTrue);
      expect(client.closed, isTrue);
      expect(process.closeCount, greaterThan(0));
    },
  );

  test('execute setup timeout releases a process that arrives late', () async {
    final pending = Completer<AppSystemAdminExecProcess>();
    final client = _DelayedExecClient(pending.future);
    final lease = AppSystemAdminSshLease(client, targetBinding: _target());

    await expectLater(
      lease.run(
        admin.SystemAdminCommand.argv('who'),
        timeout: const Duration(milliseconds: 5),
      ),
      throwsA(isA<admin.SystemAdminCommandTimeoutException>()),
    );
    expect(lease.isReleased, isTrue);
    expect(client.closed, isTrue);

    final lateProcess = _FakeExecProcess();
    pending.complete(lateProcess);
    await Future<void>.delayed(Duration.zero);
    expect(lateProcess.closeCount, 1);
  });

  test('cancelled command cannot return partial output as success', () async {
    final process = _ControlledExecProcess();
    final client = _StaticExecClient(process);
    final lease = AppSystemAdminSshLease(client, targetBinding: _target());

    final command = lease.run(
      admin.SystemAdminCommand.argv('who'),
      timeout: const Duration(seconds: 1),
    );
    await process.outputListening;
    lease.cancelActiveCommands();

    await expectLater(
      command,
      throwsA(isA<admin.SystemAdminCommandCancelledException>()),
    );
    expect(lease.isReleased, isFalse);
    await lease.release();
  });
}

SshTargetBinding _target() => SshTargetBinding.fromConfig(
  ConnectionConfig(
    id: 'server-a',
    name: 'Server A',
    host: 'server-a.example.test',
    username: 'root',
  ),
);

final class _FakeExecClient implements AppSystemAdminExecClient {
  _FakeExecClient(this.process);

  final _FakeExecProcess process;
  final List<String> executedCommands = <String>[];
  bool closed = false;

  @override
  Future<AppSystemAdminExecProcess> execute(String command) async {
    executedCommands.add(command);
    return process;
  }

  @override
  void close() {
    closed = true;
  }
}

final class _DelayedExecClient implements AppSystemAdminExecClient {
  _DelayedExecClient(this.pendingProcess);

  final Future<AppSystemAdminExecProcess> pendingProcess;
  bool closed = false;

  @override
  Future<AppSystemAdminExecProcess> execute(String command) => pendingProcess;

  @override
  void close() {
    closed = true;
  }
}

final class _StaticExecClient implements AppSystemAdminExecClient {
  _StaticExecClient(this.process);

  final AppSystemAdminExecProcess process;
  bool closed = false;

  @override
  Future<AppSystemAdminExecProcess> execute(String command) async => process;

  @override
  void close() {
    closed = true;
  }
}

final class _FakeConnectionRepository implements ConnectionRepository {
  ConnectionConfig? current;

  @override
  List<ConnectionConfig> get connections => [
    if (current case final value?) value,
  ];

  @override
  ConnectionConfig? getConnection(String id) =>
      current?.id == id ? current : null;

  @override
  Future<void> initialize() async {}
  @override
  Future<List<ConnectionConfig>> loadConnections() async => connections;
  @override
  Future<void> addConnection(ConnectionConfig config) async => current = config;
  @override
  Future<void> updateConnection(ConnectionConfig config) async =>
      current = config;
  @override
  Future<void> deleteConnection(String id) async => current = null;
  @override
  Future<void> deleteConnections(List<String> ids) async => current = null;
  @override
  Future<void> reorderConnections(int oldIndex, int newIndex) async {}
}

SshHostKeyPromptRequest _hostKeyRequest(ConnectionConfig config) =>
    SshHostKeyPromptRequest(
      connectionId: config.id,
      connectionName: config.name,
      host: config.host,
      port: config.port,
      username: config.username,
      algorithm: 'ssh-ed25519',
      fingerprint: 'aa:bb',
    );

final class _ControlledExecProcess implements AppSystemAdminExecProcess {
  final StreamController<Uint8List> _stdin = StreamController<Uint8List>();
  late final StreamController<Uint8List> _stdout;
  final StreamController<Uint8List> _stderr = StreamController<Uint8List>();
  final Completer<void> _outputListening = Completer<void>();
  bool _closed = false;

  _ControlledExecProcess() {
    _stdout = StreamController<Uint8List>(
      onListen: () => _outputListening.complete(),
    );
    _stdin.stream.listen((_) {});
  }

  Future<void> get outputListening => _outputListening.future;

  @override
  StreamSink<Uint8List> get stdin => _stdin.sink;

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  int? get exitCode => null;

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(_stdout.close());
    unawaited(_stderr.close());
  }
}

final class _FakeExecProcess implements AppSystemAdminExecProcess {
  _FakeExecProcess({
    this.stdoutChunks = const <Uint8List>[],
    this.stderrChunks = const <Uint8List>[],
  }) {
    _stdinController.stream.listen(
      stdinBytes.addAll,
      onDone: () => stdinClosed = true,
    );
  }

  final List<Uint8List> stdoutChunks;
  final List<Uint8List> stderrChunks;
  final StreamController<Uint8List> _stdinController =
      StreamController<Uint8List>();
  final List<int> stdinBytes = <int>[];
  bool stdinClosed = false;
  int closeCount = 0;

  @override
  StreamSink<Uint8List> get stdin => _stdinController.sink;

  @override
  Stream<Uint8List> get stdout => Stream<Uint8List>.fromIterable(stdoutChunks);

  @override
  Stream<Uint8List> get stderr => Stream<Uint8List>.fromIterable(stderrChunks);

  @override
  int? get exitCode => 0;

  @override
  void close() {
    closeCount++;
  }
}
