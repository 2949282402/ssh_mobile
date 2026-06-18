part of '../system_admin_screen.dart';

class _ServicesTab extends StatefulWidget {
  final AppStrings strings;
  final ColorScheme colorScheme;
  final SystemAdminViewModel viewModel;
  final bool active;

  const _ServicesTab({
    required this.strings,
    required this.colorScheme,
    required this.viewModel,
    required this.active,
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
  List<ServiceStatusSnapshot> _filteredSnapshotServices = [];
  Map<String, List<ServiceStatusSnapshot>> _rawSnapshotData = {};

  bool _isManageMode = false;
  Future<Map<String, List<ServiceStatusSnapshot>>>? _servicesFuture;
  String? _servicesSelectionKey;
  String? _lastSelectedConnectionId;
  String? _lastActivatedModeKey;
  bool _modeActivationScheduled = false;

  @override
  bool get wantKeepAlive => true;

  bool get _isLinux {
    final connectionId = widget.viewModel.selectedConnectionId;
    final config = widget.viewModel.connectionById(connectionId);
    return config?.serverPlatform == ServerPlatform.linux;
  }

  bool get _isManageModeAvailable {
    return widget.viewModel.canManageSelectedConnection && _isLinux;
  }

  void _refreshServicesFuture({bool force = false}) {
    final connectionId = widget.viewModel.selectedConnectionId;
    if (connectionId == null) {
      _servicesSelectionKey = null;
      _servicesFuture = null;
      return;
    }
    final monitorViewModel = context.read<PerformanceMonitorViewModel>();
    if (force ||
        _servicesFuture == null ||
        _servicesSelectionKey != connectionId) {
      _servicesSelectionKey = connectionId;
      _servicesFuture = _loadServices(monitorViewModel, connectionId);
    }
  }

  Future<Map<String, List<ServiceStatusSnapshot>>> _loadServices(
      PerformanceMonitorViewModel monitorViewModel, String connectionId) async {
    final list = await monitorViewModel.fetchServices(
      connectionId,
      onUnknownHostKey: (request) =>
          showSshHostKeyTrustDialog(context, request),
    );

    if (!mounted || widget.viewModel.selectedConnectionId != connectionId) {
      return {};
    }

    final result = {connectionId: list};
    setState(() {
      _rawSnapshotData = result;
      _applySnapshotFilterWithoutSetState();
    });
    return result;
  }

  @override
  void initState() {
    super.initState();
    _lastSelectedConnectionId = widget.viewModel.selectedConnectionId;
    _serviceSearchController.addListener(_filterServices);
    _snapshotSearchController.addListener(_filterSnapshotServices);
    _scheduleModeActivation();
  }

  @override
  void didUpdateWidget(covariant _ServicesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final id = widget.viewModel.selectedConnectionId;
    if (id != _lastSelectedConnectionId) {
      _lastSelectedConnectionId = id;
      _servicesSelectionKey = null;
      _servicesFuture = null;
      _rawSnapshotData = {};
      _filteredSnapshotServices = [];
      _lastActivatedModeKey = null;
      _isManageMode = false;
    }
    if (widget.active) {
      _scheduleModeActivation();
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
    setState(() {});
  }

  List<SystemdService> _visibleManageServices() {
    final query = _serviceSearchController.text.trim().toLowerCase();
    final services = widget.viewModel.services;

    if (query.isEmpty) {
      return services;
    }

    return services.where((service) {
      return service.name.toLowerCase().contains(query) ||
          service.description.toLowerCase().contains(query);
    }).toList();
  }

  void _filterSnapshotServices() {
    if (!mounted) return;
    setState(_applySnapshotFilterWithoutSetState);
  }

  void _applySnapshotFilterWithoutSetState() {
    final query = _snapshotSearchController.text.trim().toLowerCase();
    final connectionId = widget.viewModel.selectedConnectionId;
    if (connectionId == null) return;
    final list = _rawSnapshotData[connectionId] ?? [];
    if (query.isEmpty) {
      _filteredSnapshotServices = List.from(list);
    } else {
      _filteredSnapshotServices = list
          .where((s) =>
              s.name.toLowerCase().contains(query) ||
              s.displayName.toLowerCase().contains(query))
          .toList();
    }
  }

  void _scheduleModeActivation() {
    if (!widget.active || _modeActivationScheduled) return;
    final id = widget.viewModel.selectedConnectionId;
    if (id == null) return;

    final mode = _isManageMode && _isLinux ? 'manage' : 'snapshot';
    final modeKey = '$id:$mode';
    final snapshotReady = mode == 'snapshot' &&
        _servicesFuture != null &&
        _servicesSelectionKey == id;
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
    final snapshotReady = mode == 'snapshot' &&
        _servicesFuture != null &&
        _servicesSelectionKey == id;
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
        await widget.viewModel.fetchServices(id);
      }
      return;
    }

    setState(() {
      _refreshServicesFuture();
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
            targetEn: 'services',
            targetZh: '服务',
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

    if (viewModel.loadingServices) {
      return const Center(child: CircularProgressIndicator());
    }

    final visibleServices = _visibleManageServices();

    return RefreshIndicator(
      onRefresh: () => viewModel.fetchServices(id, force: true),
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
            child: visibleServices.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 100),
                      Center(child: Text('No services found.')),
                    ],
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: visibleServices.length,
                    itemBuilder: (context, index) {
                      final service = visibleServices[index];
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
    final currentConfigList =
        widget.viewModel.connections.where((c) => c.id == id).toList();

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
          child: _filteredSnapshotServices.isEmpty &&
                  _snapshotSearchController.text.isNotEmpty
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
                  onRefresh: () =>
                      setState(() => _refreshServicesFuture(force: true)),
                  itemBuilder: (context, service) {
                    // Filter if query is present, since itemBuilder runs on individual items
                    final query =
                        _snapshotSearchController.text.trim().toLowerCase();
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
