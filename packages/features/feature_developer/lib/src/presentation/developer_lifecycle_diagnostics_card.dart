import 'package:flutter/material.dart';

import '../domain/developer_diagnostics_models.dart';

/// Developer Panel 的生命周期诊断卡片。
///
/// 该组件只渲染已由 App Shell 采集的只读快照，不主动访问 Module、数据库、
/// SSH 或 Network 实现，因此不会因为打开诊断页而改变资源生命周期。
final class DeveloperLifecycleDiagnosticsCard extends StatelessWidget {
  /// 创建生命周期诊断卡片。
  const DeveloperLifecycleDiagnosticsCard({super.key, required this.snapshot});

  /// 当前诊断快照。
  final DeveloperDiagnosticsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.account_tree_outlined, size: 20),
                SizedBox(width: 8),
                Text(
                  'Lifecycle Diagnostics',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Known resources reported by their owners.',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            _buildModules(context),
            _buildDivider(),
            _buildSsh(context),
            _buildDivider(),
            _buildNetwork(context),
            _buildDivider(),
            _buildDatabases(context),
            _buildDivider(),
            _buildResources(context),
          ],
        ),
      ),
    );
  }

  Widget _buildModules(BuildContext context) {
    return _section(
      context,
      'Modules',
      snapshot.modules.isEmpty
          ? [_emptyRow(context)]
          : [
              for (final module in snapshot.modules)
                _twoValueRow(
                  context,
                  module.id,
                  'initialized: ${module.initialized ? 'yes' : 'no'}',
                  'active: ${module.active ? 'yes' : 'no'}',
                ),
            ],
    );
  }

  Widget _buildSsh(BuildContext context) {
    return _section(context, 'SSH', [
      _metricRow(context, 'Active sessions', '${snapshot.ssh.activeSessions}'),
      _metricRow(context, 'Idle sessions', '${snapshot.ssh.idleSessions}'),
      _metricRow(context, 'Lease count', '${snapshot.ssh.leaseCount}'),
    ]);
  }

  Widget _buildNetwork(BuildContext context) {
    return _section(context, 'Network', [
      _metricRow(
        context,
        'Active connections',
        '${snapshot.network.activeConnections}',
      ),
      _metricRow(
        context,
        'Native handles',
        '${snapshot.network.nativeHandles}',
      ),
    ]);
  }

  Widget _buildDatabases(BuildContext context) {
    return _section(
      context,
      'Databases',
      snapshot.databases.isEmpty
          ? [_emptyRow(context)]
          : [
              for (final database in snapshot.databases)
                _twoValueRow(
                  context,
                  database.databaseName,
                  database.moduleId,
                  database.opened ? 'opened' : 'closed',
                ),
            ],
    );
  }

  Widget _buildResources(BuildContext context) {
    return _section(context, 'Resources', [
      _metricRow(context, 'Timers', '${snapshot.resources.activeTimers}'),
      _metricRow(
        context,
        'Streams',
        '${snapshot.resources.activeSubscriptions} subscriptions',
      ),
    ]);
  }

  Widget _section(BuildContext context, String title, List<Widget> children) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        ...children,
      ],
    );
  }

  Widget _metricRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: _label(context, label)),
          Text(value, style: const TextStyle(fontFamily: 'monospace')),
        ],
      ),
    );
  }

  Widget _twoValueRow(
    BuildContext context,
    String label,
    String firstValue,
    String secondValue,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: _label(context, label)),
          const SizedBox(width: 8),
          Text(firstValue, style: const TextStyle(fontFamily: 'monospace')),
          const SizedBox(width: 8),
          Text(secondValue, style: const TextStyle(fontFamily: 'monospace')),
        ],
      ),
    );
  }

  Widget _label(BuildContext context, String value) {
    return Text(
      value,
      style: TextStyle(
        fontSize: 12,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
    );
  }

  Widget _emptyRow(BuildContext context) => _label(context, '—');

  Widget _buildDivider() => const Padding(
    padding: EdgeInsets.symmetric(vertical: 8),
    child: Divider(height: 1),
  );
}
