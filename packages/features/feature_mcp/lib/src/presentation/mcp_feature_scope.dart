// MCP Route Scope；只创建路由级 ViewModel，不拥有 Module 或 App Scope 资源。

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../application/mcp_module.dart';
import '../application/mcp_server_controller.dart';
import '../domain/mcp_ports.dart';
import '../features/mcp_console/viewmodels/mcp_console_viewmodel.dart';

/// 为 MCP 控制台页面注入设置 Port 和路由级 ViewModel。
final class McpFeatureScope extends StatelessWidget {
  const McpFeatureScope({super.key, required this.module, required this.child});

  final McpModule module;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ListenableProvider<McpSettingsPort>.value(value: module.settings),
        ChangeNotifierProvider<McpServerController>.value(
          value: module.service,
        ),
        ChangeNotifierProvider<McpConsoleViewModel>(
          create: (_) => McpConsoleViewModel(module.service, module.settings),
        ),
      ],
      child: child,
    );
  }
}
