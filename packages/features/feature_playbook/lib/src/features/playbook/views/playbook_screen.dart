import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:connection_core/connection_core.dart';
import 'package:app_ui/app_ui.dart';

import '../../../domain/playbook_ports.dart';
import '../models/playbook.dart';
import '../viewmodels/playbook_viewmodel.dart';

part 'widgets/playbook_strings.dart';
part 'widgets/playbooks_list.dart';
part 'widgets/playbook_editor.dart';
part 'widgets/execution_dashboard.dart';

class PlaybookScreen extends StatefulWidget {
  const PlaybookScreen({super.key});

  @override
  State<PlaybookScreen> createState() => _PlaybookScreenState();
}

class _PlaybookScreenState extends State<PlaybookScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _mobileTabs;

  bool get _isCompactLayout {
    final width = MediaQuery.maybeSizeOf(context)?.width;
    return width != null && width < 760;
  }

  @override
  void initState() {
    super.initState();
    _mobileTabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _mobileTabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<PlaybookSettingsPort, PlaybookLanguage>(
      (settings) => settings.language,
    );
    final strings = _PlaybookStrings(language);
    final colorScheme = Theme.of(context).colorScheme;
    final viewModel = context.watch<PlaybookViewModel>();
    final connections = viewModel.connections;

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.title),
        actions: [
          if (!viewModel.isEditing) ...[
            IconButton(
              tooltip: strings.newPlaybook,
              icon: const Icon(Icons.add_rounded),
              onPressed: () {
                viewModel.startNewPlaybook();
                if (_isCompactLayout) {
                  _mobileTabs.animateTo(1);
                }
              },
            ),
          ] else ...[
            IconButton(
              tooltip: strings.save,
              icon: const Icon(Icons.save_outlined),
              onPressed: () => viewModel.savePlaybook(),
            ),
            IconButton(
              tooltip: strings.cancel,
              icon: const Icon(Icons.close_rounded),
              onPressed: () => viewModel.cancelEditing(),
            ),
          ],
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 760;
          final listWidget = _buildPlaybooksList(
            viewModel,
            strings,
            colorScheme,
          );
          final rightWidget = viewModel.isEditing
              ? _buildPlaybookEditor(viewModel, strings, colorScheme)
              : _buildExecutionDashboard(
                  viewModel,
                  connections,
                  strings,
                  colorScheme,
                );

          if (wide) {
            return Row(
              children: [
                SizedBox(width: 320, child: listWidget),
                VerticalDivider(width: 1, color: colorScheme.outlineVariant),
                Expanded(child: rightWidget),
              ],
            );
          }

          return Column(
            children: [
              Material(
                color: colorScheme.surface,
                child: TabBar(
                  controller: _mobileTabs,
                  tabs: [
                    Tab(text: strings.playbooksList),
                    Tab(
                      text: viewModel.isEditing
                          ? strings.editPlaybook
                          : strings.execution,
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: colorScheme.outlineVariant),
              Expanded(
                child: TabBarView(
                  controller: _mobileTabs,
                  children: [listWidget, rightWidget],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 请求 App Shell 切换到 AI 页面；Prompt 仍由 Module Service 暂存和消费。
class PlaybookAiNavigationNotification extends Notification {
  const PlaybookAiNavigationNotification();
}
