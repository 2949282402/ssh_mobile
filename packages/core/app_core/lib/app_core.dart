// app_core 的公共入口。
//
// 本库只暴露跨模块所需的生命周期、Module、日志和 Capability 合约；
// 具体业务实现由 App 或 Infrastructure Package 持有。

export 'src/capability/capability_registry.dart';
export 'src/lifecycle/activatable.dart';
export 'src/lifecycle/disposable.dart';
export 'src/lifecycle/disposable_bag.dart';
export 'src/logging/app_logger.dart';
export 'src/logging/log_level.dart';
export 'src/logging/log_record.dart';
export 'src/modules/app_module.dart';
export 'src/modules/module_context.dart';
export 'src/modules/module_descriptor.dart';
export 'src/modules/module_registry.dart';
export 'src/modules/module_state.dart';
