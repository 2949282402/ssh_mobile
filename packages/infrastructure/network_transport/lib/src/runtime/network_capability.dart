// 网络能力枚举及其静态语义。
//
// Capability 只描述可按需启用的传输能力，不在这里实现任何协议。

/// App 网络运行时可以声明或按需初始化的传输能力。
enum NetworkCapability {
  /// 面向传统流式连接的 TCP 能力；当前 Facade 尚未提供实现。
  tcp,

  /// 面向无连接数据报的 UDP 能力；当前 Facade 尚未提供实现。
  udp,

  /// 当前 native v1 使用的 Quinn/QUIC 数据面。
  quic,

  /// 当前 native v1 使用的 WSS Relay 数据面。
  webSocketRelay,

  /// Session-owned native WebRTC Realtime data plane.
  realtime,
}

/// 为能力枚举提供稳定的诊断名称。
extension NetworkCapabilityDescription on NetworkCapability {
  /// 返回不包含协议细节的稳定名称，供错误和测试使用。
  String get label => switch (this) {
    NetworkCapability.tcp => 'tcp',
    NetworkCapability.udp => 'udp',
    NetworkCapability.quic => 'quic',
    NetworkCapability.webSocketRelay => 'webSocketRelay',
    NetworkCapability.realtime => 'realtime',
  };
}
