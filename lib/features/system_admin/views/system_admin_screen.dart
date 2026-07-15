import 'dart:async';
import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/features/system_admin/viewmodels/system_admin_viewmodel.dart';
import 'package:ssh_mobile/features/performance/viewmodels/performance_viewmodel.dart';
import 'package:ssh_mobile/models/system_admin.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/server_status_probe.dart';
import 'package:ssh_mobile/utils/responsive.dart';
import 'package:ssh_mobile/widgets/tactile_feedback.dart';
import 'package:ssh_mobile/widgets/overflow_scroll_text.dart';
import 'package:ssh_mobile/widgets/app_surface.dart';
import 'package:ssh_mobile/widgets/system_power_confirm_flow.dart';
import 'package:ssh_mobile/widgets/ssh_host_key_trust_dialog.dart';
import 'package:ssh_mobile/widgets/server_selector.dart';
import 'package:ssh_mobile/theme/app_theme.dart';

part 'system_admin_server_pane.dart';
part 'users_tab.dart';
part 'sessions_tab.dart';
part 'services_tab.dart';
part 'ports_tab.dart';
part 'power_tab.dart';
part 'monitor_models.dart';
part 'performance_charts.dart';
part 'health_disk_views.dart';
part 'details_views.dart';
part 'monitor_config.dart';
part 'monitor_tab.dart';
part 'applications_tab.dart';

class SystemAdminScreen extends StatefulWidget {
  const SystemAdminScreen({super.key});

  @override
  State<SystemAdminScreen> createState() => _SystemAdminScreenState();
}

class _SystemAdminScreenState extends State<SystemAdminScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final ValueNotifier<int> _activeTabIndex = ValueNotifier<int>(0);
  int? _lastActivatedTabIndex;
  String? _lastActivatedConnectionId;
  String? _lastObservedSelectedConnectionId;
  List<ConnectionConfig>? _lastObservedConnections;
  bool _activationScheduled = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 7, vsync: this);
    _tabController.addListener(_handleTabSelection);
  }

  void _handleTabSelection() {
    if (!mounted) return;
    final index = _tabController.index;
    if (_activeTabIndex.value != index) {
      _activeTabIndex.value = index;
      context.read<SystemAdminViewModel>().cancelActiveCommands();
    }
    _scheduleCurrentTabActivation();
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabSelection);
    _tabController.dispose();
    _activeTabIndex.dispose();
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

    return Selector<SystemAdminViewModel, _SystemAdminShellSnapshot>(
      selector: (_, vm) => _SystemAdminShellSnapshot.from(vm),
      builder: (context, snapshot, _) {
        final viewModelRead = context.read<SystemAdminViewModel>();
        _maybeScheduleActivationForSelectionChange(viewModelRead);

        if (!snapshot.storageReady) {
          return const Center(
            child: SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }

        if (snapshot.connections.isEmpty) {
          return AppEmptyState(
            icon: Icons.monitor_heart_outlined,
            title: strings.systemOmAdmin,
            message: strings.selectServerToManage,
            action: FilledButton.icon(
              onPressed: () => Navigator.pushNamed(context, '/add'),
              icon: const Icon(Icons.add_rounded),
              label: Text(strings.addConnection),
            ),
          );
        }

        final desktop = isDesktopLayout(context);
        final colorScheme = Theme.of(context).colorScheme;

        final bodyContent = _buildMainContent(
          strings,
          colorScheme,
          _activeTabIndex,
        );

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: AppPageSurface(
            child: ValueListenableBuilder<int>(
              valueListenable: _activeTabIndex,
              builder: (context, activeIndex, _) {
                final isMonitorTab = activeIndex == 0;
                final textScale = MediaQuery.textScalerOf(
                  context,
                ).scale(1).clamp(1.0, 2.0).toDouble();
                final expandedMobileServerHeight =
                    72.0 + (textScale - 1.0) * 38.0;
                final collapsedMobileServerHeight =
                    48.0 + (textScale - 1.0) * 22.0;
                return desktop
                    ? Row(
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOutCubic,
                            width: snapshot.serversCollapsed ? 64 : 320,
                            child: snapshot.serversCollapsed
                                ? _AdminCollapsedDesktopServerRail(
                                    key: const ValueKey(
                                      'admin-server-rail-collapsed',
                                    ),
                                    strings: strings,
                                    isMonitorTab: isMonitorTab,
                                    onExpand: () => context
                                        .read<SystemAdminViewModel>()
                                        .setServersCollapsed(context, false),
                                  )
                                : _AdminServerPane(
                                    strings: strings,
                                    isMonitorTab: isMonitorTab,
                                    onCollapse: () => context
                                        .read<SystemAdminViewModel>()
                                        .setServersCollapsed(context, true),
                                  ),
                          ),
                          VerticalDivider(
                            width: 1,
                            thickness: 1,
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                          Expanded(child: bodyContent),
                        ],
                      )
                    : Column(
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOutCubic,
                            height: snapshot.serversCollapsed
                                ? collapsedMobileServerHeight
                                : expandedMobileServerHeight,
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 180),
                              switchInCurve: Curves.easeOutCubic,
                              switchOutCurve: Curves.easeInCubic,
                              layoutBuilder: (currentChild, _) =>
                                  currentChild ?? const SizedBox.shrink(),
                              child: snapshot.serversCollapsed
                                  ? _AdminCollapsedMobileServerBar(
                                      key: const ValueKey(
                                        'admin-server-collapsed',
                                      ),
                                      strings: strings,
                                      isMonitorTab: isMonitorTab,
                                      onExpand: () => context
                                          .read<SystemAdminViewModel>()
                                          .setServersCollapsed(context, false),
                                    )
                                  : _AdminMobileServerStrip(
                                      key: const ValueKey(
                                        'admin-server-expanded',
                                      ),
                                      strings: strings,
                                      isMonitorTab: isMonitorTab,
                                      onCollapse: () => context
                                          .read<SystemAdminViewModel>()
                                          .setServersCollapsed(context, true),
                                    ),
                            ),
                          ),
                          Divider(
                            height: 1,
                            thickness: 1,
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                          Expanded(child: bodyContent),
                        ],
                      );
              },
            ),
          ),
        );
      },
    );
  }

  void _maybeScheduleActivationForSelectionChange(
    SystemAdminViewModel viewModel,
  ) {
    final currentSelectedId = viewModel.selectedConnectionId;
    final currentConnections = viewModel.connections;

    final selectedIdChanged =
        _lastObservedSelectedConnectionId != currentSelectedId;
    final connectionsChanged = !identical(
      _lastObservedConnections,
      currentConnections,
    );

    if (!selectedIdChanged && !connectionsChanged) return;

    _lastObservedSelectedConnectionId = currentSelectedId;
    _lastObservedConnections = currentConnections;
    _lastActivatedConnectionId = null;

    _scheduleCurrentTabActivation(viewModel);
  }

  void _scheduleCurrentTabActivation([SystemAdminViewModel? viewModel]) {
    if (_activationScheduled) return;
    _activationScheduled = true;

    final activeViewModel =
        viewModel ?? (mounted ? context.read<SystemAdminViewModel>() : null);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _activationScheduled = false;
      if (!mounted || activeViewModel == null) return;

      activeViewModel.validateSelectedConnection();

      final selectedId = activeViewModel.selectedConnectionId;
      if (selectedId == null) return;

      final index = _tabController.index;
      final activationKeyChanged =
          _lastActivatedTabIndex != index ||
          _lastActivatedConnectionId != selectedId;

      if (!activationKeyChanged) return;

      _lastActivatedTabIndex = index;
      _lastActivatedConnectionId = selectedId;

      unawaited(_activateTab(index, activeViewModel));
    });
  }

  Future<void> _activateTab(int index, SystemAdminViewModel viewModel) async {
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
    AppStrings strings,
    ColorScheme colorScheme,
    ValueNotifier<int> activeTabIndex,
  ) {
    // TabController organizes all Admin tabs
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.surface.withValues(alpha: 0.74),
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) => true,
            child: TabBar(
              controller: _tabController,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelPadding: const EdgeInsets.symmetric(horizontal: 14),
              tabs: [
                Tab(
                  text: strings.monitor,
                  icon: const Icon(Icons.monitor_heart_outlined),
                ),
                Tab(text: strings.listeningPorts, icon: const Icon(Icons.lan)),
                Tab(
                  text: strings.applications,
                  icon: const Icon(Icons.apps_rounded),
                ),
                Tab(
                  text: strings.systemServices,
                  icon: const Icon(Icons.settings_suggest),
                ),
                Tab(text: strings.userAccounts, icon: const Icon(Icons.people)),
                Tab(
                  text: strings.activeSessions,
                  icon: const Icon(Icons.co_present),
                ),
                Tab(
                  text: strings.systemPower,
                  icon: const Icon(Icons.power_settings_new),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              // Tab 0: Monitor
              _MonitorTab(
                strings: strings,
                tabController: _tabController,
                onStartMonitoring: () async {
                  final monitorVm = context.read<PerformanceMonitorViewModel>();
                  await monitorVm.startMonitoring(
                    onUnknownHostKey: (request) =>
                        showSshHostKeyTrustDialog(context, request),
                  );
                  if (mounted && monitorVm.isRunning) {
                    context.read<SystemAdminViewModel>().setServersCollapsed(
                      context,
                      true,
                    );
                  }
                },
              ),
              // Tab 1: Ports (Manage/Snapshot)
              _PortsTab(
                strings: strings,
                colorScheme: colorScheme,
                viewModel: context.read<SystemAdminViewModel>(),
                activeTabIndex: activeTabIndex,
              ),
              // Tab 2: Applications (Snapshot only)
              _ApplicationsTab(
                strings: strings,
                colorScheme: colorScheme,
                viewModel: context.read<SystemAdminViewModel>(),
                monitorViewModel: context.read<PerformanceMonitorViewModel>(),
                activeTabIndex: activeTabIndex,
              ),
              // Tab 3: Services (Manage/Snapshot)
              _ServicesTab(
                strings: strings,
                colorScheme: colorScheme,
                viewModel: context.read<SystemAdminViewModel>(),
                activeTabIndex: activeTabIndex,
              ),
              // Tab 4: Users (Requires root connection)
              _RootRequiredTabWrapper(
                onConnected: (connectionId) => context
                    .read<SystemAdminViewModel>()
                    .fetchAccounts(connectionId, force: true),
                child: _UsersTab(
                  strings: strings,
                  colorScheme: colorScheme,
                  viewModel: context.read<SystemAdminViewModel>(),
                ),
              ),
              // Tab 5: Sessions (Requires root connection)
              _RootRequiredTabWrapper(
                onConnected: (connectionId) => context
                    .read<SystemAdminViewModel>()
                    .fetchSessions(connectionId, force: true),
                child: _SessionsTab(
                  strings: strings,
                  colorScheme: colorScheme,
                  viewModel: context.read<SystemAdminViewModel>(),
                ),
              ),
              // Tab 6: Power (Requires root connection)
              _RootRequiredTabWrapper(
                child: _PowerTab(
                  strings: strings,
                  colorScheme: colorScheme,
                  viewModel: context.read<SystemAdminViewModel>(),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RootRequiredTabWrapper extends StatelessWidget {
  final Widget child;
  final Future<void> Function(String connectionId)? onConnected;

  const _RootRequiredTabWrapper({required this.child, this.onConnected});

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AppStrings(language);
    final selectedConnectionId = context.select<SystemAdminViewModel, String?>(
      (vm) => vm.selectedConnectionId,
    );

    if (selectedConnectionId == null) {
      return _AdminEmptyState(strings: strings);
    }

    final selectedConnection = context
        .select<SystemAdminViewModel, ConnectionConfig?>(
          (vm) => vm.connectionById(selectedConnectionId),
        );
    if (selectedConnection == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        context.read<SystemAdminViewModel>().clearInvalidSelection();
      });
      return _AdminEmptyState(strings: strings);
    }

    if (selectedConnection.serverPlatform != ServerPlatform.linux) {
      return AppEmptyState(
        icon: Icons.desktop_windows_outlined,
        title: strings.nonLinuxMsg,
        message: strings.adminLinuxManagementHint,
      );
    }

    final isConnecting = context.select<SystemAdminViewModel, bool>(
      (vm) => vm.isConnectingSelectedConnection,
    );
    final isConnected = context.select<SystemAdminViewModel, bool>(
      (vm) => vm.isConnectedSelectedConnection,
    );
    final hasError = context.select<SystemAdminViewModel, bool>(
      (vm) => vm.hasManagementErrorForSelectedConnection,
    );
    final errorMessage = hasError
        ? context.select<SystemAdminViewModel, String?>((vm) => vm.errorMessage)
        : null;
    final isRoot =
        isConnected &&
        context.select<SystemAdminViewModel, bool>((vm) => vm.isRoot);

    if (isConnecting) {
      return Center(
        child: AppSectionCard(
          title: strings.adminRootAccess,
          subtitle: strings.verifyingPrivilege,
          icon: Icons.admin_panel_settings_outlined,
          padding: const EdgeInsets.all(22),
          child: const Center(
            child: SizedBox(
              width: 44,
              height: 44,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
          ),
        ),
      );
    }

    if (!isConnected || !isRoot || errorMessage != null) {
      return _RootRequiredView(
        strings: strings,
        errorMessage: errorMessage,
        onConnect: () =>
            unawaited(_connectAndLoad(context, selectedConnectionId)),
      );
    }

    return child;
  }

  Future<void> _connectAndLoad(
    BuildContext context,
    String connectionId,
  ) async {
    final viewModel = context.read<SystemAdminViewModel>();
    await viewModel.connectIfNeeded(
      connectionId,
      onUnknownHostKey: (request) =>
          showSshHostKeyTrustDialog(context, request),
    );
    if (!context.mounted || !viewModel.canManageSelectedConnection) return;
    await onConnected?.call(connectionId);
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
    final isPrivilegeError =
        errorMessage != null &&
        (errorMessage!.toLowerCase().contains('privilege') ||
            errorMessage!.toLowerCase().contains('root required') ||
            errorMessage!.toLowerCase().contains('insufficient'));

    return AppEmptyState(
      icon: isPrivilegeError || errorMessage == null
          ? Icons.gpp_bad_outlined
          : Icons.error_outline_rounded,
      title: isPrivilegeError || errorMessage == null
          ? strings.adminRootAccess
          : strings.adminConnectionFailed,
      message: errorMessage == null
          ? '${strings.rootRequiredMsg}\n${strings.reconnectAsRootMsg}'
          : '$errorMessage\n${strings.reconnectAsRootMsg}',
      action: onConnect == null
          ? null
          : FilledButton.icon(
              key: const ValueKey('system-admin-connect-root'),
              icon: const Icon(Icons.admin_panel_settings_rounded),
              label: Text(strings.adminConnectAsRoot),
              onPressed: onConnect,
            ),
    );
  }
}

class _AdminEmptyState extends StatelessWidget {
  final AppStrings strings;

  const _AdminEmptyState({required this.strings});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => AppEmptyState(
        icon: Icons.monitor_heart_outlined,
        title: strings.systemOmAdmin,
        message: strings.selectServerToManage,
        compact: constraints.maxWidth < 420,
      ),
    );
  }
}

class _MonitorResponsiveEmptyState extends StatelessWidget {
  final AppStrings strings;
  final String? message;

  const _MonitorResponsiveEmptyState({required this.strings, this.message});

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
                  AppIconBadge(
                    icon: Icons.monitor_heart_outlined,
                    size: compact ? 44 : 72,
                    iconSize: compact ? 24 : 34,
                  ),
                  SizedBox(height: compact ? 8 : 14),
                ],
                Text(
                  _monitorText(
                    strings,
                    'Select servers to monitor',
                    '选择要监控的服务器',
                  ),
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

class _SystemAdminShellSnapshot {
  final bool storageReady;
  final bool serversCollapsed;
  final String? selectedConnectionId;
  final List<ConnectionConfig> connections;

  const _SystemAdminShellSnapshot({
    required this.storageReady,
    required this.serversCollapsed,
    required this.selectedConnectionId,
    required this.connections,
  });

  factory _SystemAdminShellSnapshot.from(SystemAdminViewModel vm) {
    return _SystemAdminShellSnapshot(
      storageReady: vm.storageInitialized,
      serversCollapsed: vm.serversCollapsed,
      selectedConnectionId: vm.selectedConnectionId,
      connections: List.unmodifiable(vm.connections),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _SystemAdminShellSnapshot &&
        other.storageReady == storageReady &&
        other.serversCollapsed == serversCollapsed &&
        other.selectedConnectionId == selectedConnectionId &&
        listEquals(other.connections, connections);
  }

  @override
  int get hashCode => Object.hash(
    storageReady,
    serversCollapsed,
    selectedConnectionId,
    Object.hashAll(connections),
  );
}
