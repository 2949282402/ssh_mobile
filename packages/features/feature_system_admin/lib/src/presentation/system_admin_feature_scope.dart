// System Admin Route Scope 的 Provider 组合。
//
// Module 和所有 App/Capability Port 由 App Shell 注入；本 Scope 只创建
// Route ViewModel，并在离开页面时解除它对 Service/Connection 的监听。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../application/system_admin_module.dart';
import '../application/system_admin_service.dart';
import '../domain/system_admin_monitoring.dart';
import '../domain/system_admin_ports.dart';
import 'viewmodels/system_admin_viewmodel.dart';

/// 将 System Admin Module 和 Route 状态提供给页面树。
final class SystemAdminFeatureScope extends StatelessWidget {
  /// 创建已初始化 Module 的 Route Scope。
  const SystemAdminFeatureScope({
    super.key,
    required this.module,
    required this.connectionCatalog,
    required this.settings,
    required this.monitoring,
    required this.hostKeyConfirmation,
    required this.fileBrowser,
    required this.child,
  });

  final SystemAdminModule module;
  final SystemAdminConnectionCatalogPort connectionCatalog;
  final SystemAdminSettingsPort settings;
  final SystemAdminMonitoringPort monitoring;
  final SystemAdminHostKeyConfirmationPort hostKeyConfirmation;
  final SystemAdminFileBrowserPort fileBrowser;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ListenableProvider<SystemAdminConnectionCatalogPort>.value(
          value: connectionCatalog,
        ),
        ListenableProvider<SystemAdminSettingsPort>.value(value: settings),
        ListenableProvider<SystemAdminMonitoringPort>.value(value: monitoring),
        Provider<SystemAdminHostKeyConfirmationPort>.value(
          value: hostKeyConfirmation,
        ),
        Provider<SystemAdminFileBrowserPort>.value(value: fileBrowser),
        ChangeNotifierProvider<SystemAdminService>.value(value: module.service),
        ChangeNotifierProvider<SystemAdminViewModel>(
          create: (_) => SystemAdminViewModel(
            adminService: module.service,
            connectionCatalog: connectionCatalog,
          ),
        ),
      ],
      child: child,
    );
  }
}
