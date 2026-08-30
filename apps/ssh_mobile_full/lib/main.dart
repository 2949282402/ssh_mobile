import 'app/app_bootstrap.dart';

// 保留旧入口导出，避免测试和外部兼容代码因 App Shell 迁移而断裂。
export 'app/ssh_mobile_app.dart' show SshMobileApp;

/// Flutter 应用入口只负责委托给 App Shell 的启动边界。
// coverage:ignore-start
Future<void> main() async {
  await AppBootstrap.run();
}
// coverage:ignore-end
