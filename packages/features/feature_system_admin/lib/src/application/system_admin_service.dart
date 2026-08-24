// System Admin 管理命令 Service。
//
// Service 负责管理会话、root 校验、命令编排和资源释放；连接、日志和
// Host Key 处理均通过 Port 注入，不直接创建 App Scope 基础设施。

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:ssh_core/ssh_core.dart';

import '../domain/system_admin_models.dart';
import '../domain/system_admin_ports.dart';
import '../presentation/system_power_confirm_flow.dart';
import 'system_admin_parsers.dart';

part 'system_admin_account_operations.dart';
part 'system_admin_inspection_operations.dart';
part 'system_admin_power_operations.dart';

class SystemAdminService extends ChangeNotifier {
  SystemAdminService({required this._sshPort, required this._logger});

  final SystemAdminSshPort _sshPort;
  final SystemAdminLoggerPort _logger;

  SystemAdminSshLeasePort? _activeLease;
  SystemAdminSshLeasePort? _pendingLease;
  SystemAdminSessionTarget? _activeTarget;
  SshTargetBinding? _pendingTarget;
  bool _isConnecting = false;
  bool _isConnected = false;
  String? _errorMessage;
  bool _isRoot = false;
  bool _closed = false;
  int _connectionGeneration = 0;
  Future<void>? _closeFuture;
  final Set<Future<void>> _inFlightConnects = <Future<void>>{};
  final Set<Future<void>> _inFlightAcquisitions = <Future<void>>{};
  final LinkedHashMap<String, DateTime> _consumedPowerTokenNonces =
      LinkedHashMap<String, DateTime>();

  static const Duration _acquisitionTimeout = Duration(seconds: 20);
  static const Duration _connectionDrainTimeout = Duration(seconds: 21);
  static const int powerTokenRegistryCapacity = 256;

  String? get connectionId => _activeTarget?.connectionId ?? _pendingTarget?.id;
  SystemAdminSessionTarget? get activeTarget =>
      isConnected ? _activeTarget : null;
  bool get isConnecting => _isConnecting;
  bool get isConnected =>
      _isConnected &&
      _isRoot &&
      _activeLease != null &&
      !_activeLease!.isReleased &&
      _activeTarget != null;
  String? get errorMessage => _errorMessage;
  bool get isRoot => _isRoot && isConnected;

  /// 建立绑定到不可变目标的 root 管理 Lease。
  Future<void> connect(
    SshTargetBinding target, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) {
    final operation = _connectTarget(
      target,
      onUnknownHostKey: onUnknownHostKey,
    );
    _inFlightConnects.add(operation);
    unawaited(
      operation.then<void>(
        (_) => _inFlightConnects.remove(operation),
        onError: (Object _, StackTrace _) {
          _inFlightConnects.remove(operation);
        },
      ),
    );
    return operation;
  }

  Future<void> _connectTarget(
    SshTargetBinding target, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    if (_closed) throw StateError('System Admin service has been closed.');
    final currentTarget = _activeTarget;
    if (isConnected &&
        currentTarget != null &&
        currentTarget.binding.fingerprint == target.fingerprint) {
      return;
    }

    final generation = ++_connectionGeneration;
    final previous = _detachActiveLease();
    final previousPending = _detachPendingLease();
    _pendingTarget = target;
    _isConnecting = true;
    _isConnected = false;
    _isRoot = false;
    _errorMessage = null;
    _notifyIfOpen();
    await _releaseLease(previous);
    await _releaseLease(previousPending);
    if (!_isCurrentGeneration(generation)) return;

    SystemAdminSshLeasePort? candidate;
    try {
      _logger.info('System Admin connecting to ${target.id}...');
      final boundHostKeyConfirmation = onUnknownHostKey == null
          ? null
          : (SshHostKeyPromptRequest request) async {
              if (!_isCurrentGeneration(generation)) return false;
              final accepted = await onUnknownHostKey(request);
              return accepted && _isCurrentGeneration(generation);
            };
      candidate = await _acquireLease(
        target,
        onUnknownHostKey: boundHostKeyConfirmation,
      );
      if (!_isCurrentGeneration(generation)) {
        await _releaseLease(candidate);
        return;
      }
      if (!_acceptsAcquiredTarget(target, candidate.targetBinding)) {
        throw StateError('System Admin acquired a different remote target.');
      }
      _pendingLease = candidate;

      final result = await candidate.run(
        SystemAdminCommand.argv('id', arguments: const <String>['-u']),
        timeout: const Duration(seconds: 10),
      );
      if (!_isCurrentGeneration(generation)) {
        _clearPendingLease(candidate);
        await _releaseLease(candidate);
        return;
      }
      if (result.exitCode != 0 || result.stdout.trim() != '0') {
        throw StateError('Insufficient privileges: Root access required');
      }

      _clearPendingLease(candidate);
      _activeTarget = SystemAdminSessionTarget(
        binding: candidate.targetBinding,
        generation: generation,
      );
      _activeLease = candidate;
      candidate = null;
      _pendingTarget = null;
      _isRoot = true;
      _isConnected = true;
      _isConnecting = false;
      _logger.info('System Admin connected to ${target.id} as root');
      _notifyIfOpen();
    } catch (error, stackTrace) {
      _clearPendingLease(candidate);
      await _releaseLease(candidate);
      if (!_isCurrentGeneration(generation)) return;
      _pendingTarget = null;
      _isConnecting = false;
      _isConnected = false;
      _isRoot = false;
      _errorMessage = error.toString().replaceAll('Exception: ', '');
      _logger.error(
        'System Admin connection failed to ${target.id}',
        error: error,
        stackTrace: stackTrace,
      );
      _notifyIfOpen();
    }
  }

  Future<SystemAdminSshLeasePort> _acquireLease(
    SshTargetBinding target, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    var timedOut = false;
    final acquisition = _sshPort.acquire(
      target,
      onUnknownHostKey: onUnknownHostKey,
    );
    late final Future<void> acquisitionSettlement;
    acquisitionSettlement = acquisition.then<void>((lease) async {
      if (timedOut) await _releaseLease(lease);
    }, onError: (Object _, StackTrace _) {});
    _inFlightAcquisitions.add(acquisitionSettlement);
    unawaited(
      acquisitionSettlement.then<void>(
        (_) => _inFlightAcquisitions.remove(acquisitionSettlement),
        onError: (Object _, StackTrace _) {
          _inFlightAcquisitions.remove(acquisitionSettlement);
        },
      ),
    );
    try {
      return await acquisition.timeout(_acquisitionTimeout);
    } on TimeoutException {
      timedOut = true;
      throw const SystemAdminConnectionTimeoutException();
    }
  }

  /// 断开当前目标，并使全部在途连接和命令结果失效。
  Future<void> disconnect() async {
    if (_closed) return;
    ++_connectionGeneration;
    final lease = _detachActiveLease();
    final pendingLease = _detachPendingLease();
    _pendingTarget = null;
    _isConnecting = false;
    _isConnected = false;
    _isRoot = false;
    _errorMessage = null;
    _notifyIfOpen();
    await _releaseLease(lease);
    await _releaseLease(pendingLease);
  }

  void cancelActiveCommands() {
    _activeLease?.cancelActiveCommands();
    _pendingLease?.cancelActiveCommands();
  }

  /// 当前目标是否仍是同一个 connection/target/session generation。
  bool isActiveTarget(SystemAdminSessionTarget target) {
    final current = _activeTarget;
    return isConnected && current != null && current.matches(target);
  }

  Future<RemoteCommandResult> _runCommand(
    SystemAdminSessionTarget target,
    SystemAdminCommand command, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final lease = _requireActiveLease(target);
    try {
      final result = await lease.run(command, timeout: timeout);
      if (!isActiveTarget(target) || lease.isReleased) {
        throw StateError('System Admin target or session changed.');
      }
      return result;
    } on SystemAdminOutputLimitException catch (error) {
      await _invalidateTargetAfterFatalCommand(target, error);
      rethrow;
    } on SystemAdminCommandTimeoutException catch (error) {
      await _invalidateTargetAfterFatalCommand(target, error);
      rethrow;
    }
  }

  SystemAdminSshLeasePort _requireActiveLease(
    SystemAdminSessionTarget expected,
  ) {
    final current = _activeTarget;
    final lease = _activeLease;
    if (!isConnected || current == null || lease == null) {
      throw StateError('Not connected to a root management session.');
    }
    if (!current.matches(expected)) {
      throw StateError('System Admin target or session changed.');
    }
    return lease;
  }

  Future<void> _invalidateTargetAfterFatalCommand(
    SystemAdminSessionTarget target,
    Object error,
  ) async {
    final current = _activeTarget;
    if (current == null || !current.matches(target)) return;
    ++_connectionGeneration;
    final lease = _detachActiveLease();
    _isConnecting = false;
    _isConnected = false;
    _isRoot = false;
    _errorMessage = error.toString();
    _notifyIfOpen();
    await _releaseLease(lease);
  }

  Future<bool> checkRootPrivilege(SystemAdminSessionTarget target) async {
    return isActiveTarget(target) && _isRoot;
  }

  SystemAdminSshLeasePort? _detachActiveLease() {
    final lease = _activeLease;
    lease?.cancelActiveCommands();
    _activeLease = null;
    _activeTarget = null;
    return lease;
  }

  SystemAdminSshLeasePort? _detachPendingLease() {
    final lease = _pendingLease;
    lease?.cancelActiveCommands();
    _pendingLease = null;
    return lease;
  }

  void _clearPendingLease(SystemAdminSshLeasePort? lease) {
    if (identical(_pendingLease, lease)) _pendingLease = null;
  }

  Future<void> _releaseLease(SystemAdminSshLeasePort? lease) async {
    if (lease == null || lease.isReleased) return;
    try {
      await lease.release();
    } catch (error, stackTrace) {
      _logger.error(
        'Failed to release a System Admin SSH lease',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  bool _isCurrentGeneration(int generation) =>
      !_closed && generation == _connectionGeneration;

  bool _acceptsAcquiredTarget(
    SshTargetBinding requested,
    SshTargetBinding acquired,
  ) {
    if (requested.fingerprint == acquired.fingerprint) return true;
    if (requested.hostKeyFingerprint != null ||
        acquired.hostKeyFingerprint == null) {
      return false;
    }
    final upgraded = requested.config;
    upgraded.hostKeyFingerprint = acquired.hostKeyFingerprint;
    upgraded.hostKeyAlgorithm = acquired.hostKeyAlgorithm;
    return SshTargetBinding.fromConfig(upgraded).fingerprint ==
        acquired.fingerprint;
  }

  void _notifyIfOpen() {
    if (!_closed) notifyListeners();
  }

  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    final future = _closeResources();
    _closeFuture = future;
    return future;
  }

  Future<void> _closeResources() async {
    if (_closed) return;
    _closed = true;
    ++_connectionGeneration;
    final lease = _detachActiveLease();
    final pendingLease = _detachPendingLease();
    _pendingTarget = null;
    _isConnecting = false;
    _isConnected = false;
    _isRoot = false;
    _errorMessage = null;
    _consumedPowerTokenNonces.clear();
    await _releaseLease(lease);
    await _releaseLease(pendingLease);
    await _drainInFlightConnections();
  }

  Future<void> _drainInFlightConnections() async {
    final pending = <Future<void>>[
      ..._inFlightConnects,
      ..._inFlightAcquisitions,
    ];
    if (pending.isEmpty) return;
    try {
      await Future.wait<void>(pending).timeout(_connectionDrainTimeout);
    } on TimeoutException {
      _logger.warning(
        'Timed out draining System Admin SSH acquisition operations',
      );
    }
  }

  @override
  void dispose() {
    if (!_closed) unawaited(close());
    super.dispose();
  }
}
