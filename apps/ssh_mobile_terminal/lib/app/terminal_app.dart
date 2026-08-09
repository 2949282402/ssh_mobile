// Terminal-only App 的最小 Material Shell。
//
// 路由只注册 Terminal Feature 的公开页面；未选择的 AI、RAG、MCP、WebView、
// LAN Share、SFTP 等 Feature 没有实现、初始化或路由贡献。

import 'package:app_ui/app_ui.dart';
import 'package:feature_terminal/feature_terminal.dart';
import 'package:flutter/material.dart';

import 'terminal_app_runtime.dart';

/// Terminal-only App 根 Widget。
final class TerminalOnlyApp extends StatelessWidget {
  /// 创建 Terminal-only App。
  const TerminalOnlyApp({super.key, required this.runtime});

  /// App Scope Runtime Owner。
  final TerminalAppRuntime runtime;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SSH Mobile Terminal',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightThemeFor(),
      darkTheme: AppTheme.darkThemeFor(),
      themeMode: runtime.settings.isDarkMode ? ThemeMode.dark : ThemeMode.light,
      home: const TerminalWindowsScreen(),
      routes: <String, WidgetBuilder>{
        TerminalRouteNames.history: (_) => const TerminalHistoryScreen(),
      },
      onGenerateRoute: (settings) {
        if (settings.name == TerminalRouteNames.terminal) {
          return MaterialPageRoute<void>(
            builder: (_) => const _TerminalUnavailablePage(),
          );
        }
        return null;
      },
      onUnknownRoute: (settings) => MaterialPageRoute<void>(
        builder: (_) => const _TerminalUnavailablePage(),
      ),
      builder: (context, child) {
        return TerminalFeatureScope(
          sshSessionManager: runtime.sshSessionManager,
          settings: runtime.settings,
          shortcuts: runtime.shortcuts,
          connections: runtime.connections,
          logger: runtime.terminalLogger,
          historyRepository: runtime.terminalModule.historyRepository,
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}

/// 未装配真实连接编辑器或会话实现时的明确降级页面。
final class _TerminalUnavailablePage extends StatelessWidget {
  const _TerminalUnavailablePage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SSH Mobile Terminal')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(AppTheme.pagePadding),
          child: Text(
            'This Terminal-only build validates the modular dependency slice. '
            'The Full App provides the live SSH connection implementation.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
