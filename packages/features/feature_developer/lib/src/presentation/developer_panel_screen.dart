import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/developer_ports.dart';
import 'developer_lifecycle_diagnostics_card.dart';
import 'developer_panel_viewmodel.dart';
import 'developer_telemetry_card.dart';

part 'developer_panel_card_helpers.dart';
part 'developer_panel_component_card.dart';
part 'developer_panel_frame_card.dart';
part 'developer_panel_fps_card.dart';
part 'developer_panel_info_card.dart';
part 'developer_panel_memory_card.dart';

/// Developer Panel 全屏页面；路由从 Provider 注入 diagnostics contract。
class DeveloperPanelScreen extends StatefulWidget {
  const DeveloperPanelScreen({super.key});

  @override
  State<DeveloperPanelScreen> createState() => _DeveloperPanelScreenState();
}

class _DeveloperPanelScreenState extends State<DeveloperPanelScreen> {
  late final DeveloperPanelViewModel _vm;

  @override
  void initState() {
    super.initState();
    _vm = DeveloperPanelViewModel(
      diagnostics: context.read<DeveloperDiagnosticsPort>(),
    )..start();
  }

  @override
  void dispose() {
    _vm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<DeveloperPanelViewModel>.value(
      value: _vm,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Developer Panel'),
          centerTitle: false,
        ),
        body: DeveloperPanelContent(vm: _vm),
      ),
    );
  }
}

/// Reusable developer panel body (FPS / memory / frame stats / build info).
///
/// Used by both the full-screen [DeveloperPanelScreen] and the floating
/// developer panel overlay so the same diagnostics are shown in both places.
class DeveloperPanelContent extends StatelessWidget {
  final DeveloperPanelViewModel vm;

  const DeveloperPanelContent({super.key, required this.vm});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: vm,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _DeveloperPanelFpsCard(vm: vm),
            const SizedBox(height: 12),
            _DeveloperPanelMemoryCard(vm: vm),
            const SizedBox(height: 12),
            _DeveloperPanelFrameCard(vm: vm),
            const SizedBox(height: 12),
            _DeveloperPanelComponentCard(vm: vm),
            const SizedBox(height: 12),
            DeveloperTelemetryCard(
              telemetry: vm.diagnosticsSnapshot.telemetry,
              vm: vm,
            ),
            const SizedBox(height: 12),
            DeveloperLifecycleDiagnosticsCard(snapshot: vm.diagnosticsSnapshot),
            const SizedBox(height: 12),
            _DeveloperPanelInfoCard(vm: vm),
          ],
        );
      },
    );
  }
}
