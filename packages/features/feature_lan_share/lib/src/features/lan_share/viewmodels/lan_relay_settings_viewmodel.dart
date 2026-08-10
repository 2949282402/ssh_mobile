// Relay 设置页的路由级状态和异步操作编排。

import 'package:flutter/foundation.dart';
import 'package:network_sdk/network_sdk.dart';

import '../services/lan_receiver_coordinator.dart';

/// Relay 设置页 ViewModel；不保存 enrollment token 或任何 credential。
final class LanRelaySettingsViewModel extends ChangeNotifier {
  /// 使用共享 Receiver Coordinator 创建一个设置路由状态。
  LanRelaySettingsViewModel(this.coordinator) {
    coordinator.addListener(_onCoordinatorChanged);
  }

  /// App Scope 唯一的 LAN Receiver/Relay Owner。
  final LanReceiverCoordinator coordinator;

  bool _busy = false;
  NetworkError? _error;
  bool _disposed = false;

  /// 当前 Relay 状态快照。
  LanRelayStatus get status => coordinator.relayStatus;

  /// 设置操作是否正在进行。
  bool get busy => _busy;

  /// 最近一次操作失败的安全错误。
  NetworkError? get error => _error;

  /// 保存 endpoint；提供 token 时同时执行 enrollment 和连接。
  Future<NetworkResult<void>> save({
    required String host,
    required int port,
    String enrollmentToken = '',
  }) async {
    if (_busy) return _busyFailure(NetworkOperation.connectRelay);
    final normalizedHost = host.trim();
    if (normalizedHost.isEmpty ||
        normalizedHost.contains('://') ||
        normalizedHost.contains('/') ||
        port < 1 ||
        port > 65535) {
      return _setFailure(
        const NetworkError(
          code: NetworkErrorCode.invalidArgument,
          message: 'A host/IP and a port from 1 to 65535 are required.',
          operation: NetworkOperation.connectRelay,
        ),
      );
    }
    final endpoint = Uri(scheme: 'https', host: normalizedHost, port: port);
    return _run(() async {
      if (enrollmentToken.trim().isEmpty) {
        return coordinator.saveRelayEndpoint(endpoint);
      }
      return coordinator.enrollRelay(
        endpoint: endpoint,
        enrollmentToken: enrollmentToken,
      );
    });
  }

  /// 使用安全存储中的现有 enrollment 连接 Relay。
  Future<NetworkResult<void>> connect() =>
      _run(coordinator.connectConfiguredRelay);

  /// 主动断开 socket，但保留 endpoint 和 enrollment。
  Future<NetworkResult<void>> disconnect() => _run(coordinator.disconnectRelay);

  /// 断开并清除 endpoint/credential。
  Future<NetworkResult<void>> clear() => _run(coordinator.clearRelayEnrollment);

  Future<NetworkResult<void>> _run(
    Future<NetworkResult<void>> Function() operation,
  ) async {
    if (_busy) return _busyFailure(NetworkOperation.connectRelay);
    _busy = true;
    _error = null;
    _notify();
    try {
      final result = await operation();
      if (result is NetworkFailure<void>) _error = result.error;
      return result;
    } finally {
      _busy = false;
      _notify();
    }
  }

  NetworkFailure<void> _setFailure(NetworkError error) {
    _error = error;
    _notify();
    return NetworkFailure<void>(error);
  }

  NetworkFailure<void> _busyFailure(NetworkOperation operation) =>
      NetworkFailure<void>(
        NetworkError(
          code: NetworkErrorCode.cancelled,
          message: 'Relay operation is already in progress.',
          operation: operation,
        ),
      );

  void _onCoordinatorChanged() => _notify();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    coordinator.removeListener(_onCoordinatorChanged);
    super.dispose();
  }
}
