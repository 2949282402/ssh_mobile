/// Module 初始化期间使用的类型安全依赖上下文。
///
/// Context 只保存 Composition Root 明确传入的对象，不通过静态单例查找
/// 全局服务；类型键允许 Core 保持与具体 Feature、Infrastructure 解耦。
final class ModuleContext {
  /// 创建一个空上下文。
  const ModuleContext.empty() : _services = const <Type, Object>{};

  /// 从类型到实例的映射创建上下文，并复制为不可变快照。
  factory ModuleContext.fromMap(Map<Type, Object> services) {
    return ModuleContext._(Map<Type, Object>.unmodifiable(services));
  }

  const ModuleContext._(this._services);

  final Map<Type, Object> _services;

  /// 按类型读取可选依赖；未提供时返回 null。
  T? maybeGet<T extends Object>() {
    final service = _services[T];
    return service is T ? service : null;
  }

  /// 按类型读取必需依赖；缺失时抛出明确错误。
  T require<T extends Object>() {
    final service = maybeGet<T>();
    if (service == null) {
      throw StateError('ModuleContext is missing dependency $T');
    }
    return service;
  }

  /// 检查上下文中是否提供了指定类型的依赖。
  bool contains<T extends Object>() => _services.containsKey(T);
}
