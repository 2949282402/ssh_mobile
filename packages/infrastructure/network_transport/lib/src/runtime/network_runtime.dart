// App Scope 网络运行时的稳定 Facade。
//
// Feature 只依赖该接口请求 Capability，不直接创建 native adapter 或持有
// FFI handle；实际实现由 Composition Root 注入。

import 'package:app_core/app_core.dart';

import '../native/network_command_gateway.dart';
import '../realtime/network_realtime_gateway.dart';
import 'network_capability.dart';

/// 网络运行时的生命周期状态。
enum NetworkRuntimeState {
  /// 尚未初始化任何能力。
  idle,

  /// 至少一个 Capability 正在初始化。
  starting,

  /// 至少一个 Capability 已准备完成。
  ready,

  /// 正在关闭 native handle。
  stopping,

  /// 已关闭，不允许重新使用。
  disposed,
}

/// NetworkRuntime 当前能够直接观测到的资源快照。
///
/// Facade 只拥有 Capability 初始化和 native handle；具体 LAN 传输服务的
/// 单连接生命周期仍由对应服务 Owner 管理，因此 [activeConnections] 只在
/// Facade 实际登记连接时增加，当前实现固定为零而不是猜测底层连接数量。
final class NetworkRuntimeDiagnostics {
  /// 创建网络资源诊断快照。
  NetworkRuntimeDiagnostics({
    required this.state,
    required this.activeConnections,
    required this.nativeHandles,
    required Iterable<NetworkCapability> readyCapabilities,
  }) : readyCapabilities = List.unmodifiable(readyCapabilities);

  /// 当前 Runtime 生命周期状态。
  final NetworkRuntimeState state;

  /// 当前由 Runtime 直接登记的活跃连接数。
  final int activeConnections;

  /// 当前由 Runtime 持有的 native handle 数量。
  final int nativeHandles;

  /// 已成功初始化的 Capability。
  final List<NetworkCapability> readyCapabilities;
}

/// App Scope 唯一的网络运行时合约。
abstract interface class NetworkRuntime implements Disposable {
  /// 当前运行时生命周期状态。
  NetworkRuntimeState get state;

  /// 返回当前可观测的网络资源快照。
  NetworkRuntimeDiagnostics get diagnostics;

  /// 请求按需初始化一个 Capability。
  ///
  /// 相同能力的并发调用必须共享同一个 Future；失败后可再次调用重试。
  Future<void> ensureCapability(NetworkCapability capability);

  /// 打开一个共享的粗粒度 Command/Event gateway。
  ///
  /// Gateway 不拥有 Runtime 或 native handle；调用方只能释放自己的订阅，
  /// 最终资源仍由 AppRuntime 释放 NetworkRuntime。
  Future<NetworkCommandGateway> openCommandGateway();

  /// Opens a borrowed typed gateway for the native Realtime route.
  ///
  /// The gateway does not own the native handle. Realtime session state is
  /// released by the SDK/App adapter before this Runtime is disposed.
  Future<NetworkRealtimeGateway> openRealtimeGateway();

  /// 返回某个 Capability 是否已经成功初始化。
  bool isCapabilityReady(NetworkCapability capability);
}
