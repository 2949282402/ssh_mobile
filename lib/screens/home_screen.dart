import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/connection.dart';
import '../services/app_settings.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/connection_progress_dialog.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final storage = context.watch<StorageService>();
    final ssh = context.watch<SshService>();
    final settings = context.watch<AppSettings>();
    final strings = AppStrings(settings.language);
    final connections = storage.connections;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'SSH Mobile',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          TextButton(
            onPressed: settings.toggleLanguage,
            child: Text(
              settings.isEnglish
                  ? strings.switchToChinese
                  : strings.switchToEnglish,
            ),
          ),
          IconButton(
            icon: Icon(
              settings.isDarkMode ? Icons.light_mode : Icons.dark_mode,
            ),
            tooltip: settings.isDarkMode ? strings.lightMode : strings.darkMode,
            onPressed: settings.toggleTheme,
          ),
          if (ssh.sessions.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close, color: Colors.redAccent),
              tooltip: strings.disconnectAllTooltip,
              onPressed: () => _disconnect(context),
            ),
        ],
      ),
      body: connections.isEmpty
          ? storage.initialized
              ? _buildEmptyState(context, strings)
              : _buildLoadingState()
          : _buildConnectionList(context, connections, ssh, strings),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _addConnection(context),
        tooltip: strings.addConnection,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildLoadingState() {
    return const Center(
      child: SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(strokeWidth: 2),
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
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: colorScheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: colorScheme.primary.withValues(alpha: 0.18),
                ),
              ),
              child: Icon(
                Icons.terminal_rounded,
                size: 42,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              strings.noConnections,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              strings.addHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colorScheme.onSurface.withValues(alpha: 0.62),
                fontSize: 14,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionList(
    BuildContext context,
    List<ConnectionConfig> connections,
    SshService ssh,
    AppStrings strings,
  ) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
      itemCount: connections.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return _buildOverviewHeader(context, connections, ssh);
        }

        final conn = connections[index - 1];
        final isActive = ssh.hasConnectedSession(conn.id);
        final sessionCount = ssh.sessionCountForConnection(conn.id);
        final isConnecting = ssh.latestSessionForConnection(conn.id)?.state ==
            SshConnectionState.connecting;
        final primary = Theme.of(context).colorScheme.primary;

        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _connectToServer(context, conn),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isActive
                      ? AppTheme.terminalGreen.withValues(alpha: 0.42)
                      : Theme.of(context).dividerColor,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: Theme.of(context).brightness == Brightness.dark
                          ? 0.12
                          : 0.04,
                    ),
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: isActive
                          ? AppTheme.terminalGreen.withValues(alpha: 0.15)
                          : primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      _getStatusIcon(conn, ssh),
                      color: isActive ? AppTheme.terminalGreen : primary,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          conn.name,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Icons.dns_outlined,
                              size: 13,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.48),
                            ),
                            const SizedBox(width: 5),
                            Expanded(
                              child: Text(
                                '${conn.username}@${conn.host}:${conn.port}',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withValues(alpha: 0.66),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (isConnecting)
                    const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    PopupMenuButton<String>(
                      icon: Icon(
                        Icons.more_vert,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.65),
                      ),
                      onSelected: (action) =>
                          _handleAction(context, conn, action),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'new_terminal',
                          child: Row(
                            children: [
                              const Icon(Icons.add_to_photos, size: 18),
                              const SizedBox(width: 8),
                              Text(strings.newWindow),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'edit',
                          child: Row(
                            children: [
                              const Icon(Icons.edit, size: 18),
                              const SizedBox(width: 8),
                              Text(strings.edit),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              const Icon(
                                Icons.delete,
                                size: 18,
                                color: Colors.red,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                strings.delete,
                                style: const TextStyle(color: Colors.red),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  if (sessionCount > 0) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.terminalGreen.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: AppTheme.terminalGreen.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Text(
                        '$sessionCount',
                        style: const TextStyle(
                          color: AppTheme.terminalGreen,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildOverviewHeader(
    BuildContext context,
    List<ConnectionConfig> connections,
    SshService ssh,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final activeCount =
        connections.where((conn) => ssh.hasConnectedSession(conn.id)).length;
    final windowCount = ssh.sessions.length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        child: Row(
          children: [
            _summaryItem(
              context,
              icon: Icons.storage_rounded,
              label: 'Servers',
              value: '${connections.length}',
            ),
            const SizedBox(width: 10),
            _summaryItem(
              context,
              icon: Icons.link_rounded,
              label: 'Active',
              value: '$activeCount',
              accent: AppTheme.terminalGreen,
            ),
            const SizedBox(width: 10),
            _summaryItem(
              context,
              icon: Icons.tab_rounded,
              label: 'Windows',
              value: '$windowCount',
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryItem(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    Color? accent,
  }) {
    final color = accent ?? Theme.of(context).colorScheme.primary;
    return Expanded(
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 17, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _getStatusIcon(ConnectionConfig conn, SshService ssh) {
    final session = ssh.latestSessionForConnection(conn.id);
    if (session != null) {
      if (session.state == SshConnectionState.connected) return Icons.link;
      if (session.state == SshConnectionState.connecting) return Icons.sync;
      return Icons.link_off;
    }
    return Icons.dns_outlined;
  }

  void _connectToServer(BuildContext context, ConnectionConfig conn) {
    final ssh = context.read<SshService>();

    final existing = ssh.latestSessionForConnection(conn.id);
    if (existing?.isConnected == true ||
        (existing != null && conn.launchMode == TerminalLaunchMode.tmux)) {
      Navigator.pushNamed(
        context,
        '/terminal',
        arguments: {
          'id': conn.id,
          'sessionId': existing!.id,
        },
      );
      return;
    }

    _openNewTerminal(context, conn);
  }

  Future<void> _openNewTerminal(
    BuildContext context,
    ConnectionConfig conn,
  ) async {
    await _openNewTerminalWithOptions(context, conn);
  }

  Future<void> _openNewTerminalWithOptions(
    BuildContext context,
    ConnectionConfig conn, {
    bool allowTmuxInstall = false,
  }) async {
    final ssh = context.read<SshService>();

    showDialog(
      context: context,
      barrierDismissible: false,
      useSafeArea: false,
      builder: (ctx) => ConnectionProgressDialog(
        title: 'Connecting to ${conn.name}',
        message: 'Establishing SSH connection...',
      ),
    );

    await waitForConnectionProgressFrame();
    if (!context.mounted) return;

    final sessionId = await ssh.openSession(
      conn.id,
      allowTmuxInstall: allowTmuxInstall,
    );
    if (!context.mounted) return;
    Navigator.of(context).pop();

    if (sessionId != null) {
      Navigator.pushNamed(
        context,
        '/terminal',
        arguments: {
          'id': conn.id,
          'sessionId': sessionId,
        },
      );
    } else {
      if (!allowTmuxInstall &&
          conn.launchMode == TerminalLaunchMode.tmux &&
          _isTmuxMissingError(ssh.errorMessage)) {
        final confirmed = await _confirmInstallTmux(context, conn);
        if (confirmed == true && context.mounted) {
          await _openNewTerminalWithOptions(
            context,
            conn,
            allowTmuxInstall: true,
          );
        }
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_formatConnectionFailure(ssh.errorMessage)),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  bool _isTmuxMissingError(String? message) {
    return message?.toLowerCase().contains('tmux is not installed') == true;
  }

  String _formatConnectionFailure(String? message) {
    final text = message ?? 'Unknown';
    final lower = text.toLowerCase();
    if (lower.contains('tmux automatic install failed') ||
        lower.contains('unable to check tmux')) {
      return 'Connection failed: $text\n请手动登录服务器安装 tmux 后再重试。';
    }
    return 'Connection failed: $text';
  }

  Future<bool?> _confirmInstallTmux(
    BuildContext context,
    ConnectionConfig conn,
  ) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('服务器未安装 tmux'),
        content: Text(
          '连接 "${conn.name}" 需要 tmux。是否允许应用在服务器上尝试安装 tmux？\n\n'
          '安装会使用服务器上的 apt、dnf、yum、pacman、zypper、apk 或 pkg，并且可能需要当前用户拥有免密 sudo 或 root 权限。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('同意安装'),
          ),
        ],
      ),
    );
  }

  void _handleAction(
    BuildContext context,
    ConnectionConfig conn,
    String action,
  ) {
    switch (action) {
      case 'new_terminal':
        _openNewTerminal(context, conn);
        break;
      case 'edit':
        Navigator.pushNamed(context, '/edit', arguments: conn.id);
        break;
      case 'delete':
        _confirmDelete(context, conn);
        break;
    }
  }

  void _confirmDelete(BuildContext context, ConnectionConfig conn) {
    final strings = AppStrings(context.read<AppSettings>().language);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.deleteConnectionTitle),
        content: Text(strings.deleteConnectionContent(conn.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () {
              context.read<StorageService>().deleteConnection(conn.id);
              Navigator.pop(ctx);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(strings.delete),
          ),
        ],
      ),
    );
  }

  Future<void> _disconnect(BuildContext context) async {
    final ssh = context.read<SshService>();
    final strings = AppStrings(context.read<AppSettings>().language);
    final windowCount = ssh.sessions.length;
    if (windowCount == 0) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.closeAllTitle),
        content: Text(strings.closeAllContent(windowCount)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(strings.closeAll),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;
    await ssh.disconnect();
  }

  void _addConnection(BuildContext context) {
    Navigator.pushNamed(context, '/add');
  }
}
