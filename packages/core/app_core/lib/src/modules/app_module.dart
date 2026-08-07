import '../lifecycle/activatable.dart';
import '../lifecycle/disposable.dart';
import 'module_context.dart';
import 'module_state.dart';

/// App Module 的统一生命周期接口。
///
/// 调用方应按 register → initialize → activate 的顺序使用 Module；停用
/// 后可以再次 activate，dispose 后不得重新使用。具体 Module 负责保证
/// initialize 和其余生命周期操作的幂等性。
abstract interface class AppModule implements Activatable, Disposable {
  /// Module 的稳定标识，必须与其 [ModuleDescriptor] 的 id 一致。
  String get id;

  /// 当前 Module 的稳定生命周期状态。
  ModuleState get state;

  /// 注册 Module 所需的上下文依赖和内部资源。
  Future<void> register(ModuleContext context);

  /// 初始化 Module 资源；重复调用不得重复创建资源。
  Future<void> initialize();
}
