// App Scope 网络运行时的稳定 Facade。
//
// Feature 只依赖该接口请求 Capability，不直接创建 native adapter 或持有
// FFI handle；实际实现由 Composition Root 注入。

import 'package:app_core/app_core.dart';

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

/// App Scope 唯一的网络运行时合约。
abstract interface class NetworkRuntime implements Disposable {
  /// 当前运行时生命周期状态。
  NetworkRuntimeState get state;

  /// 请求按需初始化一个 Capability。
  ///
  /// 相同能力的并发调用必须共享同一个 Future；失败后可再次调用重试。
  Future<void> ensureCapability(NetworkCapability capability);

  /// 返回某个 Capability 是否已经成功初始化。
  bool isCapabilityReady(NetworkCapability capability);
}
