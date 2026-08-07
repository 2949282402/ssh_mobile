/// 旧 App 路径的兼容转导出。
///
/// 页面实现已迁移到 feature_connection；保留该入口是为了让尚未完成全局
/// import 收敛的旧测试和外部调用继续编译，不再在此目录维护 UI 实现。
library;

export 'package:feature_connection/feature_connection.dart' show AddEditScreen;
