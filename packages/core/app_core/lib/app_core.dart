// app_core 的公共入口。
//
// 本库只暴露跨模块所需的生命周期、Module、日志和 Capability 合约；
// 具体业务实现由 App 或 Infrastructure Package 持有。

export 'src/capability/capability_registry.dart';
export 'src/capability/ai_capabilities.dart';
export 'src/localization/app_language.dart';
export 'src/lifecycle/activatable.dart';
export 'src/lifecycle/disposable.dart';
export 'src/lifecycle/disposable_bag.dart';
export 'src/logging/app_logger.dart';
export 'src/logging/app_logger_impl.dart';
export 'src/logging/log_buffer.dart';
export 'src/logging/log_level.dart';
export 'src/logging/log_record.dart';
export 'src/logging/log_sink.dart';
export 'src/logging/telemetry_log_sink.dart';
export 'src/logging/scoped_logger.dart';
export 'src/modules/app_module.dart';
export 'src/modules/module_context.dart';
export 'src/modules/module_descriptor.dart';
export 'src/modules/module_registry.dart';
export 'src/modules/module_state.dart';
export 'src/telemetry/telemetry_model.dart';
export 'src/telemetry/telemetry_policy.dart';
export 'src/telemetry/telemetry_catalog.dart';
export 'src/telemetry/generated/telemetry_events.dart';
export 'src/telemetry/generated/error_codes.dart';
export 'src/telemetry/telemetry_endpoints.dart';
export 'src/telemetry/telemetry_storage.dart';
export 'src/telemetry/telemetry_client.dart';
export 'src/telemetry/telemetry_redactor.dart';
