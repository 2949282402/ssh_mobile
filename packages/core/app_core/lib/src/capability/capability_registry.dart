/// 按类型注册和查找跨模块 Capability 的轻量 Registry。
///
/// Registry 只管理 Capability 与类型键的绑定，不拥有 Capability 的资源
/// 生命周期；对应资源仍由注册它的 AppRuntime 或 Module 负责 dispose/close。
final class CapabilityRegistry {
  final Map<Type, Object> _capabilities = <Type, Object>{};

  /// 当前已注册的 Capability 数量。
  int get length => _capabilities.length;

  /// 注册一个类型化 Capability；同一类型不可被不同实例静默覆盖。
  void register<T extends Object>(T capability) {
    final existing = _capabilities[T];
    if (existing != null && !identical(existing, capability)) {
      throw StateError('Capability type is already registered: $T');
    }
    _capabilities[T] = capability;
  }

  /// 检查指定类型是否已注册。
  bool contains<T extends Object>() => _capabilities.containsKey(T);

  /// 读取可选 Capability；未注册时返回 null。
  T? maybeGet<T extends Object>() {
    final capability = _capabilities[T];
    return capability is T ? capability : null;
  }

  /// 读取必需 Capability；未注册时抛出明确错误。
  T require<T extends Object>() {
    final capability = maybeGet<T>();
    if (capability == null) {
      throw StateError('Capability is not registered: $T');
    }
    return capability;
  }

  /// 移除指定类型的绑定，但不释放 Capability 本身。
  T? remove<T extends Object>() {
    final capability = _capabilities.remove(T);
    return capability is T ? capability : null;
  }
}
