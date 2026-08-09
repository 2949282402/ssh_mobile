import 'app/terminal_app_bootstrap.dart';

/// Terminal-only App 的最小入口；所有资源装配由 App Shell 负责。
Future<void> main() async {
  await TerminalAppBootstrap.run();
}
