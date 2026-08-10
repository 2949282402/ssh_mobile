import 'dart:typed_data';

import 'network_models.dart';

/// 公开服务能力和 enrollment 的非鉴权客户端。
abstract interface class BootstrapClient {
  Future<SdkResult<BootstrapMetadata>> probe(Uri endpoint);

  Future<SdkResult<DeviceEnrollment>> enroll(
    Uri endpoint,
    EnrollmentRequest request,
  );
}

/// 控制面鉴权会话提供者；具体 token 存储由 App Shell 实现。
abstract interface class AuthSessionProvider {
  Future<String?> readAccessToken();

  /// 尝试获取一个替换当前 token 的新 token；无法刷新时返回 null。
  ///
  /// 默认实现保持纯内存/无刷新 Provider 的行为，避免把刷新协议强加给
  /// 仅使用静态设备凭据的 App Shell。
  Future<String?> refreshAccessToken() async => null;

  Future<void> invalidate();
}

/// Bearer/设备签名保护的短请求控制面客户端。
abstract interface class AuthenticatedApiClient {
  Future<SdkResult<List<PeerDescriptor>>> listPeers();

  Future<SdkResult<ConnectionTicket>> requestConnection(String peerId);
}

/// Rust runtime 统一事件流客户端。
abstract interface class EventStreamClient {
  Stream<SdkEvent> get events;
}

/// 设备业务 Session 和传输操作客户端。
///
/// 该接口保留当前开发阶段 v1 的粗粒度命令边界。具体 Transport、Route、
/// reconnect 和 transfer recovery 不暴露给 Flutter。
abstract interface class SessionClient implements EventStreamClient {
  Future<SdkResult<void>> start(SdkRuntimeConfig config);

  Future<SdkResult<void>> stop();

  Future<SdkResult<void>> upsertPeer(SdkPeerConfig peer);

  Future<SdkResult<void>> connect(String peerId);

  Future<SdkResult<void>> disconnect(String peerId);

  Future<SdkResult<void>> configureRelay(SdkRelayConfig config);

  Future<SdkResult<void>> disconnectRelay();

  Future<SdkResult<SdkTransferSession>> send({
    required String transferId,
    required String peerId,
    required String filePath,
  });

  Future<SdkResult<void>> cancel(String transferId);

  Future<SdkResult<void>> respondToIncoming({
    required String transferId,
    required bool accept,
  });

  Future<SdkResult<SdkRouteSnapshot>> state(String peerId);

  Future<void> dispose();
}

/// App Shell 组装后的统一 SDK 客户端集合。
abstract interface class NetworkSdk {
  BootstrapClient get bootstrap;

  AuthenticatedApiClient get authenticatedApi;

  SessionClient get sessions;

  EventStreamClient get events;
}

/// 纯组合实现，不拥有任何底层资源。
final class NetworkSdkClients implements NetworkSdk {
  const NetworkSdkClients({
    required this.bootstrap,
    required this.authenticatedApi,
    required this.sessions,
    EventStreamClient? events,
  }) : events = events ?? sessions;

  @override
  final BootstrapClient bootstrap;

  @override
  final AuthenticatedApiClient authenticatedApi;

  @override
  final SessionClient sessions;

  @override
  final EventStreamClient events;
}

/// 公开 bootstrap 服务能力快照。
final class BootstrapMetadata {
  const BootstrapMetadata({
    required this.protocolVersion,
    this.capabilities = const <String>[],
    this.serverTime,
  });

  final int protocolVersion;
  final List<String> capabilities;
  final DateTime? serverTime;
}

final class EnrollmentRequest {
  const EnrollmentRequest({
    required this.deviceId,
    required this.identityPublicKey,
    this.enrollmentToken,
    this.protocolVersion = 1,
    this.platform,
  });

  final String deviceId;
  final Uint8List identityPublicKey;
  final String? enrollmentToken;
  final int protocolVersion;
  final String? platform;
}

/// enrollment 返回的敏感材料只交给 App Shell 安全存储。
final class DeviceEnrollment {
  const DeviceEnrollment({
    required this.deviceId,
    required this.relayCredential,
    required this.expiresAt,
    required this.serverTime,
    required this.protocolVersion,
  });

  final String deviceId;
  final String relayCredential;
  final DateTime expiresAt;
  final DateTime serverTime;
  final int protocolVersion;
}

final class PeerDescriptor {
  const PeerDescriptor({required this.peerId, required this.displayName});

  final String peerId;
  final String displayName;
}

final class ConnectionTicket {
  const ConnectionTicket({required this.peerId, required this.value});

  final String peerId;
  final String value;
}
