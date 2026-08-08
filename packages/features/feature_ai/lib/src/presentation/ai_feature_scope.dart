// AI Route Scope；只注入已初始化的 AI Port，不拥有 App Scope 资源。

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../application/ai_module.dart';
import '../data/repositories/ai_repository.dart';
import '../domain/ai_ports.dart';

final class AiFeatureScope extends StatelessWidget {
  const AiFeatureScope({super.key, required this.module, required this.child});

  final AiModule module;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ListenableProvider<AiSettingsPort>.value(value: module.settings),
        Provider<AiStoragePort>.value(value: module.storage),
        Provider<AiRepository>.value(value: module.repository),
      ],
      child: child,
    );
  }
}
