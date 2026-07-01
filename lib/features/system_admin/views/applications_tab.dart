part of 'system_admin_screen.dart';

class _ApplicationsTab extends StatefulWidget {
  final AppStrings strings;
  final ColorScheme colorScheme;
  final SystemAdminViewModel viewModel;
  final PerformanceMonitorViewModel monitorViewModel;
  final ValueNotifier<int> activeTabIndex;

  const _ApplicationsTab({
    required this.strings,
    required this.colorScheme,
    required this.viewModel,
    required this.monitorViewModel,
    required this.activeTabIndex,
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
  bool _appsLoadScheduled = false;

  bool get _isActive => widget.activeTabIndex.value == 2;

  void _refreshApplicationsFuture({bool force = false}) {
    final connectionId = widget.viewModel.selectedConnectionId;
    if (connectionId == null) {
      _appsSelectionKey = null;
      _appsFuture = null;
      return;
    }
    if (force || _appsFuture == null || _appsSelectionKey != connectionId) {
      _appsSelectionKey = connectionId;
      _appsFuture = Future.delayed(const Duration(milliseconds: 300)).then((_) {
        if (!mounted || !_isActive)
          return <String, List<ApplicationMemorySnapshot>>{};
        return _loadApplications(connectionId);
      });
    }
  }

  Future<Map<String, List<ApplicationMemorySnapshot>>> _loadApplications(
      String connectionId) async {
    final data = await widget.monitorViewModel.fetchApplications(
      connectionId,
      onUnknownHostKey: (request) =>
          showSshHostKeyTrustDialog(context, request),
    );

    if (!mounted || widget.viewModel.selectedConnectionId != connectionId) {
      return {};
    }

    return {connectionId: data};
  }

  void _scheduleApplicationsLoad({bool force = false}) {
    if (!_isActive || _appsLoadScheduled) return;
    final connectionId = widget.viewModel.selectedConnectionId;
    if (connectionId == null) return;
    if (!force && _appsFuture != null && _appsSelectionKey == connectionId) {
      return;
    }

    _appsLoadScheduled = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _appsLoadScheduled = false;
      if (!mounted || !_isActive) return;
      final currentConnectionId = widget.viewModel.selectedConnectionId;
      if (currentConnectionId == null) return;
      if (!force &&
          _appsFuture != null &&
          _appsSelectionKey == currentConnectionId) {
        return;
      }

      setState(() {
        _refreshApplicationsFuture(force: force);
      });
    });
  }

  @override
  void didUpdateWidget(covariant _ApplicationsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final connectionId = widget.viewModel.selectedConnectionId;
    if (connectionId != _lastSelectedConnectionId) {
      _lastSelectedConnectionId = connectionId;
      _appsSelectionKey = null;
      _appsFuture = null;
    }
    if (_isActive && (connectionId != null)) {
      _scheduleApplicationsLoad();
    }
  }

  @override
  void initState() {
    super.initState();
    _lastSelectedConnectionId = widget.viewModel.selectedConnectionId;
    widget.activeTabIndex.addListener(_onTabChanged);
    _scheduleApplicationsLoad();
  }

  @override
  void dispose() {
    widget.activeTabIndex.removeListener(_onTabChanged);
    super.dispose();
  }

  void _onTabChanged() {
    if (!mounted) return;
    if (_isActive) {
      _scheduleApplicationsLoad();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final connectionId = context.select<SystemAdminViewModel, String?>(
      (vm) => vm.selectedConnectionId,
    );

    if (connectionId == null) {
      return Center(
        child: Text(
          _selectServerHint(
            context,
            widget.strings.language,
            targetEn: 'applications',
            targetZh: '应用',
          ),
        ),
      );
    }

    if (_isActive) {
      _scheduleApplicationsLoad();
    }

    final connections =
        context.select<SystemAdminViewModel, List<ConnectionConfig>>(
      (vm) => vm.connections,
    );
    final currentConfigList =
        connections.where((c) => c.id == connectionId).toList();

    return _ServerSnapshotTab<ApplicationMemorySnapshot>(
      strings: widget.strings,
      connections: currentConfigList,
      emptyText:
          _monitorText(widget.strings, 'No application data found', '未发现应用数据'),
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
