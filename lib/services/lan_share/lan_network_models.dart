// v1 LAN 网络结果、错误与事件模型。
//
// 将 LAN 专属数据与传输实现分离，使调用方可以使用类型化结果，
// 而不依赖 HTTP 细节。

import 'dart:async';

import '../network/network_models.dart';

/// 描述 v1 LAN 配对握手结果。
final class LanHandshakeData {
  /// 使用相互验证状态创建配对结果。
  const LanHandshakeData({required this.pendingRemote});

  /// 远端设备是否仍需完成相互配对。
  final bool pendingRemote;
}

/// 描述 v1 LAN 广播或邀请返回的端点。
final class LanPairingEndpoint {
  /// 创建远端端点描述。
  const LanPairingEndpoint({this.remoteDeviceId, this.remotePort});

  /// 远端端点广播的设备标识。
  final String? remoteDeviceId;

  /// 远端端点广播的 HTTP(S) 端口。
  final int? remotePort;
}

/// 报告一个 LAN 对端的 WebSocket 连接变化。
final class LanConnectionStateChanged {
  /// 创建类型化 LAN 连接状态事件。
  const LanConnectionStateChanged({
    required this.deviceId,
    required this.connected,
  });

  /// 发生连接变化的对端。
  final String deviceId;

  /// 对端当前是否已连接。
  final bool connected;
}

/// 携带 LAN 操作产生的安全结构化错误。
final class LanNetworkException implements Exception {
  /// 创建可转换为 [NetworkError] 的 LAN 异常。
  const LanNetworkException(
    this.message, {
    this.code = NetworkErrorCode.ioError,
    this.operation,
    this.peerId,
    this.statusCode,
  });

  /// 不包含凭据或原始载荷的安全诊断信息。
  final String message;

  /// 稳定错误分类。
  final NetworkErrorCode code;

  /// 产生错误的操作。
  final String? operation;

  /// 已知时表示受影响的对端。
  final String? peerId;

  /// 适用时表示导致错误的 HTTP 状态码。
  final int? statusCode;

  /// 将此异常转换为公开网络错误模型。
  NetworkError toNetworkError({
    String? fallbackOperation,
    String? fallbackPeerId,
  }) => NetworkError(
    code: code,
    message: message,
    operation: operation ?? fallbackOperation,
    peerId: peerId ?? fallbackPeerId,
  );

  /// 返回可供日志和 UI 适配层使用的安全诊断文本。
  @override
  String toString() => message;
}

/// 将 HTTP 状态映射为稳定的 v1 LAN 错误分类。
NetworkErrorCode lanHttpErrorCode(int statusCode) {
  if (statusCode == 400 || statusCode == 413) {
    return NetworkErrorCode.invalidArgument;
  }
  if (statusCode == 401 || statusCode == 403 || statusCode == 426) {
    return NetworkErrorCode.authenticationFailed;
  }
  if (statusCode == 408 || statusCode == 504) {
    return NetworkErrorCode.timeout;
  }
  if (statusCode == 404) return NetworkErrorCode.noRoute;
  return NetworkErrorCode.ioError;
}

/// 将捕获的 LAN 失败映射为稳定公开错误，并隐藏底层细节。
NetworkError lanNetworkError(
  Object error, {
  required String operation,
  String? peerId,
}) {
  if (error is LanNetworkException) {
    return error.toNetworkError(
      fallbackOperation: operation,
      fallbackPeerId: peerId,
    );
  }
  if (error is FormatException) {
    return NetworkError(
      code: NetworkErrorCode.invalidArgument,
      message: 'LAN response format is invalid.',
      operation: operation,
      peerId: peerId,
    );
  }
  if (error is NetworkError) {
    return error.copyWith(
      operation: error.operation ?? operation,
      peerId: error.peerId ?? peerId,
    );
  }
  return NetworkError(
    code: error is TimeoutException
        ? NetworkErrorCode.timeout
        : NetworkErrorCode.ioError,
    message: error is TimeoutException
        ? 'LAN operation timed out.'
        : 'LAN operation failed.',
    operation: operation,
    peerId: peerId,
  );
}
