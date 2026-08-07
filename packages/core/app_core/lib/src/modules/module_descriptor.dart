import 'app_module.dart';
import 'module_context.dart';

/// 根据 Module 上下文创建运行时实例的工厂函数。
typedef AppModuleFactory = AppModule Function(ModuleContext context);

/// 描述一个可选路由贡献的静态元数据。
///
/// 这里不持有 Widget、ViewModel 或路由实例，避免 Core 长期持有 UI 运行时
/// 对象；App Shell 在需要组装导航时再解释这些元数据。
final class ModuleRouteContribution {
  /// 创建不可变的路由贡献元数据。
  factory ModuleRouteContribution({
    required String routeName,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    if (routeName.trim().isEmpty) {
      throw ArgumentError.value(routeName, 'routeName');
    }
    return ModuleRouteContribution._(
      routeName,
      Map<String, Object?>.unmodifiable(metadata),
    );
  }

  const ModuleRouteContribution._(this.routeName, this.metadata);

  /// 路由名称或稳定路由键。
  final String routeName;

  /// 供 App Shell 使用的不可变附加元数据。
  final Map<String, Object?> metadata;
}

/// Module 的静态描述信息。
///
/// Registry 只长期持有 Descriptor；[factory] 只在 Runtime 明确请求时创建
/// Module，因此不会因为注册所有模块而提前初始化重型资源。
final class ModuleDescriptor {
  /// 创建并校验一个 Module 描述。
  factory ModuleDescriptor({
    required String id,
    required AppModuleFactory factory,
    Map<String, Object?> metadata = const <String, Object?>{},
    Iterable<ModuleRouteContribution> routeContributions =
        const <ModuleRouteContribution>[],
  }) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id');
    }
    return ModuleDescriptor._(
      id,
      factory,
      Map<String, Object?>.unmodifiable(metadata),
      List<ModuleRouteContribution>.unmodifiable(routeContributions),
    );
  }

  const ModuleDescriptor._(
    this.id,
    this.factory,
    this.metadata,
    this.routeContributions,
  );

  /// Module 的稳定标识。
  final String id;

  /// 创建 Module 运行时实例的工厂。
  final AppModuleFactory factory;

  /// 不参与运行时初始化的静态描述元数据。
  final Map<String, Object?> metadata;

  /// 不持有路由实例的静态路由贡献信息。
  final List<ModuleRouteContribution> routeContributions;
}
