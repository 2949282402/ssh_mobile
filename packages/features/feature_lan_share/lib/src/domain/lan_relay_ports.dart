// LAN Relay 生命周期协调器的纯 Dart 边界契约。

import 'dart:typed_data';

import 'package:network_sdk/network_sdk.dart';

/// Relay endpoint 设置的最小借用接口。
abstract interface class LanRelaySettingsPort {
  /// 当前配置的 Relay HTTPS origin。
  String get relayEndpoint;

  /// 保存 Relay HTTPS origin。
  Future<void> setRelayEndpoint(String endpoint);

  /// 观察外部 endpoint 变更。
  void addListener(void Function() listener);

  /// 停止观察 endpoint 变更。
  void removeListener(void Function() listener);
}

/// Relay 协调器所需的最小日志接口。
abstract interface class LanRelayLoggerPort {
  /// 记录可恢复的 Relay 降级，不包含凭据。
  void warning(String message, {String? details});
}

/// App Scope Runtime 能力检查适配接口。
abstract interface class LanRelayCapabilityPort {
  /// 确认原生 WebSocket Relay 能力可用；不可用时抛出异常。
  Future<void> ensureWebSocketRelay();
}

/// 标识 enrollment 与原生配置使用的 Relay 源站。
final class RelaySettings {
  /// 为一个 HTTPS Relay 源站创建配置。
  const RelaySettings({required this.endpoint});

  /// 不包含路径、查询参数或凭据的 Relay HTTPS 源站。
  final Uri endpoint;
}

/// 只包含 Rust Relay 客户端所需的凭据材料。
final class RelayNativeConfiguration {
  /// 创建原生 Relay 配置快照。
  const RelayNativeConfiguration({
    required this.endpoint,
    required this.credential,
    required this.signingSeed,
  });

  /// 传递给原生运行时的 Relay 源站。
  final Uri endpoint;

  /// 短期 enrollment 凭据。
  final String credential;

  /// 从安全存储加载的 Ed25519 签名种子。
  final Uint8List signingSeed;
}

/// Relay enrollment 与凭据安全存储的生命周期接口。
abstract interface class LanRelayEnrollmentPort {
  /// 使用一次性 token enrollment 并保存短期凭据。
  Future<NetworkResult<void>> enroll(
    RelaySettings settings,
    String enrollmentToken,
  );

  /// 使用稳定设备密钥刷新短期凭据。
  Future<NetworkResult<void>> refreshCredential(RelaySettings settings);

  /// 是否存在与源站匹配的已存储凭据，包括已过期凭据。
  Future<bool> hasStoredCredential(RelaySettings settings);

  /// 是否存在未过期、可供连接使用的 enrollment。
  Future<bool> isEnrolled(RelaySettings settings);

  /// 加载可供原生数据面使用的配置；不可用或过期时返回 null。
  Future<RelayNativeConfiguration?> nativeConfiguration(RelaySettings settings);

  /// 清除短期 enrollment 凭据，但保留稳定签名种子。
  Future<void> clearEnrollment();

  /// 释放 enrollment 客户端资源。
  Future<void> dispose();
}
