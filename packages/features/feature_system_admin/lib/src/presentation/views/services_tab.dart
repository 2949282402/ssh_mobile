// System Admin Services Tab：展示和管理 systemd 服务状态。

part of 'system_admin_screen.dart';

class _ServicesManageSnapshot {
  final bool isConnecting;
  final bool isManageModeAvailable;
  final String? errorMessage;
  final bool loadingServices;
  final List<SystemdService> services;

  const _ServicesManageSnapshot({
    required this.isConnecting,
    required this.isManageModeAvailable,
    required this.errorMessage,
    required this.loadingServices,
    required this.services,
  });

  factory _ServicesManageSnapshot.from(SystemAdminViewModel vm) {
    return _ServicesManageSnapshot(
      isConnecting: vm.isConnectingSelectedConnection,
      isManageModeAvailable: vm.canManageSelectedConnection,
      errorMessage: vm.hasManagementErrorForSelectedConnection
          ? vm.errorMessage
          : null,
      loadingServices: vm.loadingServices,
      services: vm.services,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _ServicesManageSnapshot &&
        other.isConnecting == isConnecting &&
        other.isManageModeAvailable == isManageModeAvailable &&
        other.errorMessage == errorMessage &&
        other.loadingServices == loadingServices &&
        listEquals(other.services, services);
  }

  @override
  int get hashCode => Object.hash(
    isConnecting,
    isManageModeAvailable,
    errorMessage,
    loadingServices,
    Object.hashAll(services),
  );
}

class _ServicesTab extends StatefulWidget {
  final AppStrings strings;
  final ColorScheme colorScheme;
  final SystemAdminViewModel viewModel;
  final ValueNotifier<int> activeTabIndex;

  const _ServicesTab({
    super.key,
    required this.strings,
    required this.colorScheme,
    required this.viewModel,
    required this.activeTabIndex,
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
  Map<String, List<ServiceStatusSnapshot>> _rawSnapshotData = {};

  bool _isManageMode = false;
  Future<Map<String, List<ServiceStatusSnapshot>>>? _servicesFuture;
  String? _servicesSelectionKey;
  String? _lastSelectedConnectionId;
  String? _lastActivatedModeKey;
  bool _modeActivationScheduled = false;

  Timer? _serviceSearchDebounce;
  List<SystemdService> _visibleManageServicesCache = [];
  String? _lastManageFilterKey;

  bool get _isActive => widget.activeTabIndex.value == 3;

  void refresh() {
    final id = widget.viewModel.selectedConnectionId;
    if (id == null) return;
    if (_isManageMode && _isLinux) {
      unawaited(widget.viewModel.fetchServices(id, force: true));
    } else {
      setState(() => _refreshServicesFuture(force: true));
    }
  }

  @override
  bool get wantKeepAlive => true;

  bool get _isLinux {
    final connectionId = widget.viewModel.selectedConnectionId;
    final config = widget.viewModel.connectionById(connectionId);
    return config?.serverPlatform == ServerPlatform.linux;
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
    PerformanceMonitorViewModel monitorViewModel,
    String connectionId,
  ) async {
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
    });
    return result;
  }

  @override
  void initState() {
    super.initState();
    _lastSelectedConnectionId = widget.viewModel.selectedConnectionId;
    _serviceSearchController.addListener(_filterServices);
    _snapshotSearchController.addListener(_filterSnapshotServices);
    widget.activeTabIndex.addListener(_onTabChanged);
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
      _lastActivatedModeKey = null;
      _isManageMode = false;
    }
    if (_isActive) {
      _scheduleModeActivation();
    }
  }

  @override
  void dispose() {
    _serviceSearchController.dispose();
    _snapshotSearchController.dispose();
    _serviceSearchDebounce?.cancel();
    widget.activeTabIndex.removeListener(_onTabChanged);
    super.dispose();
  }

  void _onTabChanged() {
    if (!mounted) return;
    if (_isActive) {
      _scheduleModeActivation();
    }
  }

  void _filterServices() {
    _serviceSearchDebounce?.cancel();
    _serviceSearchDebounce = Timer(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      setState(() {
        _lastManageFilterKey = null;
      });
    });
  }

  void _rebuildVisibleManageServicesCache(List<SystemdService> services) {
    final query = _serviceSearchController.text.trim().toLowerCase();
    final connectionId = widget.viewModel.selectedConnectionId;
    final servicesHash = Object.hashAll(
      services.map(
        (s) => Object.hash(
          s.name,
          s.loadState,
          s.activeState,
          s.subState,
          s.description,
        ),
      ),
    );
    final key = '$connectionId|$query|$servicesHash';

    if (_lastManageFilterKey == key) return;
    _lastManageFilterKey = key;

    if (query.isEmpty) {
      _visibleManageServicesCache = services;
    } else {
      _visibleManageServicesCache = services.where((service) {
        return service.name.toLowerCase().contains(query) ||
            service.description.toLowerCase().contains(query);
      }).toList();
    }
  }

  List<SystemdService> _visibleManageServices(List<SystemdService> services) {
    _rebuildVisibleManageServicesCache(services);
    return _visibleManageServicesCache;
  }

  void _filterSnapshotServices() {
    if (!mounted) return;
    setState(() {});
  }

  void _scheduleModeActivation() {
    if (!_isActive || _modeActivationScheduled) return;
    final id = widget.viewModel.selectedConnectionId;
    if (id == null) return;

    final mode = _isManageMode && _isLinux ? 'manage' : 'snapshot';
    final modeKey = '$id:$mode';
    final snapshotReady =
        mode == 'snapshot' &&
        _servicesFuture != null &&
        _servicesSelectionKey == id;
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
        mode == 'snapshot' &&
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

  Map<String, List<ServiceStatusSnapshot>> get _filteredSnapshotData {
    final connectionId = widget.viewModel.selectedConnectionId;
    if (connectionId == null) return {};
    final list = _rawSnapshotData[connectionId] ?? [];
    final query = _snapshotSearchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      return {connectionId: list};
    }
    final filtered = list
        .where(
          (s) =>
              s.name.toLowerCase().contains(query) ||
              s.displayName.toLowerCase().contains(query),
        )
        .toList();
    return {connectionId: filtered};
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
            targetEn: 'services',
            targetZh: '服务',
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
    return Selector<SystemAdminViewModel, _ServicesManageSnapshot>(
      selector: (_, vm) => _ServicesManageSnapshot.from(vm),
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

        if (snapshot.loadingServices) {
          return const Center(child: CircularProgressIndicator());
        }

        final visibleServices = _visibleManageServices(snapshot.services);

        return RefreshIndicator(
          onRefresh: () => widget.viewModel.fetchServices(id, force: true),
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
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: _AdminListSurface(
                          child: ListView.separated(
                            itemCount: visibleServices.length,
                            separatorBuilder: (_, _) => Divider(
                              height: 1,
                              thickness: 1,
                              color: widget.colorScheme.outlineVariant
                                  .withValues(alpha: 0.5),
                            ),
                            itemBuilder: (context, index) {
                              final service = visibleServices[index];
                              return ListTile(
                                leading: Icon(
                                  service.isRunning
                                      ? Icons.play_circle_filled_rounded
                                      : Icons.stop_circle_outlined,
                                  size: 20,
                                  color: service.isRunning
                                      ? AppStatusColors.of(context).success
                                      : AppStatusColors.of(
                                          context,
                                        ).neutral.withValues(alpha: 0.5),
                                ),
                                title: OverflowScrollText(
                                  service.name,
                                  selectable: false,
                                  maxLines: 1,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
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
                                      child: Text(widget.strings.serviceStart),
                                    ),
                                    PopupMenuItem(
                                      value: 'stop',
                                      child: Text(widget.strings.serviceStop),
                                    ),
                                    PopupMenuItem(
                                      value: 'restart',
                                      child: Text(
                                        widget.strings.serviceRestart,
                                      ),
                                    ),
                                    PopupMenuItem(
                                      value: 'enable',
                                      child: Text(widget.strings.serviceEnable),
                                    ),
                                    PopupMenuItem(
                                      value: 'disable',
                                      child: Text(
                                        widget.strings.serviceDisable,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSnapshotView(String id) {
    final currentConfigList = widget.viewModel.connections
        .where((c) => c.id == id)
        .toList();
    final snapshotData = _filteredSnapshotData;

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
          child:
              snapshotData.values.expand((e) => e).isEmpty &&
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
                    widget.strings,
                    'No running services found',
                    '未发现运行中的服务',
                  ),
                  future: _servicesFuture,
                  showRefresh: false,
                  dataOverride: _rawSnapshotData.isEmpty ? null : snapshotData,
                  onRefresh: () =>
                      setState(() => _refreshServicesFuture(force: true)),
                  itemBuilder: (context, service) {
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
    final strings = context.read<AppSettings>().strings;

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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Action failed: $e')));
    }
  }
}
