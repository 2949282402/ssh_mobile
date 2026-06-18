import 'dart:async';
import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/connection/models/connection.dart';
import '../features/system_admin/viewmodels/system_admin_viewmodel.dart';
import '../features/performance/viewmodels/performance_viewmodel.dart';
import '../models/system_admin.dart';
import '../services/app_settings.dart';
import '../services/sftp_service.dart';
import '../services/storage_service.dart';
import '../services/performance_monitor_service.dart';
import '../services/server_status_probe.dart';
import '../utils/responsive.dart';
import '../widgets/tactile_feedback.dart';
import '../widgets/overflow_scroll_text.dart';
import '../widgets/system_power_confirm_flow.dart';
import '../widgets/ssh_host_key_trust_dialog.dart';

part 'system_admin/system_admin_server_pane.dart';
part 'system_admin/users_tab.dart';
part 'system_admin/sessions_tab.dart';
part 'system_admin/services_tab.dart';
part 'system_admin/ports_tab.dart';
part 'system_admin/power_tab.dart';
part 'system_admin/monitor_models.dart';
part 'system_admin/performance_charts.dart';
part 'system_admin/health_disk_views.dart';
part 'system_admin/details_views.dart';
part 'system_admin/monitor_config.dart';
part 'system_admin/monitor_tab.dart';
part 'system_admin/applications_tab.dart';

class SystemAdminScreen extends StatefulWidget {
  const SystemAdminScreen({super.key});

  @override
  State<SystemAdminScreen> createState() => _SystemAdminScreenState();
}

class _SystemAdminScreenState extends State<SystemAdminScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  int? _lastActivatedTabIndex;
  String? _lastActivatedConnectionId;
  String? _lastObservedSelectedConnectionId;
  bool _activationScheduled = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 7, vsync: this);
    _tabController.addListener(_handleTabSelection);
  }

  void _handleTabSelection() {
    if (!mounted) return;
    setState(() {});
    _scheduleCurrentTabActivation();
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabSelection);
    _tabController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    context.read<SystemAdminViewModel>().restoreServersCollapsed(context);
    _scheduleCurrentTabActivation();
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AppStrings(language);
    final viewModel = context.watch<SystemAdminViewModel>();
    final monitorVm = context.watch<PerformanceMonitorViewModel>();
    final storageReady = viewModel.storageInitialized;
    final connections = viewModel.connections;

    final selectedConnectionId = viewModel.selectedConnectionId;
    final isConnecting = viewModel.isConnecting;
    final isConnected = viewModel.isConnected;
    final errorMessage = viewModel.errorMessage;

    final desktop = isDesktopLayout(context);
    final colorScheme = Theme.of(context).colorScheme;

    final isMonitorTab = _tabController.index == 0;

    _maybeScheduleActivationForSelectionChange(viewModel);

    final selectedConnection = viewModel.connectionById(selectedConnectionId);
    final selectedMonitorConnections = connections
        .where((c) => monitorVm.selectedConnectionIds.contains(c.id))
        .toList();
    final serversCollapsed = viewModel.serversCollapsed;

    if (!storageReady) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    final bodyContent = _buildMainContent(
      viewModel,
      monitorVm,
      strings,
      colorScheme,
      desktop,
      selectedConnectionId,
      isConnecting,
      isConnected,
      errorMessage,
      connections,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.systemAdmin),
        actions: [
          if (!isMonitorTab && viewModel.canManageSelectedConnection)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: viewModel.refreshAllData,
              tooltip: strings.refreshAll,
            ),
        ],
      ),
      body: desktop
          ? Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  width: serversCollapsed ? 64 : 320,
                  child: serversCollapsed
                      ? _AdminCollapsedDesktopServerRail(
                          key: ValueKey(isMonitorTab
                              ? 'admin-monitor-server-rail-collapsed'
                              : 'admin-server-rail-collapsed'),
                          selectedConnection: selectedConnection,
                          connections: selectedMonitorConnections,
                          busy: isMonitorTab
                              ? (monitorVm.isSampling && monitorVm.isRunning)
                              : (isConnecting &&
                                  viewModel.managementConnectionId ==
                                      selectedConnectionId),
                          connected: isMonitorTab
                              ? monitorVm.isRunning
                              : (isConnected &&
                                  viewModel.managementConnectionId ==
                                      selectedConnectionId),
                          strings: strings,
                          isMonitorTab: isMonitorTab,
                          onExpand: () =>
                              viewModel.setServersCollapsed(context, false),
                        )
                      : _AdminServerPane(
                          viewModel: viewModel,
                          connections: connections,
                          strings: strings,
                          isMonitorTab: isMonitorTab,
                          onCollapse: () =>
                              viewModel.setServersCollapsed(context, true),
                        ),
                ),
                VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                Expanded(
                  child: bodyContent,
                ),
              ],
            )
          : Column(
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: serversCollapsed
                      ? _AdminCollapsedMobileServerBar(
                          key: ValueKey(isMonitorTab
                              ? 'admin-monitor-server-collapsed'
                              : 'admin-server-collapsed'),
                          selectedConnection: selectedConnection,
                          connections: selectedMonitorConnections,
                          busy: isMonitorTab
                              ? (monitorVm.isSampling && monitorVm.isRunning)
                              : (isConnecting &&
                                  viewModel.managementConnectionId ==
                                      selectedConnectionId),
                          connected: isMonitorTab
                              ? monitorVm.isRunning
                              : (isConnected &&
                                  viewModel.managementConnectionId ==
                                      selectedConnectionId),
                          strings: strings,
                          isMonitorTab: isMonitorTab,
                          onExpand: () =>
                              viewModel.setServersCollapsed(context, false),
                        )
                      : _AdminMobileServerStrip(
                          key: ValueKey(isMonitorTab
                              ? 'admin-monitor-server-expanded'
                              : 'admin-server-expanded'),
                          viewModel: viewModel,
                          connections: connections,
                          strings: strings,
                          isMonitorTab: isMonitorTab,
                          onCollapse: () =>
                              viewModel.setServersCollapsed(context, true),
                        ),
                ),
                Divider(
                  height: 1,
                  thickness: 1,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                Expanded(
                  child: bodyContent,
                ),
              ],
            ),
    );
  }

  void _maybeScheduleActivationForSelectionChange(
    SystemAdminViewModel viewModel,
  ) {
    final currentSelectedId = viewModel.selectedConnectionId;
    if (_lastObservedSelectedConnectionId == currentSelectedId) return;

    _lastObservedSelectedConnectionId = currentSelectedId;
    _lastActivatedConnectionId = null;

    _scheduleCurrentTabActivation();
  }

  void _scheduleCurrentTabActivation() {
    if (_activationScheduled) return;
    _activationScheduled = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _activationScheduled = false;
      if (!mounted) return;

      final viewModel = context.read<SystemAdminViewModel>();
      viewModel.validateSelectedConnection();

      final selectedId = viewModel.selectedConnectionId;
      if (selectedId == null) return;

      final index = _tabController.index;
      final activationKeyChanged = _lastActivatedTabIndex != index ||
          _lastActivatedConnectionId != selectedId;

      if (!activationKeyChanged) return;

      _lastActivatedTabIndex = index;
      _lastActivatedConnectionId = selectedId;

      unawaited(_activateTab(index, viewModel));
    });
  }

  Future<void> _activateTab(
    int index,
    SystemAdminViewModel viewModel,
  ) async {
    final selectedId = viewModel.selectedConnectionId;
    if (selectedId == null) return;

    final config = viewModel.connectionById(selectedId);
    if (config == null) {
      viewModel.clearInvalidSelection();
      return;
    }

    final isLinux = config.serverPlatform == ServerPlatform.linux;

    switch (index) {
      case 0:
      case 1:
      case 2:
      case 3:
        return;
      case 4:
        if (!isLinux) return;
        await viewModel.connectIfNeeded(
          selectedId,
          onUnknownHostKey: (request) =>
              showSshHostKeyTrustDialog(context, request),
        );
        if (!mounted) return;
        if (viewModel.canManageSelectedConnection) {
          await viewModel.fetchAccounts(selectedId);
        }
        return;
      case 5:
        if (!isLinux) return;
        await viewModel.connectIfNeeded(
          selectedId,
          onUnknownHostKey: (request) =>
              showSshHostKeyTrustDialog(context, request),
        );
        if (!mounted) return;
        if (viewModel.canManageSelectedConnection) {
          await viewModel.fetchSessions(selectedId);
        }
        return;
      case 6:
        if (!isLinux) return;
        await viewModel.connectIfNeeded(
          selectedId,
          onUnknownHostKey: (request) =>
              showSshHostKeyTrustDialog(context, request),
        );
        return;
    }
  }

  Widget _buildMainContent(
    SystemAdminViewModel viewModel,
    PerformanceMonitorViewModel monitorVm,
    AppStrings strings,
    ColorScheme colorScheme,
    bool desktop,
    String? selectedConnectionId,
    bool isConnecting,
    bool isConnected,
    String? errorMessage,
    List<ConnectionConfig> connections,
  ) {
    // TabController organizes all Admin tabs
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(
                text: strings.monitor,
                icon: const Icon(Icons.monitor_heart_outlined)),
            Tab(text: strings.listeningPorts, icon: const Icon(Icons.lan)),
            Tab(
                text: strings.applications,
                icon: const Icon(Icons.apps_rounded)),
            Tab(
                text: strings.systemServices,
                icon: const Icon(Icons.settings_suggest)),
            Tab(text: strings.userAccounts, icon: const Icon(Icons.people)),
            Tab(
                text: strings.activeSessions,
                icon: const Icon(Icons.co_present)),
            Tab(
                text: strings.systemPower,
                icon: const Icon(Icons.power_settings_new)),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              // Tab 0: Monitor
              _MonitorTab(
                strings: strings,
                monitor: monitorVm,
                connections: connections,
                onStartMonitoring: () async {
                  await monitorVm.startMonitoring(
                    onUnknownHostKey: (request) =>
                        showSshHostKeyTrustDialog(context, request),
                  );
                  if (mounted) {
                    viewModel.setServersCollapsed(context, true);
                  }
                },
              ),
              // Tab 1: Ports (Manage/Snapshot)
              _PortsTab(
                strings: strings,
                colorScheme: colorScheme,
                viewModel: viewModel,
                active: _tabController.index == 1,
              ),
              // Tab 2: Applications (Snapshot only)
              _ApplicationsTab(
                strings: strings,
                colorScheme: colorScheme,
                viewModel: viewModel,
                monitorViewModel: monitorVm,
                active: _tabController.index == 2,
              ),
              // Tab 3: Services (Manage/Snapshot)
              _ServicesTab(
                strings: strings,
                colorScheme: colorScheme,
                viewModel: viewModel,
                active: _tabController.index == 3,
              ),
              // Tab 4: Users (Requires root connection)
              _buildRootRequiredTab(
                viewModel,
                strings,
                colorScheme,
                _UsersTab(
                  strings: strings,
                  colorScheme: colorScheme,
                  viewModel: viewModel,
                ),
              ),
              // Tab 5: Sessions (Requires root connection)
              _buildRootRequiredTab(
                viewModel,
                strings,
                colorScheme,
                _SessionsTab(
                  strings: strings,
                  colorScheme: colorScheme,
                  viewModel: viewModel,
                ),
              ),
              // Tab 6: Power (Requires root connection)
              _buildRootRequiredTab(
                viewModel,
                strings,
                colorScheme,
                _PowerTab(
                  strings: strings,
                  colorScheme: colorScheme,
                  viewModel: viewModel,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRootRequiredTab(
    SystemAdminViewModel viewModel,
    AppStrings strings,
    ColorScheme colorScheme,
    Widget child,
  ) {
    final selectedConnectionId = viewModel.selectedConnectionId;

    if (selectedConnectionId == null) {
      return _AdminEmptyState(strings: strings);
    }

    final selectedConnection = viewModel.connectionById(selectedConnectionId);
    if (selectedConnection == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.read<SystemAdminViewModel>().clearInvalidSelection();
      });
      return _AdminEmptyState(strings: strings);
    }

    if (selectedConnection.serverPlatform != ServerPlatform.linux) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.gpp_bad, size: 80, color: colorScheme.error),
              const SizedBox(height: 16),
              Text(
                strings.nonLinuxMsg,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      );
    }

    final isConnecting = viewModel.isConnectingSelectedConnection;
    final isConnected = viewModel.isConnectedSelectedConnection;
    final errorMessage = viewModel.hasManagementErrorForSelectedConnection
        ? viewModel.errorMessage
        : null;
    final isRoot = isConnected && viewModel.isRoot;

    if (isConnecting) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              strings.verifyingPrivilege,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    if (!isConnected || !isRoot || errorMessage != null) {
      return _RootRequiredView(
        strings: strings,
        errorMessage: errorMessage,
        onConnect: () => unawaited(
          viewModel.connectIfNeeded(
            selectedConnectionId,
            onUnknownHostKey: (request) =>
                showSshHostKeyTrustDialog(context, request),
          ),
        ),
      );
    }

    return child;
  }
}

class _RootRequiredView extends StatelessWidget {
  final AppStrings strings;
  final String? errorMessage;
  final VoidCallback? onConnect;

  const _RootRequiredView({
    required this.strings,
    this.errorMessage,
    this.onConnect,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isPrivilegeError = errorMessage != null &&
        (errorMessage!.toLowerCase().contains('privilege') ||
            errorMessage!.toLowerCase().contains('root required') ||
            errorMessage!.toLowerCase().contains('insufficient'));

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isPrivilegeError || errorMessage == null
                  ? Icons.gpp_bad
                  : Icons.error_outline_rounded,
              size: 80,
              color: colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              isPrivilegeError || errorMessage == null
                  ? strings.rootRequiredMsg
                  : 'Connection Failed',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            if (errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              strings.reconnectAsRootMsg,
              textAlign: TextAlign.center,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            if (onConnect != null) ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                icon: const Icon(Icons.admin_panel_settings_rounded),
                label: Text(strings.language == AppLanguage.en
                    ? 'Connect as Root'
                    : '以 Root 连接'),
                onPressed: onConnect,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AdminEmptyState extends StatelessWidget {
  final AppStrings strings;

  const _AdminEmptyState({required this.strings});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: colorScheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: colorScheme.primary.withValues(alpha: 0.18),
                ),
              ),
              child: Icon(
                Icons.admin_panel_settings_outlined,
                color: colorScheme.primary,
                size: 36,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              strings.systemOmAdmin,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              strings.selectServerToManage,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MonitorResponsiveEmptyState extends StatelessWidget {
  final AppStrings strings;
  final String? message;

  const _MonitorResponsiveEmptyState({
    required this.strings,
    this.message,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 180;
        final showIcon = constraints.maxHeight >= 150;
        return Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(compact ? 12 : 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showIcon) ...[
                  Container(
                    width: compact ? 44 : 72,
                    height: compact ? 44 : 72,
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: colorScheme.primary.withValues(alpha: 0.18),
                      ),
                    ),
                    child: Icon(
                      Icons.monitor_heart_outlined,
                      color: colorScheme.primary,
                      size: compact ? 24 : 34,
                    ),
                  ),
                  SizedBox(height: compact ? 8 : 14),
                ],
                Text(
                  _monitorText(
                      strings, 'Select servers to monitor', '选择要监控的服务器'),
                  textAlign: TextAlign.center,
                  maxLines: compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w800,
                    fontSize: compact ? 14 : 16,
                  ),
                ),
                SizedBox(height: compact ? 4 : 6),
                Text(
                  message ??
                      _monitorText(
                        strings,
                        'Select one or more servers, then start monitoring. Sampling stays silent until started.',
                        '可多选服务器，点击开始监控后才采样；未开始前保持静默。',
                      ),
                  textAlign: TextAlign.center,
                  maxLines: compact ? 2 : null,
                  overflow: compact ? TextOverflow.ellipsis : null,
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: compact ? 12 : 13,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// Helpers
String _serverSummary(AppStrings strings, List<ConnectionConfig> connections) {
  if (connections.isEmpty) {
    return _monitorText(strings, 'Monitor servers', '监控服务器');
  }
  if (connections.length == 1) {
    final connection = connections.first;
    return '${connection.name}  ${connection.username}@${connection.host}';
  }
  return _monitorText(
    strings,
    '${connections.length} selected',
    '已选择 ${connections.length} 台',
  );
}

String _monitorText(AppStrings strings, String en, String zh) {
  return strings.language == AppLanguage.en ? en : zh;
}

String _selectServerHint(
  BuildContext context,
  AppLanguage language, {
  required String targetEn,
  required String targetZh,
}) {
  final desktop = isDesktopLayout(context);
  final isEnglish = language == AppLanguage.en;

  if (isEnglish) {
    return desktop
        ? 'Please select a server on the left to view $targetEn.'
        : 'Please select a server above to view $targetEn.';
  }

  return desktop ? '请先在左侧选择要查看的$targetZh。' : '请先在上方选择要查看的$targetZh。';
}

String _durationLabel(Duration duration) {
  if (duration.inMinutes >= 1 && duration.inSeconds % 60 == 0) {
    return '${duration.inMinutes}m';
  }
  return '${duration.inSeconds}s';
}

String _runDurationLabel(DateTime? startedAt) {
  if (startedAt == null) return '0s';
  final duration = DateTime.now().difference(startedAt);
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  if (hours > 0) return '${hours}h ${minutes}m';
  if (minutes > 0) return '${minutes}m ${seconds}s';
  return '${seconds}s';
}

Color _healthColor(BuildContext context, ServerHealthLevel level) {
  final colorScheme = Theme.of(context).colorScheme;
  return switch (level) {
    ServerHealthLevel.healthy => colorScheme.secondary,
    ServerHealthLevel.warning => Colors.orangeAccent.shade700,
    ServerHealthLevel.critical => colorScheme.error,
    ServerHealthLevel.unknown => colorScheme.onSurfaceVariant,
  };
}

IconData _healthIcon(ServerHealthLevel level) {
  return switch (level) {
    ServerHealthLevel.healthy => Icons.verified_rounded,
    ServerHealthLevel.warning => Icons.warning_amber_rounded,
    ServerHealthLevel.critical => Icons.error_rounded,
    ServerHealthLevel.unknown => Icons.help_outline_rounded,
  };
}

String _healthLabel(AppStrings strings, ServerHealthLevel level) {
  final en = strings.language == AppLanguage.en;
  return switch (level) {
    ServerHealthLevel.healthy => en ? 'Healthy' : '正常',
    ServerHealthLevel.warning => en ? 'Warning' : '警告',
    ServerHealthLevel.critical => en ? 'Critical' : '危险',
    ServerHealthLevel.unknown => en ? 'No samples' : '暂无采样',
  };
}

Color _monitorSeriesColor(int index) {
  const palette = [
    Colors.blue,
    Colors.teal,
    Colors.deepOrange,
    Colors.indigo,
    Colors.pink,
    Colors.green,
    Colors.cyan,
    Colors.brown,
  ];
  return palette[index % palette.length];
}
