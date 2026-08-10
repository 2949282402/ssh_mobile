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
  wireguardError(9),
  ioError(10),
  cancelled(11);

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
  connectRelay('connect_relay');

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
  });

  final NetworkErrorCode code;
  final String message;
  final NetworkOperation? operation;
  final String? peerId;

  NetworkError copyWith({
    NetworkErrorCode? code,
    String? message,
    NetworkOperation? operation,
    String? peerId,
  }) => NetworkError(
    code: code ?? this.code,
    message: message ?? this.message,
    operation: operation ?? this.operation,
    peerId: peerId ?? this.peerId,
  );

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
  wireguard(3),
  lan(4);

  const NetworkRouteType(this.wireValue);

  final int wireValue;

  static NetworkRouteType fromWire(int value) =>
      NetworkRouteType.values.firstWhere(
        (route) => route.wireValue == value,
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
    this.error,
  });

  final String peerId;
  final PeerConnectionState state;
  final NetworkRouteType routeType;
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
  });

  final String transferId;
  final String peerId;
  final String fileName;
  final int fileSize;
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
