import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/app_settings.dart';
import '../services/ssh_service.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';

class TerminalWindowsScreen extends StatelessWidget {
  const TerminalWindowsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: SafeArea(child: TerminalWindowsPage()));
  }
}

class TerminalWindowsPage extends StatefulWidget {
  const TerminalWindowsPage({super.key});

  @override
  State<TerminalWindowsPage> createState() => _TerminalWindowsPageState();
}

class _TerminalWindowsPageState extends State<TerminalWindowsPage> {
  final Set<String> _selectedSessionIds = {};
  bool _selectionMode = false;

  @override
  Widget build(BuildContext context) {
    final ssh = context.watch<SshService>();
    final sessions = ssh.sessions;
    final strings = AppStrings(context.watch<AppSettings>().language);

    _selectedSessionIds.removeWhere(
      (sessionId) => sessions.every((session) => session.id != sessionId),
    );
    if (_selectedSessionIds.isEmpty && _selectionMode) {
      _selectionMode = false;
    }

    return Column(
      children: [
        _buildHeader(context, sessions, strings),
        Expanded(
          child: sessions.isEmpty
              ? _buildEmptyState(context, strings)
              : _buildWindowList(context, sessions, strings),
        ),
      ],
    );
  }

  Widget _buildWindowList(
    BuildContext context,
    List<SshSession> sessions,
    AppStrings strings,
  ) {
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
          if (_selectionMode)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: strings.exitSelection,
              onPressed: _clearSelection,
            ),
          Expanded(
            child: Text(
              _selectionMode
                  ? strings.selectedWindows(_selectedSessionIds.length)
                  : strings.terminalWindows,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          if (_selectionMode) ...[
            IconButton(
              icon: const Icon(Icons.select_all),
              tooltip: strings.selectAll,
              onPressed: () => _selectAll(sessions),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: strings.closeSelectedWindows,
              color: colorScheme.error,
              onPressed: _selectedSessionIds.isEmpty
                  ? null
                  : () => _closeSelectedWindows(context),
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
    SshSession session,
    AppStrings strings,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final selected = _selectedSessionIds.contains(session.id);
    final statusColor = _statusColor(context, session);
    final cleanupCommand = session.tmuxKillCommand;

    return RepaintBoundary(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            if (_selectionMode) {
              _toggleSelection(session.id);
            } else {
              _openWindow(context, session);
            }
          },
          onLongPress: () {
            setState(() {
              _selectionMode = true;
              _selectedSessionIds.add(session.id);
            });
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
                _buildLeadingIcon(context, session, selected, statusColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colorScheme.onSurface,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        session.connectionName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                            child: Text(
                              _statusLabel(session, strings),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
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
                        _buildCleanupCommand(context, cleanupCommand),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (!_selectionMode)
                  _windowActionButton(
                    icon: const Icon(Icons.open_in_new_rounded),
                    tooltip: strings.enterWindow,
                    onPressed: () => _openWindow(context, session),
                  ),
                _windowActionButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: strings.closeWindow,
                  color: session.isConnected ? null : colorScheme.error,
                  onPressed: () => _closeWindow(context, session),
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

  Widget _buildCleanupCommand(BuildContext context, String command) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => _copyCleanupCommand(context, command),
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
              child: Text(
                command,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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

  String _formatAutoDestroy(SshSession session, AppStrings strings) {
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
    SshSession session,
    bool selected,
    Color statusColor,
  ) {
    if (_selectionMode) {
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

  void _toggleSelection(String sessionId) {
    setState(() {
      if (_selectedSessionIds.contains(sessionId)) {
        _selectedSessionIds.remove(sessionId);
      } else {
        _selectedSessionIds.add(sessionId);
      }
      _selectionMode = _selectedSessionIds.isNotEmpty;
    });
  }

  void _selectAll(List<SshSession> sessions) {
    setState(() {
      _selectionMode = true;
      _selectedSessionIds
        ..clear()
        ..addAll(sessions.map((session) => session.id));
    });
  }

  void _clearSelection() {
    setState(() {
      _selectionMode = false;
      _selectedSessionIds.clear();
    });
  }

  Future<void> _closeWindow(BuildContext context, SshSession session) async {
    final cleanupCommand = session.tmuxKillCommand;
    final strings = AppStrings(context.read<AppSettings>().language);
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
                _copyCleanupCommand(context, cleanupCommand, strings);
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

    if (confirmed != true || !context.mounted) return;
    await context.read<SshService>().disconnectSession(session.id);
  }

  Future<void> _copyCleanupCommand(
    BuildContext context,
    String command, [
    AppStrings? strings,
  ]) async {
    await Clipboard.setData(ClipboardData(text: command));
    if (!context.mounted) return;
    strings ??= AppStrings(context.read<AppSettings>().language);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(strings.copiedCleanupCommand)),
    );
  }

  Future<void> _closeSelectedWindows(BuildContext context) async {
    final count = _selectedSessionIds.length;
    final strings = AppStrings(context.read<AppSettings>().language);
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

    if (confirmed != true || !context.mounted) return;

    final ssh = context.read<SshService>();
    final ids = _selectedSessionIds.toList();
    _clearSelection();
    for (final sessionId in ids) {
      await ssh.disconnectSession(sessionId);
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
