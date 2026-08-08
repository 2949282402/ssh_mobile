// RAG Route Scope。
//
// Scope 将 Module 自有 Service 和 App Port 注入页面，并创建只属于当前路由
// 的 ViewModel；页面退出时只释放 ViewModel，不关闭 App Scope 的 Module。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../application/rag_module.dart';
import '../application/rag_service.dart';
import '../domain/rag_ports.dart';
import '../features/rag/viewmodels/rag_knowledge_viewmodel.dart';

final class RagFeatureScope extends StatelessWidget {
  const RagFeatureScope({required this.module, required this.child, super.key});

  final RagModule module;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ListenableProvider<RagSettingsPort>.value(value: module.settings),
        ListenableProvider<RagCapability>.value(value: module.service),
        ChangeNotifierProvider<RagService>.value(value: module.service),
        ChangeNotifierProvider<RagKnowledgeViewModel>(
          create: (context) => RagKnowledgeViewModel(
            ragService: context.read<RagService>(),
            settings: context.read<RagSettingsPort>(),
          ),
        ),
      ],
      child: child,
    );
  }
}
