import 'app_module.dart';
import 'module_context.dart';
import 'module_descriptor.dart';

/// 只注册和查找 ModuleDescriptor 的静态 Registry。
///
/// Registry 不缓存 [AppModule] 实例；运行时实例的 Owner 是调用方的
/// AppRuntime 或 Module Scope，因而可以按需 Lazy Create 并明确释放。
final class ModuleRegistry {
  final Map<String, ModuleDescriptor> _descriptors =
      <String, ModuleDescriptor>{};

  /// 注册一个 Module 描述。
  ///
  /// 同一个 Descriptor 重复注册视为幂等；相同 id 指向不同 Descriptor 则
  /// 直接报错，避免 Composition Root 静默覆盖模块定义。
  void register(ModuleDescriptor descriptor) {
    final existing = _descriptors[descriptor.id];
    if (existing == null) {
      _descriptors[descriptor.id] = descriptor;
      return;
    }
    if (!identical(existing, descriptor)) {
      throw StateError('Module id is already registered: ${descriptor.id}');
    }
  }

  /// 注册多个 Module 描述。
  void registerAll(Iterable<ModuleDescriptor> descriptors) {
    for (final descriptor in descriptors) {
      register(descriptor);
    }
  }

  /// 当前 Registry 是否包含指定 id。
  bool contains(String id) => _descriptors.containsKey(id);

  /// 返回指定 id 的静态描述；不存在时抛出明确错误。
  ModuleDescriptor descriptorFor(String id) {
    final descriptor = _descriptors[id];
    if (descriptor == null) {
      throw StateError('Module is not registered: $id');
    }
    return descriptor;
  }

  /// 返回不可变的 Descriptor 快照，不暴露内部 Map。
  Iterable<ModuleDescriptor> get descriptors =>
      List<ModuleDescriptor>.unmodifiable(_descriptors.values);

  /// 按需创建 Module，不在 Registry 中保存创建结果。
  AppModule create(String id, ModuleContext context) {
    final descriptor = descriptorFor(id);
    final module = descriptor.factory(context);
    if (module.id != descriptor.id) {
      throw StateError(
        'Module factory returned ${module.id} for descriptor ${descriptor.id}',
      );
    }
    return module;
  }
}
