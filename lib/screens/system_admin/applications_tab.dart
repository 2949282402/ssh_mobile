part of '../system_admin_screen.dart';

class _ApplicationsTab extends StatefulWidget {
  final AppStrings strings;
  final ColorScheme colorScheme;
  final SystemAdminViewModel viewModel;
  final PerformanceMonitorViewModel monitorViewModel;

  const _ApplicationsTab({
    required this.strings,
    required this.colorScheme,
    required this.viewModel,
    required this.monitorViewModel,
  });

  @override
  State<_ApplicationsTab> createState() => _ApplicationsTabState();
}

class _ApplicationsTabState extends State<_ApplicationsTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  Future<Map<String, List<ApplicationMemorySnapshot>>>? _appsFuture;
  String? _appsSelectionKey;
  String? _lastSelectedConnectionId;

  void _refreshApplicationsFuture({bool force = false}) {
    final connectionId = widget.viewModel.selectedConnectionId;
    if (connectionId == null) {
      _appsSelectionKey = null;
      _appsFuture = null;
      return;
    }
    if (force || _appsFuture == null || _appsSelectionKey != connectionId) {
      _appsSelectionKey = connectionId;
      _appsFuture = _loadApplications(connectionId);
    }
  }

  Future<Map<String, List<ApplicationMemorySnapshot>>> _loadApplications(
      String connectionId) async {
    final result = <String, List<ApplicationMemorySnapshot>>{};
    result[connectionId] =
        await widget.monitorViewModel.fetchApplications(connectionId);
    return result;
  }

  @override
  void didUpdateWidget(covariant _ApplicationsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Connection checking is handled dynamically in build() using _lastSelectedConnectionId.
  }

  @override
  void initState() {
    super.initState();
    _lastSelectedConnectionId = widget.viewModel.selectedConnectionId;
    _refreshApplicationsFuture();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final connectionId = widget.viewModel.selectedConnectionId;

    if (connectionId != _lastSelectedConnectionId) {
      _lastSelectedConnectionId = connectionId;
      _refreshApplicationsFuture();
    }

    if (connectionId == null) {
      return Center(
        child: Text(_monitorText(
            widget.strings,
            'Please select a server on the left to view applications.',
            '请先在左侧选择要查看的服务器。')),
      );
    }

    final currentConfigList = widget.viewModel.connections
        .where((c) => c.id == connectionId)
        .toList();

    return _ServerSnapshotTab<ApplicationMemorySnapshot>(
      strings: widget.strings,
      connections: currentConfigList,
      emptyText: _monitorText(
          widget.strings, 'No application data found', '未发现应用数据'),
      future: _appsFuture,
      onRefresh: () => setState(() => _refreshApplicationsFuture(force: true)),
      itemBuilder: _buildApplicationItem,
    );
  }

  Widget _buildApplicationItem(
    BuildContext context,
    ApplicationMemorySnapshot app,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      leading: const Icon(Icons.apps_rounded),
      title: OverflowScrollText(
        app.command,
        selectable: false,
        maxLines: 1,
      ),
      subtitle: Text(
        'PID ${app.pid}  CPU ${app.cpuPercent.toStringAsFixed(1)}%',
        style: TextStyle(color: colorScheme.onSurfaceVariant),
      ),
      trailing: Text(
        _formatBytes(app.rssBytes),
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }
}
