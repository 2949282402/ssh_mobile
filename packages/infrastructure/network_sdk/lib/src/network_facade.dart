// 传输网络 v2 业务门面（NetworkFacade）。
//
// Flutter 只面对本文件定义的 Facade，不直接操作 Candidate/Resolve/PathManager/
// RelayClient 状态机（设计文档 §5）。底层 [SessionClient]、Realtime 协调器和
// native runtime 由 App 组合根注入，作为 Facade 的内部实现。通信类别
// [CommunicationClass] 定义在 network_models.dart。

import 'dart:typed_data';

import 'network_clients.dart';
import 'network_models.dart';
import 'realtime.dart';

/// 业务侧唯一网络门面。
///
/// Facade 暴露高层操作（连接/断开对端、批量文件传输、可靠消息、实时会话、
/// Presence 提示事件流），隐藏 Candidate/Resolve/PathManager/RelayClient 状态机。
/// 底层 [SessionClient] 与 Realtime 协调器作为内部实现由 App 组合根注入。
abstract interface class NetworkFacade implements EventStreamClient {
  /// 统一 typed 事件流，包含 Presence 提示、传输进度/终态、Relay 状态等。
  @override
  Stream<SdkEvent> get events;

  /// 启动底层 native runtime 并应用运行时配置。
  Future<SdkResult<void>> start(SdkRuntimeConfig config);

  /// 停止底层 native runtime 数据面。
  Future<SdkResult<void>> stop();

  /// 注册对端传输身份和可选 endpoint，但不发起连接。
  ///
  /// Receiver 在每一代 native runtime 启动后用此方法恢复可信对端；入站信任恢复
  /// 允许 [SdkPeerConfig.endpointAddress] 为空。
  Future<SdkResult<void>> registerPeer(SdkPeerConfig peer);

  /// 连接对端。
  ///
  /// [peer] 可选：提供时内部先注册对端传输身份（endpoint + 身份密钥）再连接，
  /// 避免调用方直接调用低层 upsert/connect。可连接类别为除 [CommunicationClass.realtimeMedia]
  /// 外的数据类别；realtimeMedia 通过 [createRealtimeSession] 建立。
  Future<SdkResult<void>> connectPeer(
    String peerId, {
    SdkPeerConfig? peer,
    CommunicationClass communicationClass = CommunicationClass.reliableStream,
  });

  /// 断开对端。
  Future<SdkResult<void>> disconnectPeer(String peerId);

  /// 配置并连接 native Relay 数据面。
  Future<SdkResult<void>> configureRelay(SdkRelayConfig config);

  /// 断开 native Relay 数据面。
  Future<SdkResult<void>> disconnectRelay();

  /// 批量文件传输（[CommunicationClass.bulkTransfer]）。
  ///
  /// 调用前应先通过 [connectPeer] 建立对端连接。其它 CommunicationClass 会返回
  /// invalidArgument 失败，避免业务在未接入的 V2 native 命令上表达不支持的语义。
  Future<SdkResult<SdkTransferSession>> transferFile({
    required String transferId,
    required String peerId,
    required String filePath,
    CommunicationClass communicationClass = CommunicationClass.bulkTransfer,
  });

  /// 取消已接受的传输。
  Future<SdkResult<void>> cancelTransfer(String transferId);

  /// 接受或拒绝 native 传入传输申请。
  Future<SdkResult<void>> respondToIncomingTransfer({
    required String transferId,
    required bool accept,
  });

  /// 发送可靠消息（[CommunicationClass.reliableMessage]）。
  ///
  /// 当前 V2 native 命令接线尚未拥有消息通道命令；返回 invalidArgument 失败。WS-E 落地
  /// `SendMessage → ReliableMessage` tag 后由本方法接入。
  Future<SdkResult<void>> sendMessage({
    required String peerId,
    required Uint8List payload,
    CommunicationClass communicationClass = CommunicationClass.reliableMessage,
  });

  /// 返回最近观察到的对端路由快照。
  Future<SdkResult<SdkRouteSnapshot>> peerState(String peerId);

  /// 创建实时媒体会话（[CommunicationClass.realtimeMedia]）。
  ///
  /// WebRTC 协商由 native 拥有；调用方只消费 [RealtimeSession] 状态/媒体流。
  RealtimeSession createRealtimeSession({
    required String realtimeId,
    required String peerId,
  });

  /// 释放 Facade 持有的内部 SessionClient（App Scope Owner 仍负责 runtime）。
  Future<void> dispose();
}

/// 默认 [NetworkFacade] 实现，仅委托给内部 [SessionClient] 与 Realtime 协调器。
final class NetworkFacadeImpl implements NetworkFacade {
  /// 创建门面实现。
  ///
  /// [sessions] 是 App 注入的低层 Session 客户端（例如基于 native gateway 的
  /// 实现）；[realtime] 可选，缺省时 [createRealtimeSession] 抛 [UnsupportedError]。
  /// [ownsSessions] 为 true 时 [dispose] 会同时释放注入的 SessionClient。
  NetworkFacadeImpl({
    required this._sessions,
    this._realtime,
    this._ownsSessions = true,
  });

  final SessionClient _sessions;
  final RealtimeClient? _realtime;
  final bool _ownsSessions;
  bool _disposed = false;

  @override
  Stream<SdkEvent> get events => _sessions.events;

  @override
  Future<SdkResult<void>> start(SdkRuntimeConfig config) {
    _ensureUsable();
    return _sessions.start(config);
  }

  @override
  Future<SdkResult<void>> registerPeer(SdkPeerConfig peer) {
    _ensureUsable();
    return _sessions.upsertPeer(peer);
  }

  @override
  Future<SdkResult<void>> stop() {
    _ensureUsable();
    return _sessions.stop();
  }

  @override
  Future<SdkResult<void>> connectPeer(
    String peerId, {
    SdkPeerConfig? peer,
    CommunicationClass communicationClass = CommunicationClass.reliableStream,
  }) async {
    _ensureUsable();
    if (communicationClass == CommunicationClass.realtimeMedia) {
      return _invalidClass(
        communicationClass,
        'connectPeer',
        NetworkOperation.connect,
      );
    }
    if (peer != null) {
      final upsert = await registerPeer(peer);
      if (upsert is SdkFailure<void>) return upsert;
    }
    return _sessions.connect(peerId, communicationClass: communicationClass);
  }

  @override
  Future<SdkResult<void>> disconnectPeer(String peerId) {
    _ensureUsable();
    return _sessions.disconnect(peerId);
  }

  @override
  Future<SdkResult<void>> configureRelay(SdkRelayConfig config) {
    _ensureUsable();
    return _sessions.configureRelay(config);
  }

  @override
  Future<SdkResult<void>> disconnectRelay() {
    _ensureUsable();
    return _sessions.disconnectRelay();
  }

  @override
  Future<SdkResult<SdkTransferSession>> transferFile({
    required String transferId,
    required String peerId,
    required String filePath,
    CommunicationClass communicationClass = CommunicationClass.bulkTransfer,
  }) {
    _ensureUsable();
    if (communicationClass != CommunicationClass.bulkTransfer) {
      return Future.value(
        _invalidClass(
          communicationClass,
          'transferFile',
          NetworkOperation.send,
        ),
      );
    }
    return _sessions.send(
      transferId: transferId,
      peerId: peerId,
      filePath: filePath,
    );
  }

  @override
  Future<SdkResult<void>> cancelTransfer(String transferId) {
    _ensureUsable();
    return _sessions.cancel(transferId);
  }

  @override
  Future<SdkResult<void>> respondToIncomingTransfer({
    required String transferId,
    required bool accept,
  }) {
    _ensureUsable();
    return _sessions.respondToIncoming(transferId: transferId, accept: accept);
  }

  @override
  Future<SdkResult<void>> sendMessage({
    required String peerId,
    required Uint8List payload,
    CommunicationClass communicationClass = CommunicationClass.reliableMessage,
  }) async {
    _ensureUsable();
    if (communicationClass != CommunicationClass.reliableMessage) {
      return _invalidClass(
        communicationClass,
        'sendMessage',
        NetworkOperation.send,
      );
    }
    // 当前 V2 native 契约没有消息通道命令；返回稳定失败，等待 WS-E 接入 tag。
    return SdkFailure<void>(
      NetworkError(
        code: NetworkErrorCode.invalidArgument,
        message: 'Reliable message transport is not yet available.',
        operation: NetworkOperation.send,
        peerId: peerId,
      ),
    );
  }

  @override
  Future<SdkResult<SdkRouteSnapshot>> peerState(String peerId) {
    _ensureUsable();
    return _sessions.state(peerId);
  }

  @override
  RealtimeSession createRealtimeSession({
    required String realtimeId,
    required String peerId,
  }) {
    _ensureUsable();
    final realtime = _realtime;
    if (realtime == null) {
      throw UnsupportedError('Realtime is unavailable on this facade.');
    }
    return realtime.createSession(realtimeId: realtimeId, peerId: peerId);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_ownsSessions) await _sessions.dispose();
  }

  void _ensureUsable() {
    if (_disposed) throw const SdkClientDisposedException();
  }

  static SdkFailure<T> _invalidClass<T>(
    CommunicationClass communicationClass,
    String operationName,
    NetworkOperation operation,
  ) => SdkFailure<T>(
    NetworkError(
      code: NetworkErrorCode.invalidArgument,
      message:
          'CommunicationClass ${communicationClass.name} is not supported '
          'for $operationName.',
      operation: operation,
    ),
  );
}
