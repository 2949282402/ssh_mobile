import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../services/storage_service.dart';
import '../services/ssh_service.dart';
import '../models/connection.dart';
import '../theme/app_theme.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final storage = context.watch<StorageService>();
    final ssh = context.watch<SshService>();
    final connections = storage.connections;

    return Scaffold(
      appBar: AppBar(
        title: const Text('SSH Mobile'),
        actions: [
          if (ssh.activeConnectionId != null)
            IconButton(
              icon: const Icon(Icons.close, color: Colors.redAccent),
              tooltip: '断开连接',
              onPressed: () => _disconnect(context),
            ),
        ],
      ),
      body: connections.isEmpty
          ? _buildEmptyState(context)
          : _buildConnectionList(context, connections, ssh),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _addConnection(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
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
            '还没有保存的服务器',
            style: TextStyle(
              color: Colors.grey[500],
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '点击右下角 + 添加连接',
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
  ) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: connections.length,
      itemBuilder: (context, index) {
        final conn = connections[index];
        final isActive = ssh.activeConnectionId == conn.id;
        final isConnecting = isActive &&
            ssh.state == SshConnectionState.connecting;

        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _connectToServer(context, conn),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  // 状态图标
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: isActive
                          ? AppTheme.terminalGreen.withOpacity(0.15)
                          : AppTheme.darkTheme.colorScheme.primary
                              .withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      _getStatusIcon(conn, ssh),
                      color: isActive
                          ? AppTheme.terminalGreen
                          : AppTheme.darkTheme.colorScheme.primary,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 14),
                  // 服务器信息
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
                            color: Colors.grey[400],
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 操作按钮
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
                        color: Colors.grey[500],
                      ),
                      onSelected: (action) =>
                          _handleAction(context, conn, action),
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'edit',
                          child: Row(
                            children: [
                              Icon(Icons.edit, size: 18),
                              SizedBox(width: 8),
                              Text('编辑'),
                            ],
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(Icons.delete, size: 18, color: Colors.red),
                              SizedBox(width: 8),
                              Text('删除', style: TextStyle(color: Colors.red)),
                            ],
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  IconData _getStatusIcon(ConnectionConfig conn, SshService ssh) {
    if (ssh.activeConnectionId == conn.id) {
      if (ssh.isConnected) return Icons.link;
      if (ssh.state == SshConnectionState.connecting) return Icons.sync;
      return Icons.link_off;
    }
    return Icons.dns_outlined;
  }

  void _connectToServer(BuildContext context, ConnectionConfig conn) {
    final ssh = context.read<SshService>();

    // 如果已连接同一个服务器，进入终端
    if (ssh.activeConnectionId == conn.id && ssh.isConnected) {
      Navigator.pushNamed(context, '/terminal', arguments: {'id': conn.id});
      return;
    }

    // 否则先连接再进入终端
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('连接中: ${conn.name}'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(),
            ),
            SizedBox(height: 16),
            Text('正在建立 SSH 连接...'),
          ],
        ),
      ),
    );

    ssh.connect(conn.id).then((_) {
      // 弹出等待对话框
      if (context.mounted) {
        Navigator.of(context).pop(); // pop dialog
      }
      if (ssh.isConnected) {
        Navigator.pushNamed(
          context,
          '/terminal',
          arguments: {'id': conn.id},
        );
      } else if (ssh.state == SshConnectionState.error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('连接失败: ${ssh.errorMessage ?? "未知错误"}'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    });
  }

  void _handleAction(
      BuildContext context, ConnectionConfig conn, String action) {
    switch (action) {
      case 'edit':
        Navigator.pushNamed(context, '/edit', arguments: conn.id);
        break;
      case 'delete':
        _confirmDelete(context, conn);
        break;
    }
  }

  void _confirmDelete(BuildContext context, ConnectionConfig conn) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除连接'),
        content: Text('确定删除 "${conn.name}" 吗？\n密码和私钥也会被一并清除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              context.read<StorageService>().deleteConnection(conn.id);
              Navigator.pop(ctx);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  void _disconnect(BuildContext context) {
    context.read<SshService>().disconnect();
  }

  void _addConnection(BuildContext context) {
    Navigator.pushNamed(context, '/add');
  }
}
