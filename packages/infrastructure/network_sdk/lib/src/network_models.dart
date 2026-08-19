import 'dart:typed_data';

/// Dart、Rust、FFI、LAN 和 Relay 共享的开发阶段 v1 错误码。
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
  ioError(10),
  cancelled(11),
  credentialExpired(12),
  identityConflict(13);

  const NetworkErrorCode(this.wireValue);

  final int wireValue;

  static NetworkErrorCode fromWire(int value) => NetworkErrorCode.values
      .firstWhere((code) => code.wireValue == value, orElse: () => unspecified);
}

extension NetworkErrorCodePolicy on NetworkErrorCode {
  bool get retryable => switch (this) {
    NetworkErrorCode.timeout ||
    NetworkErrorCode.peerOffline ||
    NetworkErrorCode.noRoute ||
    NetworkErrorCode.relayError => true,
    _ => false,
  };
}

/// 传输网络 v2 的五种业务通信类别（设计文档 §16/§17）。
///
/// 业务只能通过 [CommunicationClass] 表达通信语义，不能直接指定 QUIC/TCP/UDP
/// 等具体传输。每个类别映射到现有 Network Protocol V2 command/event tag；当前 V2
/// 契约不新增 tag（SSH 流与消息通道 tag 由 WS-E 在并行工作流落地）。
/// [wireValue] 镜像 network-protocol crate `CommunicationClass` 的 prost 枚举值。
enum CommunicationClass {
  /// 可靠字节流（SSH 等连续流式通信）。当前 native 数据面由 ConfigureRuntime
  /// 初始化；SSH 流式 FFI 由 WS-E 落地。
  reliableStream(1),

  /// 可靠消息。native 消息通道 tag 由 WS-E 落地，当前不发送。
  reliableMessage(2),

  /// 大文件批量传输。映射到 native `SendFile` 命令（codec tag 11）。
  bulkTransfer(3),

  /// 不可靠数据报。第一阶段 native 数据面不提供，当前不发送。
  unreliableDatagram(4),

  /// 实时媒体会话。映射到 native Realtime command/event（codec tag 21/22/23）。
  realtimeMedia(5);

  const CommunicationClass(this.wireValue);

  /// 对应 network-protocol `CommunicationClass` 的 prost 枚举值（§17）。
  final int wireValue;
}

/// 服务端建议的重试策略；默认 Unspecified 表示未指定。
enum RetryDisposition {
  unspecified(0),
  noRetry(1),
  retryWithBackoff(2),
  retryAfter(3),
  refreshCredentialThenRetry(4);

  const RetryDisposition(this.wireValue);

  final int wireValue;

  static RetryDisposition fromWire(int value) =>
      RetryDisposition.values.firstWhere(
        (disposition) => disposition.wireValue == value,
        orElse: () => unspecified,
      );
}

/// v1 网络操作的稳定标识。
enum NetworkOperation {
  start('start'),
  stop('stop'),
  upsertPeer('upsert_peer'),
  connect('connect'),
  disconnect('disconnect'),
  configureRelay('configure_relay'),
  disconnectRelay('disconnect_relay'),
  send('send'),
  cancel('cancel'),
  respondToIncoming('respond_incoming'),
  state('state'),
  startLanListener('start_lan_listener'),
  stopLanListener('stop_lan_listener'),
  closeLanConnections('close_lan_connections'),
  connectWebSocket('connect_websocket'),
  authorizeLanRequest('authorize_lan_request'),
  sendHandshake('send_handshake'),
  sendMeta('send_meta'),
  sendFile('send_file'),
  sendRecall('send_recall'),
  sendAnnouncement('send_announcement'),
  sendPairingInvite('send_pairing_invite'),
  fetchCapabilities('fetch_capabilities'),
  checkPair('check_pair'),
  readCapabilities('read_capabilities'),
  lanRequest('lan_request'),
  webShareRequest('webshare_request'),
  webShareSendMeta('webshare_send_meta'),
  webShareSendFile('webshare_send_file'),
  startAdvertising('start_advertising'),
  stopAdvertising('stop_advertising'),
  startDiscovery('start_discovery'),
  stopDiscovery('stop_discovery'),
  startWebShare('start_webshare'),
  stopWebShare('stop_webshare'),
  enrollRelay('enroll_relay'),
  refreshCredential('refresh_credential'),
  connectRelay('connect_relay'),
  bootstrapProbe('bootstrap_probe'),
  listPeers('list_peers'),
  requestConnection('request_connection');

  const NetworkOperation(this.wireName);

  final String wireName;

  static NetworkOperation? fromWire(String? value) {
    if (value == null || value.isEmpty) return null;
    for (final operation in values) {
      if (operation.wireName == value) return operation;
    }
    return null;
  }
}

/// 可安全传递给 UI/日志的结构化网络错误。
final class NetworkError {
  const NetworkError({
    required this.code,
    required this.message,
    this.operation,
    this.peerId,
    this.retryDisposition = RetryDisposition.unspecified,
    this.retryAfterSeconds = 0,
  });

  final NetworkErrorCode code;
  final String message;
  final NetworkOperation? operation;
  final String? peerId;

  /// 服务端建议的重试策略；[RetryDisposition.unspecified] 表示未指定。
  final RetryDisposition retryDisposition;

  /// 服务端建议的 `RetryAfter` 秒数；0 表示未指定。
  final int retryAfterSeconds;

  NetworkError copyWith({
    NetworkErrorCode? code,
    String? message,
    NetworkOperation? operation,
    String? peerId,
    RetryDisposition? retryDisposition,
    int? retryAfterSeconds,
  }) => NetworkError(
    code: code ?? this.code,
    message: message ?? this.message,
    operation: operation ?? this.operation,
    peerId: peerId ?? this.peerId,
    retryDisposition: retryDisposition ?? this.retryDisposition,
    retryAfterSeconds: retryAfterSeconds ?? this.retryAfterSeconds,
  );

  /// 服务端携带重试策略时以其为准；未指定时回退到 [NetworkErrorCode.retryable]。
  bool get retryable => switch (retryDisposition) {
    RetryDisposition.unspecified => code.retryable,
    RetryDisposition.noRetry => false,
    RetryDisposition.retryWithBackoff ||
    RetryDisposition.retryAfter ||
    RetryDisposition.refreshCredentialThenRetry => true,
  };

  @override
  String toString() =>
      'NetworkError(${code.name}, operation: $operation, peerId: $peerId)';
}

/// SDK 客户端操作的 typed result。
sealed class SdkResult<T> {
  const SdkResult();

  bool get isSuccess => this is SdkSuccess<T>;
}

final class SdkSuccess<T> extends SdkResult<T> {
  const SdkSuccess(this.data);

  final T data;
}

final class SdkFailure<T> extends SdkResult<T> {
  const SdkFailure(this.error);

  final NetworkError error;
}

/// SDK facade 释放后继续调用的稳定异常。
final class SdkClientDisposedException implements Exception {
  const SdkClientDisposedException();

  @override
  String toString() => 'SdkClientDisposedException';
}

enum PeerConnectionState {
  unspecified(0),
  connecting(1),
  connected(2),
  disconnected(3),
  failed(4);

  const PeerConnectionState(this.wireValue);

  final int wireValue;

  static PeerConnectionState fromWire(int value) =>
      PeerConnectionState.values.firstWhere(
        (state) => state.wireValue == value,
        orElse: () => unspecified,
      );
}

enum NetworkRouteType {
  unspecified(0),
  quicDirect(1),
  relay(2),
  lan(4);

  const NetworkRouteType(this.wireValue);

  final int wireValue;

  static NetworkRouteType fromWire(int value) =>
      NetworkRouteType.values.firstWhere(
        (route) => route.wireValue == value,
        orElse: () => unspecified,
      );
}

/// Composed route metadata for transports that do not fit the legacy flat
/// [NetworkRouteType] projection.
enum NetworkRouteTopology {
  unspecified(0),
  direct(1),
  relay(2);

  const NetworkRouteTopology(this.wireValue);

  final int wireValue;

  static NetworkRouteTopology fromWire(int value) =>
      NetworkRouteTopology.values.firstWhere(
        (topology) => topology.wireValue == value,
        orElse: () => unspecified,
      );
}

enum NetworkRouteTransport {
  unspecified(0),
  quic(1),
  tcp(2),
  udp(3),
  webSocket(4);

  const NetworkRouteTransport(this.wireValue);

  final int wireValue;

  static NetworkRouteTransport fromWire(int value) =>
      NetworkRouteTransport.values.firstWhere(
        (transport) => transport.wireValue == value,
        orElse: () => unspecified,
      );
}

enum RelayConnectionState {
  unspecified(0),
  connecting(1),
  connected(2),
  disconnected(3),
  failed(4);

  const RelayConnectionState(this.wireValue);

  final int wireValue;

  static RelayConnectionState fromWire(int value) =>
      RelayConnectionState.values.firstWhere(
        (state) => state.wireValue == value,
        orElse: () => unspecified,
      );
}

/// Relay Presence 控制面推送的对端在线状态。
enum PeerPresenceState {
  unspecified(0),
  online(1),
  updated(2),
  offline(3);

  const PeerPresenceState(this.wireValue);

  final int wireValue;

  static PeerPresenceState fromWire(int value) =>
      PeerPresenceState.values.firstWhere(
        (state) => state.wireValue == value,
        orElse: () => unspecified,
      );
}

final class SdkRuntimeConfig {
  const SdkRuntimeConfig({
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

final class SdkPeerConfig {
  const SdkPeerConfig({
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

final class SdkRelayConfig {
  const SdkRelayConfig({
    required this.relayUrl,
    required this.relayCredential,
    required this.relaySigningSeed,
  });

  final String relayUrl;
  final String relayCredential;
  final Uint8List relaySigningSeed;
}

final class SdkTransferSession {
  const SdkTransferSession({
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

final class SdkRouteSnapshot {
  const SdkRouteSnapshot({
    required this.peerId,
    required this.routeType,
    this.topology = NetworkRouteTopology.unspecified,
    this.transport = NetworkRouteTransport.unspecified,
    this.endpoint,
    this.rtt,
    this.loss,
  });

  final String peerId;
  final NetworkRouteType routeType;
  final NetworkRouteTopology topology;
  final NetworkRouteTransport transport;
  final String? endpoint;
  final Duration? rtt;
  final double? loss;
}

/// Rust runtime 的统一 typed event。
sealed class SdkEvent {
  const SdkEvent({required this.eventId, required this.timestamp});

  final String eventId;
  final DateTime timestamp;
}

final class PeerStateChanged extends SdkEvent {
  const PeerStateChanged({
    required super.eventId,
    required super.timestamp,
    required this.peerId,
    required this.state,
    required this.routeType,
    this.routeTopology = NetworkRouteTopology.unspecified,
    this.routeTransport = NetworkRouteTransport.unspecified,
    this.error,
  });

  final String peerId;
  final PeerConnectionState state;
  final NetworkRouteType routeType;
  final NetworkRouteTopology routeTopology;
  final NetworkRouteTransport routeTransport;
  final NetworkError? error;
}

final class TransferProgress extends SdkEvent {
  const TransferProgress({
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

final class TransferCompleted extends SdkEvent {
  const TransferCompleted({
    required super.eventId,
    required super.timestamp,
    required this.transferId,
    required this.localPath,
  });

  final String transferId;
  final String localPath;
}

final class TransferFailed extends SdkEvent {
  const TransferFailed({
    required super.eventId,
    required super.timestamp,
    required this.transferId,
    required this.error,
  });

  final String transferId;
  final NetworkError error;
}

final class IncomingTransferOffer extends SdkEvent {
  const IncomingTransferOffer({
    required super.eventId,
    required super.timestamp,
    required this.transferId,
    required this.peerId,
    required this.fileName,
    required this.fileSize,
    this.routeType = NetworkRouteType.unspecified,
  });

  final String transferId;
  final String peerId;
  final String fileName;
  final int fileSize;
  final NetworkRouteType routeType;
}

final class RouteChanged extends SdkEvent {
  const RouteChanged({
    required super.eventId,
    required super.timestamp,
    required this.snapshot,
  });

  final SdkRouteSnapshot snapshot;
}

final class RelayStateChanged extends SdkEvent {
  const RelayStateChanged({
    required super.eventId,
    required super.timestamp,
    required this.state,
    this.error,
  });

  final RelayConnectionState state;
  final NetworkError? error;
}

/// 单个对端的 Relay Presence 变化（online/updated/offline）。
final class PeerPresenceChanged extends SdkEvent {
  const PeerPresenceChanged({
    required super.eventId,
    required super.timestamp,
    required this.peerId,
    required this.generation,
    required this.state,
  });

  final String peerId;
  final int generation;
  final PeerPresenceState state;
}

/// Relay 认证连接后推送的完整在线设备快照。
final class PeerPresenceSnapshot extends SdkEvent {
  const PeerPresenceSnapshot({
    required super.eventId,
    required super.timestamp,
    required this.peers,
  });

  final List<PeerPresenceChanged> peers;
}
