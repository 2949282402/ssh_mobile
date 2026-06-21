import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/terminal/viewmodels/terminal_windows_viewmodel.dart';
import '../services/app_settings.dart';
import '../services/ssh_service.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import '../widgets/overflow_scroll_text.dart';

class TerminalWindowsScreen extends StatelessWidget {
  final String? connectionId;

  const TerminalWindowsScreen({
    super.key,
    this.connectionId,
  });

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings(context.watch<AppSettings>().language);

    return Scaffold(
      appBar: Navigator.canPop(context)
          ? AppBar(
              title: Text(strings.terminalWindows),
            )
          : null,
      body: SafeArea(
        child: TerminalWindowsPage(connectionId: connectionId),
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

  Widget _buildWindowList(
    BuildContext context,
    TerminalWindowsViewModel viewModel,
    List<SshSession> sessions,
    AppStrings strings,
  ) {
    if (widget.embedded) {
      final visibleSessions =
          sessions.take(_embeddedPreviewLimit).toList(growable: false);
      final hiddenCount = sessions.length - visibleSessions.length;

      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          children: [
            for (var index = 0; index < visibleSessions.length; index++) ...[
              if (index > 0) const SizedBox(height: 8),
              _buildWindowItem(
                context,
                viewModel,
                visibleSessions[index],
                strings,
              ),
            ],
            if (hiddenCount > 0) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.open_in_full_rounded, size: 16),
                  label: Text(strings.viewAllTerminalWindows(sessions.length)),
                  onPressed: () => Navigator.pushNamed(
                    context,
                    '/terminal-windows',
                    arguments: widget.connectionId,
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= AppBreakpoints.desktop;
        final columns = constraints.maxWidth >= AppBreakpoints.wideDesktop
            ? 3
            : desktop
                ? 2
                : 1;
        final horizontalPadding = desktop ? 24.0 : 12.0;

        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: desktop ? 1480 : double.infinity,
            ),
            child: columns == 1
                ? ListView.separated(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      8,
                      horizontalPadding,
                      24,
                    ),
                    itemCount: sessions.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      return _buildWindowItem(
                        context,
                        viewModel,
                        sessions[index],
                        strings,
                      );
                    },
                  )
                : GridView.builder(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      18,
                      horizontalPadding,
                      24,
                    ),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: 14,
                      mainAxisSpacing: 14,
                      mainAxisExtent: 210,
                    ),
                    itemCount: sessions.length,
                    itemBuilder: (context, index) {
                      return _buildWindowItem(
                        context,
                        viewModel,
                        sessions[index],
                        strings,
                      );
                    },
                  ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(
    BuildContext context,
    TerminalWindowsViewModel viewModel,
    List<SshSession> sessions,
    AppStrings strings,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          bottom: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          if (viewModel.selectionMode)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: strings.exitSelection,
              onPressed: viewModel.clearSelection,
            ),
          Expanded(
            child: Text(
              viewModel.selectionMode
                  ? strings.selectedWindows(viewModel.selectedSessionIds.length)
                  : strings.terminalWindows,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          if (viewModel.selectionMode) ...[
            IconButton(
              icon: const Icon(Icons.select_all),
              tooltip: strings.selectAll,
              onPressed: viewModel.selectAll,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: strings.closeSelectedWindows,
              color: colorScheme.error,
              onPressed: viewModel.selectedSessionIds.isEmpty
                  ? null
                  : () => _closeSelectedWindows(context, viewModel),
            ),
          ] else
            IconButton(
              icon: const Icon(Icons.history_rounded),
              tooltip: strings.connectionHistory,
              onPressed: () => Navigator.pushNamed(context, '/history'),
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, AppStrings strings) {
    final colorScheme = Theme.of(context).colorScheme;
    if (widget.embedded) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.34),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Text(
          strings.noOpenWindows,
          style: TextStyle(
            color: colorScheme.onSurfaceVariant,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.tab_unselected_rounded,
              size: 56,
              color: colorScheme.onSurface.withValues(alpha: 0.38),
            ),
            const SizedBox(height: 14),
            Text(
              strings.noOpenWindows,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              strings.openWindowsHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colorScheme.onSurface.withValues(alpha: 0.62),
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWindowItem(
    BuildContext context,
    TerminalWindowsViewModel viewModel,
    SshSession session,
    AppStrings strings,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final selected = viewModel.selectedSessionIds.contains(session.id);
    final statusColor = _statusColor(context, session);
    final cleanupCommand = session.tmuxKillCommand;

    return RepaintBoundary(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            if (viewModel.selectionMode) {
              viewModel.toggleSelection(session.id);
            } else {
              _openWindow(context, session);
            }
          },
          onLongPress: () {
            viewModel.toggleSelection(session.id);
          },
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: selected
                  ? colorScheme.primary.withValues(alpha: 0.12)
                  : colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected
                    ? colorScheme.primary.withValues(alpha: 0.55)
                    : colorScheme.outlineVariant,
              ),
            ),
            child: Row(
              children: [
                _buildLeadingIcon(
                    context, viewModel, session, selected, statusColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      OverflowScrollText(
                        session.displayName,
                        selectable: false,
                        maxLines: 1,
                        style: TextStyle(
                          color: colorScheme.onSurface,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      OverflowScrollText(
                        session.connectionName,
                        selectable: false,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurface.withValues(alpha: 0.58),
                        ),
                      ),
                      const SizedBox(height: 7),
                      Row(
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: statusColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: OverflowScrollText(
                              _statusLabel(session, strings),
                              selectable: false,
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 12,
                                color: colorScheme.onSurface
                                    .withValues(alpha: 0.68),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _buildSessionMeta(context, session, strings),
                      if (cleanupCommand != null) ...[
                        const SizedBox(height: 8),
                        _buildCleanupCommand(
                            context, viewModel, cleanupCommand, strings),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (!viewModel.selectionMode)
                  _windowActionButton(
                    icon: const Icon(Icons.open_in_new_rounded),
                    tooltip: strings.enterWindow,
                    onPressed: () => _openWindow(context, session),
                  ),
                _windowActionButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: strings.closeWindow,
                  color: session.isConnected ? null : colorScheme.error,
                  onPressed: () =>
                      _closeWindow(context, viewModel, session, strings),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _windowActionButton({
    required Widget icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color? color,
  }) {
    return SizedBox(
      width: 36,
      height: 36,
      child: IconButton(
        icon: icon,
        tooltip: tooltip,
        color: color,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildCleanupCommand(
    BuildContext context,
    TerminalWindowsViewModel viewModel,
    String command,
    AppStrings strings,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => _copyCleanupCommand(context, viewModel, command, strings),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            Icon(
              Icons.content_copy_rounded,
              size: 14,
              color: colorScheme.onSurface.withValues(alpha: 0.62),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: OverflowScrollText(
                command,
                selectable: false,
                maxLines: 1,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: colorScheme.onSurface.withValues(alpha: 0.78),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionMeta(
    BuildContext context,
    SshSession session,
    AppStrings strings,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final metaColor = colorScheme.onSurface.withValues(alpha: 0.62);

    return LayoutBuilder(
      builder: (context, constraints) {
        final chipWidth = constraints.maxWidth < 260
            ? constraints.maxWidth
            : (constraints.maxWidth - 8) / 2;
        return Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            _MetaChip(
              width: chipWidth,
              icon: Icons.schedule_rounded,
              label: strings.createdAt,
              value: _formatTime(session.createdAt),
              color: metaColor,
            ),
            _MetaChip(
              width: chipWidth,
              icon: Icons.timer_outlined,
              label: strings.autoDestroy,
              value: _formatAutoDestroy(session, strings),
              color: metaColor,
            ),
            _MetaChip(
              width: chipWidth,
              icon: Icons.memory_rounded,
              label: strings.memoryUsage,
              value: _formatBytes(session.estimatedMemoryBytes),
              color: metaColor,
            ),
          ],
        );
      },
    );
  }

  String _formatAutoDestroy(
    SshSession session,
    AppStrings strings,
  ) {
    final seconds = session.tmuxAutoDeleteSeconds;
    if (session.tmuxSessionName == null || seconds == null) {
      return strings.notAvailable;
    }

    final duration = _formatDuration(seconds, strings);
    if (session.isConnected || session.state == SshConnectionState.connecting) {
      return strings.autoDestroyAfter(duration);
    }

    return strings.autoDestroyAt(
      _formatTime(session.updatedAt.add(Duration(seconds: seconds))),
    );
  }

  String _formatDuration(int seconds, AppStrings strings) {
    if (seconds >= 60) {
      return strings.durationMinutes((seconds + 59) ~/ 60);
    }
    return strings.durationSeconds(seconds);
  }

  String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kib = bytes / 1024;
    if (kib < 1024) return '${kib.toStringAsFixed(kib < 10 ? 1 : 0)} KB';
    final mib = kib / 1024;
    return '${mib.toStringAsFixed(mib < 10 ? 1 : 0)} MB';
  }

  Widget _buildLeadingIcon(
    BuildContext context,
    TerminalWindowsViewModel viewModel,
    SshSession session,
    bool selected,
    Color statusColor,
  ) {
    if (viewModel.selectionMode) {
      return Icon(
        selected ? Icons.check_circle : Icons.radio_button_unchecked,
        color: selected ? Theme.of(context).colorScheme.primary : null,
        size: 28,
      );
    }

    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(Icons.terminal_rounded, color: statusColor, size: 22),
    );
  }

  Color _statusColor(BuildContext context, SshSession session) {
    final colorScheme = Theme.of(context).colorScheme;
    switch (session.state) {
      case SshConnectionState.connected:
        return colorScheme.secondary;
      case SshConnectionState.connecting:
        return AppTheme.terminalAmber;
      case SshConnectionState.error:
      case SshConnectionState.disconnected:
        return colorScheme.error;
    }
  }

  String _statusLabel(SshSession session, AppStrings strings) {
    switch (session.state) {
      case SshConnectionState.connected:
        return strings.connected;
      case SshConnectionState.connecting:
        return strings.connecting;
      case SshConnectionState.error:
        return session.errorMessage ?? strings.connectionError;
      case SshConnectionState.disconnected:
        return session.errorMessage ?? strings.disconnected;
    }
  }

  void _openWindow(BuildContext context, SshSession session) {
    Navigator.pushNamedAndRemoveUntil(
      context,
      '/terminal',
      (route) => route.isFirst,
      arguments: {
        'id': session.connectionId,
        'sessionId': session.id,
      },
    );
  }

  Future<void> _closeWindow(
    BuildContext context,
    TerminalWindowsViewModel viewModel,
    SshSession session,
    AppStrings strings,
  ) async {
    final cleanupCommand = session.tmuxKillCommand;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.closeTerminalWindow),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(strings.closeWindowTitle(session.displayName)),
            if (cleanupCommand != null) ...[
              const SizedBox(height: 12),
              Text(strings.staleTmuxHint),
              const SizedBox(height: 8),
              SelectableText(
                cleanupCommand,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ],
        ),
        actions: [
          if (cleanupCommand != null)
            TextButton.icon(
              onPressed: () {
                _copyCleanupCommand(
                    context, viewModel, cleanupCommand, strings);
                Navigator.pop(ctx, false);
              },
              icon: const Icon(Icons.content_copy_rounded),
              label: Text(strings.copyCommand),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(strings.close),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await viewModel.closeSession(session.id);
    }
  }

  Future<void> _copyCleanupCommand(
    BuildContext context,
    TerminalWindowsViewModel viewModel,
    String command,
    AppStrings strings,
  ) async {
    await viewModel.copyCleanupCommand(command);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(strings.copiedCleanupCommand)),
    );
  }

  Future<void> _closeSelectedWindows(
      BuildContext context, TerminalWindowsViewModel viewModel) async {
    final count = viewModel.selectedSessionIds.length;
    final strings = AppStrings(viewModel.language);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.closeSelectedWindows),
        content: Text(strings.closeSelectedContent(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(strings.close),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await viewModel.closeSelectedSessions();
    }
  }
}

class _MetaChip extends StatelessWidget {
  final double width;
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _MetaChip({
    required this.width,
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: Container(
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
            Flexible(
              child: Text(
                '$label $value',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
