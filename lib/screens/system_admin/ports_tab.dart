part of '../system_admin_screen.dart';

class _PortsTab extends StatefulWidget {
  final AppStrings strings;
  final ColorScheme colorScheme;
  final SystemAdminViewModel viewModel;

  const _PortsTab({
    required this.strings,
    required this.colorScheme,
    required this.viewModel,
  });

  @override
  State<_PortsTab> createState() => _PortsTabState();
}

class _PortsTabState extends State<_PortsTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  bool _isManageMode = true;
  Future<Map<String, List<PortProcessSnapshot>>>? _portsFuture;
  String? _portsSelectionKey;
  String? _lastSelectedConnectionId;

  bool get _isLinux {
    final connectionId = widget.viewModel.selectedConnectionId;
    if (connectionId == null) return false;
    final config = widget.viewModel.connections.firstWhere((c) => c.id == connectionId);
    return config.serverPlatform == ServerPlatform.linux;
  }

  bool get _isManageModeAvailable {
    return widget.viewModel.isConnected &&
        widget.viewModel.isRoot &&
        widget.viewModel.managementConnectionId == widget.viewModel.selectedConnectionId &&
        _isLinux;
  }

  void _refreshPortsFuture({bool force = false}) {
    final connectionId = widget.viewModel.selectedConnectionId;
    if (connectionId == null) {
      _portsSelectionKey = null;
      _portsFuture = null;
      return;
    }
    final monitorViewModel = context.read<PerformanceMonitorViewModel>();
    if (force || _portsFuture == null || _portsSelectionKey != connectionId) {
      _portsSelectionKey = connectionId;
      _portsFuture = _loadPorts(monitorViewModel, connectionId);
    }
  }

  Future<Map<String, List<PortProcessSnapshot>>> _loadPorts(
      PerformanceMonitorViewModel monitorViewModel, String connectionId) async {
    final result = <String, List<PortProcessSnapshot>>{};
    result[connectionId] = await monitorViewModel.fetchPorts(connectionId);
    return result;
  }

  @override
  void didUpdateWidget(covariant _PortsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Since viewModel reference is the same, we check selectionId inside build() dynamically.
  }

  @override
  void initState() {
    super.initState();
    _lastSelectedConnectionId = widget.viewModel.selectedConnectionId;
    _isManageMode = _isManageModeAvailable;
    _refreshPortsFuture();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final viewModel = widget.viewModel;
    final id = viewModel.selectedConnectionId;

    if (id != _lastSelectedConnectionId) {
      _lastSelectedConnectionId = id;
      _refreshPortsFuture();
      _isManageMode = _isManageModeAvailable;
    }

    if (id == null) {
      return Center(
        child: Text(_monitorText(
            widget.strings,
            'Please select a server on the left to view ports.',
            '请先在左侧选择要查看的服务器。')),
      );
    }

    if (!_isManageModeAvailable && _isManageMode) {
      _isManageMode = false;
    }

    return Column(
      children: [
        if (_isManageModeAvailable) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: true,
                  icon: const Icon(Icons.admin_panel_settings_rounded),
                  label: Text(_monitorText(widget.strings, 'Manage Mode', '管理模式')),
                ),
                ButtonSegment(
                  value: false,
                  icon: const Icon(Icons.analytics_rounded),
                  label: Text(_monitorText(widget.strings, 'Snapshot Mode', '快照模式')),
                ),
              ],
              selected: {_isManageMode},
              onSelectionChanged: (values) {
                setState(() {
                  _isManageMode = values.first;
                });
              },
            ),
          ),
        ] else ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: widget.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _monitorText(
                      widget.strings,
                      'Manage mode unavailable (root required). Switched to snapshot mode.',
                      '当前无法使用管理模式（需要 root 权限），已自动切换为快照模式。',
                    ),
                    style: TextStyle(
                      color: widget.colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
                if (_isLinux)
                  TextButton.icon(
                    icon: const Icon(Icons.admin_panel_settings_rounded, size: 16),
                    label: Text(_monitorText(widget.strings, 'Connect Root', '连接 Root')),
                    onPressed: () => viewModel.connect(id),
                  ),
              ],
            ),
          ),
        ],
        Expanded(
          child: _isManageMode ? _buildManageView(id) : _buildSnapshotView(id),
        ),
      ],
    );
  }

  Widget _buildManageView(String id) {
    final viewModel = widget.viewModel;
    if (viewModel.loadingPorts) {
      return const Center(child: CircularProgressIndicator());
    }

    if (viewModel.ports.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => viewModel.fetchPorts(id),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 100),
            Center(child: Text('No listening ports found.')),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => viewModel.fetchPorts(id),
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: viewModel.ports.length,
        itemBuilder: (context, index) {
          final p = viewModel.ports[index];
          return Card(
            child: ListTile(
              leading: Icon(
                p.protocol.contains('udp')
                    ? Icons.radio_button_checked
                    : Icons.swap_horizontal_circle,
                color: widget.colorScheme.secondary,
              ),
              title: Row(
                children: [
                  Text('${p.protocol.toUpperCase()}  :${p.localPort}',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: widget.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: OverflowScrollText(
                          p.processName,
                          selectable: false,
                          maxLines: 1,
                          style: const TextStyle(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.bold,
                              fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              subtitle: OverflowScrollText(
                'Address: ${p.localAddress} ${p.pid != null ? '• PID: ${p.pid}' : ''}',
                selectable: false,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 12,
                  color: widget.colorScheme.onSurface.withValues(alpha: 0.58),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSnapshotView(String id) {
    final currentConfigList = widget.viewModel.connections
        .where((c) => c.id == id)
        .toList();

    return _ServerSnapshotTab<PortProcessSnapshot>(
      strings: widget.strings,
      connections: currentConfigList,
      emptyText: _monitorText(
          widget.strings, 'No listening ports found', '未发现监听端口'),
      future: _portsFuture,
      onRefresh: () => setState(() => _refreshPortsFuture(force: true)),
      itemBuilder: (context, port) {
        return _PortProcessTile(
          strings: widget.strings,
          port: port,
        );
      },
    );
  }
}
