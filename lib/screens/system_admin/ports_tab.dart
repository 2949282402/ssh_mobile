part of '../system_admin_screen.dart';

class _PortsTab extends StatefulWidget {
  final AppStrings strings;
  final ColorScheme colorScheme;
  final SystemAdminViewModel viewModel;
  final bool active;

  const _PortsTab({
    required this.strings,
    required this.colorScheme,
    required this.viewModel,
    required this.active,
  });

  @override
  State<_PortsTab> createState() => _PortsTabState();
}

class _PortsTabState extends State<_PortsTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  bool _isManageMode = false;
  Future<Map<String, List<PortProcessSnapshot>>>? _portsFuture;
  String? _portsSelectionKey;
  String? _lastSelectedConnectionId;
  String? _lastActivatedModeKey;
  bool _modeActivationScheduled = false;

  bool get _isLinux {
    final connectionId = widget.viewModel.selectedConnectionId;
    final config = widget.viewModel.connectionById(connectionId);
    return config?.serverPlatform == ServerPlatform.linux;
  }

  bool get _isManageModeAvailable {
    return widget.viewModel.canManageSelectedConnection && _isLinux;
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
    final data = await monitorViewModel.fetchPorts(
      connectionId,
      onUnknownHostKey: (request) =>
          showSshHostKeyTrustDialog(context, request),
    );

    if (!mounted || widget.viewModel.selectedConnectionId != connectionId) {
      return {};
    }

    return {connectionId: data};
  }

  @override
  void didUpdateWidget(covariant _PortsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final id = widget.viewModel.selectedConnectionId;
    if (id != _lastSelectedConnectionId) {
      _lastSelectedConnectionId = id;
      _portsSelectionKey = null;
      _portsFuture = null;
      _lastActivatedModeKey = null;
      _isManageMode = false;
    }
    if (widget.active) {
      _scheduleModeActivation();
    }
  }

  @override
  void initState() {
    super.initState();
    _lastSelectedConnectionId = widget.viewModel.selectedConnectionId;
    _scheduleModeActivation();
  }

  void _scheduleModeActivation() {
    if (!widget.active || _modeActivationScheduled) return;
    final id = widget.viewModel.selectedConnectionId;
    if (id == null) return;

    final mode = _isManageMode && _isLinux ? 'manage' : 'snapshot';
    final modeKey = '$id:$mode';
    final snapshotReady =
        mode == 'snapshot' && _portsFuture != null && _portsSelectionKey == id;
    if (_lastActivatedModeKey == modeKey && snapshotReady) return;
    if (_lastActivatedModeKey == modeKey && mode == 'manage') return;

    _modeActivationScheduled = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _modeActivationScheduled = false;
      if (!mounted || !widget.active) return;
      unawaited(_activateCurrentMode());
    });
  }

  Future<void> _activateCurrentMode() async {
    final id = widget.viewModel.selectedConnectionId;
    if (id == null) return;

    final mode = _isManageMode && _isLinux ? 'manage' : 'snapshot';
    final modeKey = '$id:$mode';
    final snapshotReady =
        mode == 'snapshot' && _portsFuture != null && _portsSelectionKey == id;
    if (_lastActivatedModeKey == modeKey && snapshotReady) return;
    if (_lastActivatedModeKey == modeKey && mode == 'manage') return;
    _lastActivatedModeKey = modeKey;

    if (mode == 'manage') {
      await widget.viewModel.connectIfNeeded(
        id,
        onUnknownHostKey: (request) =>
            showSshHostKeyTrustDialog(context, request),
      );
      if (!mounted) return;

      if (widget.viewModel.canManageSelectedConnection) {
        await widget.viewModel.fetchPorts(id);
      }
      return;
    }

    setState(() {
      _refreshPortsFuture();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final viewModel = widget.viewModel;
    final id = viewModel.selectedConnectionId;

    if (id == null) {
      return Center(
        child: Text(
          _selectServerHint(
            context,
            widget.strings.language,
            targetEn: 'ports',
            targetZh: '端口',
          ),
        ),
      );
    }

    if (widget.active) {
      _scheduleModeActivation();
    }

    return Column(
      children: [
        if (_isLinux) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: true,
                  icon: const Icon(Icons.admin_panel_settings_rounded),
                  label:
                      Text(_monitorText(widget.strings, 'Manage Mode', '管理模式')),
                ),
                ButtonSegment(
                  value: false,
                  icon: const Icon(Icons.analytics_rounded),
                  label: Text(
                      _monitorText(widget.strings, 'Snapshot Mode', '快照模式')),
                ),
              ],
              selected: {_isManageMode},
              onSelectionChanged: (values) {
                setState(() {
                  _isManageMode = values.first;
                  _lastActivatedModeKey = null;
                });
                _scheduleModeActivation();
              },
            ),
          ),
        ],
        Expanded(
            child: _isManageMode && _isLinux
                ? _buildManageView(id)
                : _buildSnapshotView(id)),
      ],
    );
  }

  Widget _buildManageView(String id) {
    final viewModel = widget.viewModel;
    if (viewModel.isConnectingSelectedConnection) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!_isManageModeAvailable) {
      return _RootRequiredView(
        strings: widget.strings,
        errorMessage: viewModel.hasManagementErrorForSelectedConnection
            ? viewModel.errorMessage
            : null,
        onConnect: () {
          _lastActivatedModeKey = null;
          _scheduleModeActivation();
        },
      );
    }

    if (viewModel.loadingPorts) {
      return const Center(child: CircularProgressIndicator());
    }

    if (viewModel.ports.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => viewModel.fetchPorts(id, force: true),
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
      onRefresh: () => viewModel.fetchPorts(id, force: true),
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
    final currentConfigList =
        widget.viewModel.connections.where((c) => c.id == id).toList();

    return _ServerSnapshotTab<PortProcessSnapshot>(
      strings: widget.strings,
      connections: currentConfigList,
      emptyText:
          _monitorText(widget.strings, 'No listening ports found', '未发现监听端口'),
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
