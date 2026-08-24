// System Admin Route Scope 的 SSH 建连与有界命令执行适配器。
//
// 该边界独立拥有每次 acquire 返回的管理 Lease；App Shell 注入的 Connection、
// Credential、Host Key Repository 和 native stream connector 均为借用资源。

// ignore_for_file: prefer_initializing_formals
// Public named parameters intentionally initialize private adapter fields.

import 'dart:async';
import 'dart:typed_data';

import 'package:connection_core/connection_core.dart' as connection_core;
import 'package:dartssh2/dartssh2.dart';
import 'package:feature_system_admin/feature_system_admin.dart' as admin;
import 'package:flutter/foundation.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import '../services/app_log_service.dart';
import '../services/remote_command_decoder.dart';

/// 测试与平台组合共用的最小 SSH client 建连边界。
typedef AppSystemAdminExecConnector =
    Future<AppSystemAdminExecClient> Function(
      connection_core.ConnectionConfig config,
      ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
    );

/// 将 App SSH Client 转换为不暴露 dartssh2 的 Feature Port。
final class AppSystemAdminSshAdapter implements admin.SystemAdminSshPort {
  /// 创建不拥有 Connection、Credential、Host Key Repository 或 SSH Client
  /// 的连接适配器。
  AppSystemAdminSshAdapter(
    this._connectionRepository, {
    required connection_core.CredentialRepository credentialRepository,
    required connection_core.HostKeyRepository hostKeyRepository,
    required AppLogService logger,
    ssh_core.SshNativeStreamConnector? nativeStreamConnector,
  }) : _clientFactory = ssh_core.SshClientFactory(
         credentialRepository: credentialRepository,
         hostKeyRepository: hostKeyRepository,
         logger: logger,
         nativeStreamConnector: nativeStreamConnector,
       ),
       _connector = null;

  /// 以可控建连边界验证 immutable target 与 Host Key generation。
  @visibleForTesting
  AppSystemAdminSshAdapter.forTesting(
    this._connectionRepository, {
    required AppSystemAdminExecConnector connector,
  }) : _connector = connector,
       _clientFactory = null;

  final connection_core.ConnectionRepository _connectionRepository;
  final ssh_core.SshClientFactory? _clientFactory;
  final AppSystemAdminExecConnector? _connector;

  @override
  Future<admin.SystemAdminSshLeasePort> acquire(
    ssh_core.SshTargetBinding target, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    if (!target.matches(_connectionRepository.getConnection(target.id))) {
      throw StateError('System Admin target changed before connection.');
    }

    final config = target.config;
    final boundConfirmation = _bindHostKeyConfirmation(
      target,
      onUnknownHostKey,
    );
    final injectedConnector = _connector;
    final AppSystemAdminExecClient execClient;
    if (injectedConnector != null) {
      execClient = await injectedConnector(config, boundConfirmation);
    } else {
      final clientFactory = _clientFactory!;
      final credentials = await clientFactory.loadCredentials(config);
      if (!target.matches(_connectionRepository.getConnection(target.id))) {
        throw StateError('System Admin target changed before connection.');
      }
      final sshClient = await clientFactory.connectClient(
        config,
        credentials: credentials,
        onUnknownHostKey: boundConfirmation,
      );
      execClient = _DartSystemAdminExecClient(sshClient);
    }
    final connectedTarget = ssh_core.SshTargetBinding.fromConfig(config);
    if (!connectedTarget.matches(
      _connectionRepository.getConnection(target.id),
    )) {
      execClient.close();
      throw StateError('System Admin target changed while connecting.');
    }
    return AppSystemAdminSshLease(execClient, targetBinding: connectedTarget);
  }

  ssh_core.SshHostKeyConfirmation? _bindHostKeyConfirmation(
    ssh_core.SshTargetBinding target,
    ssh_core.SshHostKeyConfirmation? confirmation,
  ) {
    if (confirmation == null) return null;
    return (request) async {
      if (!target.matches(_connectionRepository.getConnection(target.id))) {
        return false;
      }
      final accepted = await confirmation(request);
      return accepted &&
          target.matches(_connectionRepository.getConnection(target.id));
    };
  }
}

/// 管理命令 client 的最小生命周期边界；生产实现包装 dartssh2。
abstract interface class AppSystemAdminExecClient {
  Future<AppSystemAdminExecProcess> execute(String command);

  void close();
}

/// 管理命令 process 的流边界；敏感输入只允许写入 [stdin]。
abstract interface class AppSystemAdminExecProcess {
  StreamSink<Uint8List> get stdin;
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;
  int? get exitCode;

  void close();
}

// These two classes are a direct dart:io/dartssh2 platform shim. Their
// behavior is covered by dartssh2; business lifecycle coverage starts again at
// AppSystemAdminSshLease below.
// coverage:ignore-start
final class _DartSystemAdminExecClient implements AppSystemAdminExecClient {
  _DartSystemAdminExecClient(this._client);

  final SSHClient _client;

  @override
  Future<AppSystemAdminExecProcess> execute(String command) async {
    return _DartSystemAdminExecProcess(await _client.execute(command));
  }

  @override
  void close() => _client.close();
}

final class _DartSystemAdminExecProcess implements AppSystemAdminExecProcess {
  _DartSystemAdminExecProcess(this._session);

  final SSHSession _session;

  @override
  StreamSink<Uint8List> get stdin => _session.stdin;
  @override
  Stream<Uint8List> get stdout => _session.stdout;
  @override
  Stream<Uint8List> get stderr => _session.stderr;
  @override
  int? get exitCode => _session.exitCode;

  @override
  void close() => _session.close();
}
// coverage:ignore-end

/// Route Scope 专用管理 Lease；释放会关闭全部在途命令和底层 client。
final class AppSystemAdminSshLease implements admin.SystemAdminSshLeasePort {
  AppSystemAdminSshLease(this._client, {required this.targetBinding});

  final AppSystemAdminExecClient _client;
  final Set<AppSystemAdminExecProcess> _activeProcesses =
      <AppSystemAdminExecProcess>{};
  final Set<AppSystemAdminExecProcess> _cancelledProcesses =
      <AppSystemAdminExecProcess>{};

  @override
  final ssh_core.SshTargetBinding targetBinding;

  bool _released = false;

  @override
  bool get isReleased => _released;

  @override
  Future<ssh_core.RemoteCommandResult> run(
    admin.SystemAdminCommand command, {
    required Duration timeout,
  }) async {
    if (_released) throw StateError('System Admin SSH lease is released.');
    final stopwatch = Stopwatch()..start();
    AppSystemAdminExecProcess? process;
    try {
      final established = await _establishProcess(
        _renderCommand(command),
        _remaining(timeout, stopwatch),
      );
      process = established;
      if (_released) {
        _closeProcess(established);
        throw StateError('System Admin SSH lease is released.');
      }
      _activeProcesses.add(established);

      final input = command.standardInputBytes;
      if (input != null) established.stdin.add(input);
      await established.stdin.close().timeout(_remaining(timeout, stopwatch));

      final output = _BoundedSystemAdminOutput(
        admin.SystemAdminCommand.maxOutputBytes,
      );
      await Future.wait<void>([
        established.stdout.forEach(output.addStdout),
        established.stderr.forEach(output.addStderr),
      ], eagerError: true).timeout(_remaining(timeout, stopwatch));
      _throwIfCancelled(established);
      final decoded = await decodeRemoteCommandBytes(
        stdout: output.stdoutBytes,
        stderr: output.stderrBytes,
      ).timeout(_remaining(timeout, stopwatch));
      _throwIfCancelled(established);
      return ssh_core.RemoteCommandResult(
        exitCode: established.exitCode ?? -1,
        stdout: decoded.stdout,
        stderr: decoded.stderr,
      );
    } on admin.SystemAdminOutputLimitException {
      await _releaseIgnoringErrors();
      rethrow;
    } on TimeoutException {
      if (process != null && _cancelledProcesses.contains(process)) {
        throw const admin.SystemAdminCommandCancelledException();
      }
      await _releaseIgnoringErrors();
      throw const admin.SystemAdminCommandTimeoutException();
    } catch (_) {
      if (process != null && _cancelledProcesses.contains(process)) {
        throw const admin.SystemAdminCommandCancelledException();
      }
      rethrow;
    } finally {
      stopwatch.stop();
      if (process != null) {
        _activeProcesses.remove(process);
        _cancelledProcesses.remove(process);
        _closeProcess(process);
      }
    }
  }

  @override
  void cancelActiveCommands() {
    for (final process in List<AppSystemAdminExecProcess>.from(
      _activeProcesses,
    )) {
      _cancelledProcesses.add(process);
      _closeProcess(process);
    }
    _activeProcesses.clear();
  }

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    cancelActiveCommands();
    _client.close();
  }

  static String _renderCommand(admin.SystemAdminCommand command) {
    final script = command.shellScript;
    if (script != null) return script;
    return <String>[
      _quoteShellWord(command.executable!),
      ...command.arguments.map(_quoteShellWord),
    ].join(' ');
  }

  static String _quoteShellWord(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }

  Future<AppSystemAdminExecProcess> _establishProcess(
    String command,
    Duration timeout,
  ) async {
    final pending = _client.execute(command);
    try {
      return await pending.timeout(timeout);
    } on TimeoutException {
      unawaited(
        pending.then<void>(_closeProcess, onError: (Object _, StackTrace _) {}),
      );
      rethrow;
    }
  }

  static Duration _remaining(Duration timeout, Stopwatch stopwatch) {
    final remaining = timeout - stopwatch.elapsed;
    if (remaining <= Duration.zero) throw TimeoutException('command deadline');
    return remaining;
  }

  void _throwIfCancelled(AppSystemAdminExecProcess process) {
    if (_cancelledProcesses.contains(process)) {
      throw const admin.SystemAdminCommandCancelledException();
    }
  }

  Future<void> _releaseIgnoringErrors() async {
    try {
      await release();
    } catch (_) {
      // 安全错误必须保持稳定；释放异常不能泄漏输出或覆盖根因。
    }
  }

  static void _closeProcess(AppSystemAdminExecProcess process) {
    try {
      process.close();
    } catch (_) {
      // 单个 process 的关闭错误不能阻止其它命令和 client 释放。
    }
  }
}

final class _BoundedSystemAdminOutput {
  _BoundedSystemAdminOutput(this.maxBytes);

  final int maxBytes;
  final BytesBuilder _stdout = BytesBuilder(copy: false);
  final BytesBuilder _stderr = BytesBuilder(copy: false);
  int _length = 0;

  List<int> get stdoutBytes => _stdout.toBytes();
  List<int> get stderrBytes => _stderr.toBytes();

  void addStdout(Uint8List bytes) => _add(_stdout, bytes);
  void addStderr(Uint8List bytes) => _add(_stderr, bytes);

  void _add(BytesBuilder destination, Uint8List bytes) {
    if (bytes.length > maxBytes - _length) {
      throw admin.SystemAdminOutputLimitException(maxBytes: maxBytes);
    }
    _length += bytes.length;
    destination.add(bytes);
  }
}
