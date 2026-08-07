// v1 统一网络结果、命令、路由与类型化事件模型。
//
// 本文件是 Flutter 调用方与原生网络运行时共享的公开语义契约。
// 错误语义必须保持稳定，传输细节不得泄漏到功能 ViewModel。

import 'dart:typed_data';

/// Dart、Rust、FFI、LAN HTTP 与 Relay 共享的稳定 v1 错误码。
enum NetworkErrorCode {
  unspecified(0),
  invalidArgument(1),
  authenticationFailed(2),
  noRoute(3),
  timeout(4),
  peerOffline(5),
  quicError(6),
  natError(7),
  relayError(8),
  wireguardError(9),
  ioError(10),
  cancelled(11);

  /// 使用固定的线协议值创建错误码。
  const NetworkErrorCode(this.wireValue);

  /// 返回 v1 协议使用的整数值。
  final int wireValue;

  /// 将线协议值转换为已知错误码，未知值回退到 [unspecified]。
  static NetworkErrorCode fromWire(int value) => NetworkErrorCode.values
      .firstWhere((code) => code.wireValue == value, orElse: () => unspecified);
}

/// 为稳定网络错误码提供重试策略。
extension NetworkErrorCodePolicy on NetworkErrorCode {
  /// 是否值得重试相同操作。
  bool get retryable => switch (this) {
    NetworkErrorCode.timeout ||
    NetworkErrorCode.peerOffline ||
    NetworkErrorCode.noRoute ||
    NetworkErrorCode.relayError => true,
    _ => false,
  };
}

/// 网络操作与事件返回的安全结构化诊断信息。
final class NetworkError {
  /// 创建结构化网络错误。
  const NetworkError({
    required this.code,
    required this.message,
    this.operation,
    this.peerId,
  });

  final NetworkErrorCode code;
  final String message;
  final String? operation;
  final String? peerId;

  /// 返回替换指定非空字段后的副本。
  NetworkError copyWith({
    NetworkErrorCode? code,
    String? message,
    String? operation,
    String? peerId,
  }) => NetworkError(
    code: code ?? this.code,
    message: message ?? this.message,
    operation: operation ?? this.operation,
    peerId: peerId ?? this.peerId,
  );

  /// 返回不包含诊断原文、可安全写入日志的表示。
  @override
  String toString() =>
      'NetworkError(${code.name}, operation: $operation, peerId: $peerId)';
}

/// 表示成功的网络操作或类型化失败。
sealed class NetworkResult<T> {
  /// 创建结果实例。
  const NetworkResult();

  /// 当前结果是否包含成功数据。
  bool get isSuccess => this is NetworkSuccess<T>;
}

/// 包含 [data] 的成功结果。
final class NetworkSuccess<T> extends NetworkResult<T> {
  /// 创建成功结果。
  const NetworkSuccess(this.data);

  final T data;
}

/// 包含稳定 [NetworkError] 的失败结果。
final class NetworkFailure<T> extends NetworkResult<T> {
  /// 创建失败结果。
  const NetworkFailure(this.error);

  final NetworkError error;
}

/// 表示服务销毁后仍调用了服务方法。
final class NetworkServiceDisposedException implements Exception {
  /// 创建服务已销毁异常。
  const NetworkServiceDisposedException();

  /// 返回稳定的异常名称。
  @override
  String toString() => 'NetworkServiceDisposedException';
}

/// 类型化的 v1 对端生命周期状态。
enum PeerConnectionState {
  unspecified(0),
  connecting(1),
  connected(2),
  disconnected(3),
  failed(4);

  /// 使用固定线协议值创建对端状态。
  const PeerConnectionState(this.wireValue);

  /// 返回 v1 协议使用的整数值。
  final int wireValue;

  /// 将线协议值转换为已知对端状态。
  static PeerConnectionState fromWire(int value) =>
      PeerConnectionState.values.firstWhere(
        (state) => state.wireValue == value,
        orElse: () => unspecified,
      );
}

/// 对端或传输任务选中的类型化路由。
enum NetworkRouteType {
  unspecified(0),
  quicDirect(1),
  relay(2),
  wireguard(3),
  lan(4);

  /// 使用固定线协议值创建路由类型。
  const NetworkRouteType(this.wireValue);

  /// 返回 v1 协议使用的整数值。
  final int wireValue;

  /// 将线协议值转换为已知路由类型。
  static NetworkRouteType fromWire(int value) =>
      NetworkRouteType.values.firstWhere(
        (route) => route.wireValue == value,
        orElse: () => unspecified,
      );
}

/// 类型化的 v1 Relay 连接状态。
enum RelayConnectionState {
  unspecified(0),
  connecting(1),
  connected(2),
  disconnected(3),
  failed(4);

  /// 使用固定线协议值创建 Relay 状态。
  const RelayConnectionState(this.wireValue);

  /// 返回 v1 协议使用的整数值。
  final int wireValue;

  /// 将线协议值转换为已知 Relay 状态。
  static RelayConnectionState fromWire(int value) =>
      RelayConnectionState.values.firstWhere(
        (state) => state.wireValue == value,
        orElse: () => unspecified,
      );
}

/// 原生运行时启动配置。
final class NetworkRuntimeConfig {
  /// 创建运行时配置。
  const NetworkRuntimeConfig({
    required this.deviceId,
    required this.identityPrivateKey,
    required this.e2ePrivateKey,
    required this.listenAddress,
    required this.receiveDirectory,
  });

  final String deviceId;
  final Uint8List identityPrivateKey;
  final Uint8List e2ePrivateKey;
  final String listenAddress;
  final String receiveDirectory;
}

/// 原生运行时使用的对端身份与端点配置。
final class PeerConfig {
  /// 创建对端配置。
  const PeerConfig({
    required this.peerId,
    required this.endpointAddress,
    required this.identityPublicKey,
    required this.e2ePublicKey,
  });

  final String peerId;
  final String endpointAddress;
  final Uint8List identityPublicKey;
  final Uint8List e2ePublicKey;
}

/// Relay enrollment 凭据与端点配置。
final class RelayConfig {
  /// 创建 Relay 配置。
  const RelayConfig({
    required this.relayUrl,
    required this.relayCredential,
    required this.relaySigningSeed,
  });

  final String relayUrl;
  final String relayCredential;
  final Uint8List relaySigningSeed;
}

/// 标识已接受的传输任务。
final class TransferSession {
  /// 创建传输会话描述。
  const TransferSession({
    required this.transferId,
    required this.peerId,
    required this.filePath,
    required this.routeType,
  });

  final String transferId;
  final String peerId;
  final String filePath;
  final NetworkRouteType routeType;
}

/// 描述对端当前选中的路由。
final class RouteSnapshot {
  /// 创建路由快照。
  const RouteSnapshot({
    required this.peerId,
    required this.routeType,
    this.endpoint,
    this.rtt,
    this.loss,
  });

  final String peerId;
  final NetworkRouteType routeType;
  final String? endpoint;
  final Duration? rtt;
  final double? loss;
}

/// 所有公开 v1 网络事件的基类。
sealed class NetworkEvent {
  /// 使用事件标识和时间戳创建事件。
  const NetworkEvent({required this.eventId, required this.timestamp});

  final String eventId;
  final DateTime timestamp;
}

/// 报告对端连接状态的类型化变化。
final class PeerStateChangedEvent extends NetworkEvent {
  /// 创建对端状态事件。
  const PeerStateChangedEvent({
    required super.eventId,
    required super.timestamp,
    required this.peerId,
    required this.state,
    required this.routeType,
    this.error,
  });

  final String peerId;
  final PeerConnectionState state;
  final NetworkRouteType routeType;
  final NetworkError? error;
}

/// 报告已接受传输任务的进度。
final class TransferProgressEvent extends NetworkEvent {
  /// 创建传输进度事件。
  const TransferProgressEvent({
    required super.eventId,
    required super.timestamp,
    required this.transferId,
    required this.bytesTransferred,
    required this.totalBytes,
  });

  final String transferId;
  final int bytesTransferred;
  final int totalBytes;
}

/// 报告传输成功完成。
final class TransferCompletedEvent extends NetworkEvent {
  /// 创建传输完成事件。
  const TransferCompletedEvent({
    required super.eventId,
    required super.timestamp,
    required this.transferId,
    required this.localPath,
  });

  final String transferId;
  final String localPath;
}

/// 报告传输终态失败。
final class TransferFailedEvent extends NetworkEvent {
  /// 创建传输失败事件。
  const TransferFailedEvent({
    required super.eventId,
    required super.timestamp,
    required this.transferId,
    required this.error,
  });

  final String transferId;
  final NetworkError error;
}

/// 请求 Flutter 审批或拒绝传入传输。
final class IncomingTransferOfferEvent extends NetworkEvent {
  /// 创建传入传输申请事件。
  const IncomingTransferOfferEvent({
    required super.eventId,
    required super.timestamp,
    required this.transferId,
    required this.peerId,
    required this.fileName,
    required this.fileSize,
  });

  final String transferId;
  final String peerId;
  final String fileName;
  final int fileSize;
}

/// 报告对端的路由选择或路由丢失。
final class RouteChangedEvent extends NetworkEvent {
  /// 创建路由变化事件。
  const RouteChangedEvent({
    required super.eventId,
    required super.timestamp,
    required this.snapshot,
  });

  final RouteSnapshot snapshot;
}

/// 报告类型化的 Relay 生命周期变化。
final class RelayStateChangedEvent extends NetworkEvent {
  /// 创建 Relay 状态事件。
  const RelayStateChangedEvent({
    required super.eventId,
    required super.timestamp,
    required this.state,
    this.error,
  });

  final RelayConnectionState state;
  final NetworkError? error;
}

/// 原生 v1 网络运行时的公开命令与事件接口。
abstract interface class NetworkService {
  /// 发布类型化终态事件与生命周期事件。
  Stream<NetworkEvent> get events;

  /// 使用 [config] 启动运行时。
  Future<NetworkResult<void>> start(NetworkRuntimeConfig config);

  /// 停止运行时；重复调用保持幂等。
  Future<NetworkResult<void>> stop();

  /// 新增或替换对端配置。
  Future<NetworkResult<void>> upsertPeer(PeerConfig peer);

  /// 接受 [peerId] 的对端连接任务。
  Future<NetworkResult<void>> connect(String peerId);

  /// 接受 [peerId] 的对端断开任务。
  Future<NetworkResult<void>> disconnect(String peerId);

  /// 接受 Relay 配置任务。
  Future<NetworkResult<void>> configureRelay(RelayConfig config);

  /// 停止当前 Relay 连接。
  Future<NetworkResult<void>> disconnectRelay();

  /// 注册文件传输任务并返回已接受的会话。
  Future<NetworkResult<TransferSession>> send({
    required String transferId,
    required String peerId,
    required String filePath,
  });

  /// 取消已接受的传输任务。
  Future<NetworkResult<void>> cancel(String transferId);

  /// 接受或拒绝传入传输申请。
  Future<NetworkResult<void>> respondToIncoming({
    required String transferId,
    required bool accept,
  });

  /// 返回 [peerId] 的当前路由快照。
  Future<NetworkResult<RouteSnapshot>> state(String peerId);
}
