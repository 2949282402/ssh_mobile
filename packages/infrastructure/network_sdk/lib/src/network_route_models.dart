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

/// Causal phase of one native direct/Relay route attempt. This is an
/// observation, not a terminal Peer lifecycle state.
enum RouteAttemptPhase {
  unspecified(0),
  directFailed(1),
  relayFallbackStarted(2),
  relayConnected(3),
  relayFailed(4);

  const RouteAttemptPhase(this.wireValue);

  final int wireValue;

  static RouteAttemptPhase fromWire(int value) =>
      RouteAttemptPhase.values.firstWhere(
        (phase) => phase.wireValue == value,
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
