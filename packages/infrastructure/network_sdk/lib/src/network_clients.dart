import 'dart:typed_data';

import 'network_models.dart';
import 'realtime.dart';

/// 公开服务能力、enrollment 与凭据刷新的非鉴权客户端。
abstract interface class BootstrapClient {
  Future<SdkResult<BootstrapMetadata>> probe(Uri endpoint);

  Future<SdkResult<DeviceEnrollment>> enroll(
    Uri endpoint,
    EnrollmentRequest request,
  );

  /// 为已 enrolled 设备签发新的短期凭据，无需 enrollment token。
  ///
  /// 请求由设备签名种子对
  /// `POST\n/v1/devices/refresh\n<timestamp>\n<nonce>` 的 Ed25519 签名
  /// 证明身份；成功后返回与 enroll 相同的 [DeviceEnrollment] 形状。失败时按共享
  /// 错误映射返回：409 → identityConflict、401 code 12 → credentialExpired、
  /// 404 → noRoute（设备未 enrollment，需要重新 enroll）。
  Future<SdkResult<DeviceEnrollment>> refresh(
    Uri endpoint,
    RefreshRequest request,
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
/// 该接口是 [NetworkFacade] 的低层内部实现边界，不作为 Feature 直接消费的
/// 公共 API。具体 Transport、Route、reconnect 和 transfer recovery 不暴露给
/// Flutter。
abstract interface class SessionClient implements EventStreamClient {
  Future<SdkResult<void>> start(SdkRuntimeConfig config);

  Future<SdkResult<void>> stop();

  Future<SdkResult<void>> upsertPeer(SdkPeerConfig peer);

  Future<SdkResult<void>> removePeer(String peerId);

  Future<SdkResult<void>> connect(
    String peerId, {
    CommunicationClass communicationClass = CommunicationClass.reliableStream,
  });

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

  RealtimeClient get realtime;

  EventStreamClient get events;
}

/// 纯组合实现，不拥有任何底层资源。
final class NetworkSdkClients implements NetworkSdk {
  const NetworkSdkClients({
    required this.bootstrap,
    required this.authenticatedApi,
    required this.sessions,
    required this.realtime,
    EventStreamClient? events,
  }) : events = events ?? sessions;

  @override
  final BootstrapClient bootstrap;

  @override
  final AuthenticatedApiClient authenticatedApi;

  @override
  final SessionClient sessions;

  @override
  final RealtimeClient realtime;

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

/// `/v1/devices/refresh` 请求；签名证明由 App/Feature 使用设备种子生成。
final class RefreshRequest {
  const RefreshRequest({
    required this.deviceId,
    required this.identityPublicKey,
    required this.timestamp,
    required this.nonce,
    required this.signature,
  });

  final String deviceId;
  final Uint8List identityPublicKey;

  /// 签名时的 Unix 秒时间戳。Relay 只接受与服务端相差不超过 300 秒的证明。
  final int timestamp;

  /// 32 字节随机 nonce 的 base64url 编码（无 padding）。
  final String nonce;

  /// 对 `POST\n/v1/devices/refresh\n<timestamp>\n<nonce>` 的 Ed25519
  /// 签名的 base64url 编码（transcript 无末尾换行）。
  final String signature;
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

// 开发阶段迁移别名：业务代码统一从 network_sdk 导入，避免各 Feature 维护一份
// 网络模型副本。后续完成名称收敛后可删除这些别名，而不再引入 Feature 本地桥接。
typedef NetworkResult<T> = SdkResult<T>;
typedef NetworkSuccess<T> = SdkSuccess<T>;
typedef NetworkFailure<T> = SdkFailure<T>;
typedef NetworkServiceDisposedException = SdkClientDisposedException;
typedef NetworkRuntimeConfig = SdkRuntimeConfig;
typedef PeerConfig = SdkPeerConfig;
typedef RelayConfig = SdkRelayConfig;
typedef TransferSession = SdkTransferSession;
typedef RouteSnapshot = SdkRouteSnapshot;
typedef NetworkEvent = SdkEvent;
typedef NetworkService = SessionClient;
