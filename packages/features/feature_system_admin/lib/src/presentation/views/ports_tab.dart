// System Admin Ports Tab：展示和刷新服务器监听端口快照。

part of 'system_admin_screen.dart';

class _PortsManageSnapshot {
  final bool isConnecting;
  final bool isManageModeAvailable;
  final String? errorMessage;
  final bool loadingPorts;
  final List<ListeningPort> ports;

  const _PortsManageSnapshot({
    required this.isConnecting,
    required this.isManageModeAvailable,
    required this.errorMessage,
    required this.loadingPorts,
    required this.ports,
  });

  factory _PortsManageSnapshot.from(SystemAdminViewModel vm) {
    return _PortsManageSnapshot(
      isConnecting: vm.isConnectingSelectedConnection,
      isManageModeAvailable: vm.canManageSelectedConnection,
      errorMessage: vm.hasManagementErrorForSelectedConnection
          ? vm.errorMessage
          : null,
      loadingPorts: vm.loadingPorts,
      ports: vm.ports,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _PortsManageSnapshot &&
        other.isConnecting == isConnecting &&
        other.isManageModeAvailable == isManageModeAvailable &&
        other.errorMessage == errorMessage &&
        other.loadingPorts == loadingPorts &&
        listEquals(other.ports, ports);
  }

  @override
  int get hashCode => Object.hash(
    isConnecting,
    isManageModeAvailable,
    errorMessage,
    loadingPorts,
    Object.hashAll(ports),
  );
}

class _PortsTab extends StatefulWidget {
  final AppStrings strings;
  final ColorScheme colorScheme;
  final SystemAdminViewModel viewModel;
  final ValueNotifier<int> activeTabIndex;

  const _PortsTab({
    super.key,
    required this.strings,
    required this.colorScheme,
    required this.viewModel,
    required this.activeTabIndex,
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

  bool get _isActive => widget.activeTabIndex.value == 1;

  void refresh() {
    final id = widget.viewModel.selectedConnectionId;
    if (id == null) return;
    if (_isManageMode && _isLinux) {
      unawaited(widget.viewModel.fetchPorts(id, force: true));
    } else {
      setState(() => _refreshPortsFuture(force: true));
    }
  }

  bool get _isLinux {
    final connectionId = widget.viewModel.selectedConnectionId;
    final config = widget.viewModel.connectionById(connectionId);
    return config?.serverPlatform == ServerPlatform.linux;
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
      _portsFuture = Future.delayed(const Duration(milliseconds: 300)).then((
        _,
      ) {
        if (!mounted || !_isActive) {
          return <String, List<PortProcessSnapshot>>{};
        }
        return _loadPorts(monitorViewModel, connectionId);
      });
    }
  }

  Future<Map<String, List<PortProcessSnapshot>>> _loadPorts(
    PerformanceMonitorViewModel monitorViewModel,
    String connectionId,
  ) async {
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
    if (_isActive) {
      _scheduleModeActivation();
    }
  }

  @override
  void initState() {
    super.initState();
    _lastSelectedConnectionId = widget.viewModel.selectedConnectionId;
    widget.activeTabIndex.addListener(_onTabChanged);
    _scheduleModeActivation();
  }

  @override
  void dispose() {
    widget.activeTabIndex.removeListener(_onTabChanged);
    super.dispose();
  }

  void _onTabChanged() {
    if (!mounted) return;
    if (_isActive) {
      _scheduleModeActivation();
    }
  }

  void _scheduleModeActivation() {
    if (!_isActive || _modeActivationScheduled) return;
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
      if (!mounted || !_isActive) return;
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
    final id = context.select<SystemAdminViewModel, String?>(
      (vm) => vm.selectedConnectionId,
    );

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

    if (_isActive) {
      _scheduleModeActivation();
    }

    return Column(
      children: [
        if (_isLinux) ...[
          _AdminModeToolbar(
            modeSelector: SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: true,
                  icon: const Icon(Icons.admin_panel_settings_rounded),
                  label: Text(
                    _monitorText(widget.strings, 'Manage Mode', '管理模式'),
                  ),
                ),
                ButtonSegment(
                  value: false,
                  icon: const Icon(Icons.analytics_rounded),
                  label: Text(
                    _monitorText(widget.strings, 'Snapshot Mode', '快照模式'),
                  ),
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
              : _buildSnapshotView(id),
        ),
      ],
    );
  }

  Widget _buildManageView(String id) {
    return Selector<SystemAdminViewModel, _PortsManageSnapshot>(
      selector: (_, vm) => _PortsManageSnapshot.from(vm),
      builder: (context, snapshot, _) {
        if (snapshot.isConnecting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (!snapshot.isManageModeAvailable) {
          return _RootRequiredView(
            strings: widget.strings,
            errorMessage: snapshot.errorMessage,
            onConnect: () {
              _lastActivatedModeKey = null;
              _scheduleModeActivation();
            },
          );
        }

        if (snapshot.loadingPorts) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.ports.isEmpty) {
          return RefreshIndicator(
            onRefresh: () => widget.viewModel.fetchPorts(id, force: true),
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
          onRefresh: () => widget.viewModel.fetchPorts(id, force: true),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _AdminListSurface(
              child: ListView.separated(
                itemCount: snapshot.ports.length,
                separatorBuilder: (_, _) => Divider(
                  height: 1,
                  thickness: 1,
                  color: widget.colorScheme.outlineVariant.withValues(
                    alpha: 0.5,
                  ),
                ),
                itemBuilder: (context, index) {
                  final p = snapshot.ports[index];
                  return ListTile(
                    leading: Icon(
                      p.protocol.contains('udp')
                          ? Icons.radio_button_checked
                          : Icons.swap_horizontal_circle,
                      color: widget.colorScheme.secondary,
                    ),
                    title: Row(
                      children: [
                        Text(
                          '${p.protocol.toUpperCase()}  :${p.localPort}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color:
                                    widget.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(
                                  AppTheme.radiusXs,
                                ),
                              ),
                              child: OverflowScrollText(
                                p.processName,
                                selectable: false,
                                maxLines: 1,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontFamilyFallback: [
                                    'Consolas',
                                    'Microsoft YaHei',
                                    'PingFang SC',
                                    'sans-serif',
                                  ],
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                ),
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
                        color: widget.colorScheme.onSurface.withValues(
                          alpha: 0.58,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
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
        widget.strings,
        'No listening ports found',
        '未发现监听端口',
      ),
      future: _portsFuture,
      showRefresh: false,
      onRefresh: () => setState(() => _refreshPortsFuture(force: true)),
      itemBuilder: (context, port) {
        return _PortProcessTile(strings: widget.strings, port: port);
      },
    );
  }
}
