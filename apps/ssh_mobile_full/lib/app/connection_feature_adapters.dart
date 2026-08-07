/// Connection Feature 的 App 组合根适配器公共转导出。
///
/// 具体适配器按 Repository、Runtime 和 UI 职责分文件维护；Feature 本身
/// 不依赖这些 App 实现，只依赖 feature_connection 的公共契约。
library;

export 'connection_repository_adapters.dart';
export 'connection_runtime_adapters.dart';
export 'connection_ui_adapters.dart';
