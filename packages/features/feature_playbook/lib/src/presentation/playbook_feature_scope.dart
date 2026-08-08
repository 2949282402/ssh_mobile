// Playbook Route Scope；只创建路由级 ViewModel，不拥有 Module 或 App Scope 资源。

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../application/playbook_module.dart';
import '../domain/playbook_ports.dart';
import '../features/playbook/viewmodels/playbook_viewmodel.dart';

/// 为 Playbook 页面提供设置、连接目录和唯一 ViewModel。
final class PlaybookFeatureScope extends StatelessWidget {
  const PlaybookFeatureScope({
    super.key,
    required this.module,
    required this.settings,
    required this.connectionCatalog,
    required this.child,
  });

  final PlaybookModule module;
  final PlaybookSettingsPort settings;
  final PlaybookConnectionCatalogPort connectionCatalog;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ListenableProvider<PlaybookSettingsPort>.value(value: settings),
        ListenableProvider<PlaybookConnectionCatalogPort>.value(
          value: connectionCatalog,
        ),
        ChangeNotifierProvider<PlaybookViewModel>(
          create: (_) => PlaybookViewModel(
            playbookService: module.service,
            connectionCatalog: connectionCatalog,
          ),
        ),
      ],
      child: child,
    );
  }
}
