part of '../system_admin_screen.dart';

class _ServicesTab extends StatefulWidget {
  final AppStrings strings;
  final ColorScheme colorScheme;
  final SystemAdminViewModel viewModel;

  const _ServicesTab({
    required this.strings,
    required this.colorScheme,
    required this.viewModel,
  });

  @override
  State<_ServicesTab> createState() => _ServicesTabState();
}

class _ServicesTabState extends State<_ServicesTab>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _serviceSearchController =
      TextEditingController();
  final TextEditingController _snapshotSearchController =
      TextEditingController();
  List<SystemdService> _filteredServices = [];
  List<ServiceStatusSnapshot> _filteredSnapshotServices = [];
  Map<String, List<ServiceStatusSnapshot>> _rawSnapshotData = {};

  bool _isManageMode = true;
  Future<Map<String, List<ServiceStatusSnapshot>>>? _servicesFuture;
  String? _servicesSelectionKey;
  String? _lastSelectedConnectionId;

  @override
  bool get wantKeepAlive => true;

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

  void _refreshServicesFuture({bool force = false}) {
    final connectionId = widget.viewModel.selectedConnectionId;
    if (connectionId == null) {
      _servicesSelectionKey = null;
      _servicesFuture = null;
      return;
    }
    final monitorViewModel = context.read<PerformanceMonitorViewModel>();
    if (force || _servicesFuture == null || _servicesSelectionKey != connectionId) {
      _servicesSelectionKey = connectionId;
      _servicesFuture = _loadServices(monitorViewModel, connectionId);
    }
  }

  Future<Map<String, List<ServiceStatusSnapshot>>> _loadServices(
      PerformanceMonitorViewModel monitorViewModel, String connectionId) async {
    final result = <String, List<ServiceStatusSnapshot>>{};
    final list = await monitorViewModel.fetchServices(connectionId);
    result[connectionId] = list;
    _rawSnapshotData = result;
    _filterSnapshotServices();
    return result;
  }

  @override
  void initState() {
    super.initState();
    _lastSelectedConnectionId = widget.viewModel.selectedConnectionId;
    _isManageMode = _isManageModeAvailable;
    _serviceSearchController.addListener(_filterServices);
    _snapshotSearchController.addListener(_filterSnapshotServices);
    _filteredServices = List.from(widget.viewModel.services);
    _refreshServicesFuture();
  }

  @override
  void didUpdateWidget(covariant _ServicesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.viewModel.services != oldWidget.viewModel.services) {
      _filterServices();
    }
  }

  @override
  void dispose() {
    _serviceSearchController.dispose();
    _snapshotSearchController.dispose();
    super.dispose();
  }

  void _filterServices() {
    if (!mounted) return;
    final query = _serviceSearchController.text.trim().toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredServices = List.from(widget.viewModel.services);
      } else {
        _filteredServices = widget.viewModel.services
            .where((s) =>
                s.name.toLowerCase().contains(query) ||
                s.description.toLowerCase().contains(query))
            .toList();
      }
    });
  }

  void _filterSnapshotServices() {
    if (!mounted) return;
    final query = _snapshotSearchController.text.trim().toLowerCase();
    final connectionId = widget.viewModel.selectedConnectionId;
    if (connectionId == null) return;
    final list = _rawSnapshotData[connectionId] ?? [];
    setState(() {
      if (query.isEmpty) {
        _filteredSnapshotServices = List.from(list);
      } else {
        _filteredSnapshotServices = list
            .where((s) =>
                s.name.toLowerCase().contains(query) ||
                s.displayName.toLowerCase().contains(query))
            .toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final viewModel = widget.viewModel;
    final id = viewModel.selectedConnectionId;

    if (id != _lastSelectedConnectionId) {
      _lastSelectedConnectionId = id;
      _refreshServicesFuture();
      _isManageMode = _isManageModeAvailable;
    }

    if (id == null) {
      return Center(
        child: Text(_monitorText(
            widget.strings,
            'Please select a server on the left to view services.',
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
    if (viewModel.loadingServices) {
      return const Center(child: CircularProgressIndicator());
    }

    return RefreshIndicator(
      onRefresh: () => viewModel.fetchServices(id),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _serviceSearchController,
              decoration: InputDecoration(
                hintText: widget.strings.searchService,
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              ),
            ),
          ),
          Expanded(
            child: _filteredServices.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 100),
                      Center(child: Text('No services found.')),
                    ],
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: _filteredServices.length,
                    itemBuilder: (context, index) {
                      final service = _filteredServices[index];
                      return Card(
                        child: ListTile(
                          leading: Icon(
                            service.isRunning
                                ? Icons.play_circle
                                : Icons.stop_circle,
                            color: service.isRunning
                                ? widget.colorScheme.secondary
                                : widget.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.5),
                          ),
                          title: OverflowScrollText(
                            service.name,
                            selectable: false,
                            maxLines: 1,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: OverflowScrollText(
                            '${service.activeState} (${service.subState}) • ${service.description}',
                            selectable: false,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 12,
                              color: widget.colorScheme.onSurface
                                  .withValues(alpha: 0.58),
                            ),
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (action) =>
                                _manageService(service.name, action),
                            itemBuilder: (context) => [
                              PopupMenuItem(
                                  value: 'start',
                                  child: Text(widget.strings.serviceStart)),
                              PopupMenuItem(
                                  value: 'stop',
                                  child: Text(widget.strings.serviceStop)),
                              PopupMenuItem(
                                  value: 'restart',
                                  child: Text(widget.strings.serviceRestart)),
                              PopupMenuItem(
                                  value: 'enable',
                                  child: Text(widget.strings.serviceEnable)),
                              PopupMenuItem(
                                  value: 'disable',
                                  child: Text(widget.strings.serviceDisable)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSnapshotView(String id) {
    final currentConfigList = widget.viewModel.connections
        .where((c) => c.id == id)
        .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _snapshotSearchController,
            decoration: InputDecoration(
              hintText: widget.strings.searchService,
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            ),
          ),
        ),
        Expanded(
          child: _filteredSnapshotServices.isEmpty && _snapshotSearchController.text.isNotEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [
                    SizedBox(height: 100),
                    Center(child: Text('No matching services found.')),
                  ],
                )
              : _ServerSnapshotTab<ServiceStatusSnapshot>(
                  strings: widget.strings,
                  connections: currentConfigList,
                  emptyText: _monitorText(
                      widget.strings, 'No running services found', '未发现运行中的服务'),
                  future: _servicesFuture,
                  onRefresh: () => setState(() => _refreshServicesFuture(force: true)),
                  itemBuilder: (context, service) {
                    // Filter if query is present, since itemBuilder runs on individual items
                    final query = _snapshotSearchController.text.trim().toLowerCase();
                    if (query.isNotEmpty &&
                        !service.name.toLowerCase().contains(query) &&
                        !service.displayName.toLowerCase().contains(query)) {
                      return const SizedBox.shrink();
                    }
                    return _ServiceStatusTile(
                      strings: widget.strings,
                      service: service,
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _manageService(String name, String action) async {
    final language = context.read<AppSettings>().language;
    final strings = AppStrings(language);

    // Double confirmation for stopping or disabling service
    if (action == 'stop' || action == 'disable') {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(strings.actionConfirm),
          content: Text('Are you sure you want to $action service "$name"?'),
          actions: [
            TextButton(
              child: Text(strings.cancel),
              onPressed: () => Navigator.pop(context, false),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (confirm != true) return;
    }

    try {
      await widget.viewModel.manageSystemdService(name, action);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Action failed: $e')));
    }
  }
}
