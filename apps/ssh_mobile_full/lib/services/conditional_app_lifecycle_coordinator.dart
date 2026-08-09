import 'dart:async';
import 'package:feature_mcp/feature_mcp.dart' as feature_mcp;
import 'package:flutter/widgets.dart';
import 'app_settings.dart';

/// 负责应用按需生命周期事件与条件性服务的协调管理。
class ConditionalAppLifecycleCoordinator with WidgetsBindingObserver {
  final AppSettings appSettings;
  final feature_mcp.McpServerController mcpServerController;
  final Future<void> Function()? flushPendingWrites;

  bool _initialized = false;

  ConditionalAppLifecycleCoordinator({
    required this.appSettings,
    required this.mcpServerController,
    this.flushPendingWrites,
  });

  void initialize() {
    if (_initialized) return;
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(mcpServerController.startIfEnabled());
  }

  void dispose() {
    if (!_initialized) return;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(flushPendingWrites?.call() ?? Future<void>.value());
    unawaited(mcpServerController.stop());
    _initialized = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(flushPendingWrites?.call() ?? Future<void>.value());
    }
    if (state == AppLifecycleState.detached) {
      unawaited(mcpServerController.stop());
    }
  }
}
