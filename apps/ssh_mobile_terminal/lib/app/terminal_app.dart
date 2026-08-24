// Terminal-only App 的最小 Material Shell。
//
// 路由只注册 Terminal Feature 的公开页面；未选择的 AI、RAG、MCP、WebView、
// LAN Share、SFTP 等 Feature 没有实现、初始化或路由贡献。

import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:app_ui/app_ui.dart';
import 'package:feature_terminal/feature_terminal.dart';
import 'package:flutter/material.dart';

import 'terminal_app_runtime.dart';

/// Terminal-only App 根 Widget 和 Runtime 生命周期 Owner。
final class TerminalOnlyApp extends StatefulWidget {
  /// 创建 Terminal-only App。
  const TerminalOnlyApp({super.key, required this.runtime});

  /// App Scope Runtime Owner。
  final TerminalAppRuntime runtime;

  @override
  State<TerminalOnlyApp> createState() => TerminalOnlyAppState();
}

/// Waitable owner for the Terminal-only App Scope runtime.
final class TerminalOnlyAppState extends State<TerminalOnlyApp>
    with WidgetsBindingObserver {
  Future<void>? _shutdownFuture;
  bool _shuttingDown = false;

  TerminalAppRuntime get _runtime => widget.runtime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  /// Idempotently releases the Runtime and lets exit callers await the barrier.
  Future<void> shutdown() => _shutdownFuture ??= _shutdownRuntime();

  Future<void> _shutdownRuntime() async {
    if (mounted && !_shuttingDown) {
      setState(() => _shuttingDown = true);
      // Stop Route/Feature borrowers before closing their App Scope owners.
      await WidgetsBinding.instance.endOfFrame;
    }
    await _runtime.dispose();
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await shutdown();
    return AppExitResponse.exit;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _releaseAfterWidgetTeardown();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _releaseAfterWidgetTeardown();
    super.dispose();
  }

  void _releaseAfterWidgetTeardown() {
    final future = _shutdownFuture ??= _runtime.dispose();
    unawaited(
      future.onError((_, _) {
        // Widget disposal cannot await; explicit shutdown retains the error.
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_shuttingDown) return const SizedBox.shrink();
    final runtime = _runtime;
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
