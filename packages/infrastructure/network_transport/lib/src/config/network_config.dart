// 网络运行时的安全配置。
//
// 这里仅保留当前 native v1 已经能够表达的开关，避免提前设计一套新的
// 协议配置系统；未来协议实现可以在不改变 NetworkRuntime 合约的前提下扩展。

import '../runtime/network_capability.dart';

/// 控制当前 App Scope 网络运行时允许初始化的能力。
final class NetworkConfig {
  /// 创建默认网络配置。
  ///
  /// QUIC 和 WSS Relay 是当前 native v1 已存在的能力；TCP/UDP 在当前 Step
  /// 仍明确返回 unsupported，不通过默认配置伪造支持。
  const NetworkConfig({
    this.enableQuic = true,
    this.enableWebSocketRelay = true,
    this.enableRealtime = true,
  });

  /// 是否允许初始化 QUIC 能力。
  final bool enableQuic;

  /// 是否允许初始化 WSS Relay 能力。
  final bool enableWebSocketRelay;

  /// Whether native WebRTC Realtime may be initialized.
  final bool enableRealtime;

  /// 返回配置是否允许请求指定能力。
  bool allows(NetworkCapability capability) => switch (capability) {
    NetworkCapability.quic => enableQuic,
    NetworkCapability.webSocketRelay => enableWebSocketRelay,
    NetworkCapability.realtime => enableRealtime,
    NetworkCapability.tcp || NetworkCapability.udp => false,
  };
}
