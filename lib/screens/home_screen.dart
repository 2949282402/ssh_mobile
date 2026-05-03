import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/connection.dart';
import '../services/app_settings.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';

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
        title: const Text('SSH Mobile'),
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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.terminal_rounded,
            size: 80,
            color: Colors.grey[700],
          ),
          const SizedBox(height: 16),
          Text(
            strings.noConnections,
            style: TextStyle(
              color: Colors.grey[500],
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            strings.addHint,
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 14,
            ),
          ),
        ],
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: connections.length,
      itemBuilder: (context, index) {
        final conn = connections[index];
        final isActive = ssh.hasConnectedSession(conn.id);
        final sessionCount = ssh.sessionCountForConnection(conn.id);
        final isConnecting = ssh.latestSessionForConnection(conn.id)?.state ==
            SshConnectionState.connecting;
        final primary = Theme.of(context).colorScheme.primary;

        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _connectToServer(context, conn),
            child: Padding(
              padding: const EdgeInsets.all(16),
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
                        Text(
                          '${conn.username}@${conn.host}:${conn.port}',
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.7),
                          ),
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
    if (existing?.isConnected == true) {
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

  void _openNewTerminal(BuildContext context, ConnectionConfig conn) {
    final ssh = context.read<SshService>();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('Connecting to ${conn.name}'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(),
            ),
            SizedBox(height: 16),
            Text('Establishing SSH connection...'),
          ],
        ),
      ),
    );

    ssh.openSession(conn.id).then((sessionId) {
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text('Connection failed: ${ssh.errorMessage ?? "Unknown"}'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    });
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
