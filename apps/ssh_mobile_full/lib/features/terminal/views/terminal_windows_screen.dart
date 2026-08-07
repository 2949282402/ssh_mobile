import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:ssh_mobile/features/terminal/viewmodels/terminal_windows_viewmodel.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:app_ui/app_ui.dart';
import 'package:ssh_mobile/widgets/ssh_host_key_trust_dialog.dart';
import 'package:ssh_mobile/widgets/window_name_dialog.dart';

part 'widgets/terminal_windows_content.dart';
part 'widgets/terminal_windows_actions.dart';

class TerminalWindowsScreen extends StatelessWidget {
  final String? connectionId;

  const TerminalWindowsScreen({super.key, this.connectionId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppPageSurface(
        child: SafeArea(child: TerminalWindowsPage(connectionId: connectionId)),
      ),
    );
  }
}

class TerminalWindowsPage extends StatefulWidget {
  final String? connectionId;
  final bool showHeader;
  final bool embedded;

  const TerminalWindowsPage({
    super.key,
    this.connectionId,
    this.showHeader = true,
    this.embedded = false,
  });

  @override
  State<TerminalWindowsPage> createState() => _TerminalWindowsPageState();
}

class _TerminalWindowsPageState extends State<TerminalWindowsPage> {
  static const int _embeddedPreviewLimit = 4;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<TerminalWindowsViewModel>(
      create: (context) => TerminalWindowsViewModel(
        sshService: context.read<SshService>(),
        appSettings: context.read<AppSettings>(),
      )..connectionId = widget.connectionId,
      child: Consumer<TerminalWindowsViewModel>(
        builder: (context, viewModel, child) {
          final sessions = viewModel.sessions;
          final strings = AppStrings(viewModel.language);

          final body = sessions.isEmpty
              ? _buildEmptyState(context, strings)
              : _buildWindowList(context, viewModel, sessions, strings);

          if (widget.embedded) return body;

          return Column(
            children: [
              if (widget.showHeader)
                _buildHeader(context, viewModel, sessions, strings),
              Expanded(child: body),
            ],
          );
        },
      ),
    );
  }

  TerminalWindowsPage get page => widget;
}

class _TerminalServerGroup {
  const _TerminalServerGroup({
    required this.connectionName,
    required this.sessions,
  });

  final String connectionName;
  final List<SshSession> sessions;
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _MetaChip({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.48),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Expanded(
            child: OverflowScrollText(
              '$label $value',
              selectable: false,
              maxLines: 1,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
