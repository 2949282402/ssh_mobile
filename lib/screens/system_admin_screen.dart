import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/connection/models/connection.dart';
import '../features/system_admin/viewmodels/system_admin_viewmodel.dart';
import '../models/system_admin.dart';
import '../services/app_settings.dart';
import '../services/sftp_service.dart';
import '../services/storage_service.dart';
import '../services/system_admin_service.dart';
import '../utils/responsive.dart';
import '../widgets/tactile_feedback.dart';
import '../widgets/overflow_scroll_text.dart';

part 'system_admin/system_admin_server_pane.dart';
part 'system_admin/users_tab.dart';
part 'system_admin/sessions_tab.dart';
part 'system_admin/services_tab.dart';
part 'system_admin/ports_tab.dart';
part 'system_admin/power_tab.dart';

class SystemAdminScreen extends StatefulWidget {
  const SystemAdminScreen({super.key});

  @override
  State<SystemAdminScreen> createState() => _SystemAdminScreenState();
}

class _SystemAdminScreenState extends State<SystemAdminScreen> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    context.read<SystemAdminViewModel>().restoreServersCollapsed(context);
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AppStrings(language);
    final viewModel = context.watch<SystemAdminViewModel>();
    final storageReady = viewModel.storageInitialized;
    final connections = viewModel.connections;

    final selectedConnectionId = viewModel.connectionId;
    final isConnecting = viewModel.isConnecting;
    final isConnected = viewModel.isConnected;
    final errorMessage = viewModel.errorMessage;
    final isRoot = viewModel.isRoot;

    final desktop = isDesktopLayout(context);
    final colorScheme = Theme.of(context).colorScheme;

    final selectedConnection =
        _selectedConnection(connections, selectedConnectionId);
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
      strings,
      colorScheme,
      desktop,
      selectedConnectionId,
      isConnecting,
      isConnected,
      errorMessage,
      isRoot,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.systemAdmin),
        actions: [
          if (selectedConnectionId != null && isConnected && isRoot)
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
                          key: const ValueKey('admin-server-rail-collapsed'),
                          selectedConnection: selectedConnection,
                          busy: isConnecting,
                          connected: isConnected,
                          strings: strings,
                          onExpand: () => viewModel.setServersCollapsed(context, false),
                        )
                      : _AdminServerPane(
                          viewModel: viewModel,
                          connections: connections,
                          strings: strings,
                          onCollapse: () => viewModel.setServersCollapsed(context, true),
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
                          key: const ValueKey('admin-server-collapsed'),
                          selectedConnection: selectedConnection,
                          busy: isConnecting,
                          connected: isConnected,
                          strings: strings,
                          onExpand: () => viewModel.setServersCollapsed(context, false),
                        )
                      : _AdminMobileServerStrip(
                          key: const ValueKey('admin-server-expanded'),
                          viewModel: viewModel,
                          connections: connections,
                          strings: strings,
                          onCollapse: () => viewModel.setServersCollapsed(context, true),
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

  ConnectionConfig? _selectedConnection(
    List<ConnectionConfig> connections,
    String? activeConnectionId,
  ) {
    if (activeConnectionId == null) return null;
    for (final connection in connections) {
      if (connection.id == activeConnectionId) return connection;
    }
    return null;
  }

  Widget _buildMainContent(
    SystemAdminViewModel viewModel,
    AppStrings strings,
    ColorScheme colorScheme,
    bool desktop,
    String? selectedConnectionId,
    bool isConnecting,
    bool isConnected,
    String? errorMessage,
    bool isRoot,
  ) {
    if (selectedConnectionId == null) {
      return _AdminEmptyState(strings: strings);
    }

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

    if (errorMessage != null) {
      final isPrivilegeError =
          errorMessage.toLowerCase().contains('privilege') ||
              errorMessage.toLowerCase().contains('root required') ||
              errorMessage.toLowerCase().contains('insufficient');

      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isPrivilegeError ? Icons.gpp_bad : Icons.error_outline_rounded,
                size: 80,
                color: colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                isPrivilegeError
                    ? strings.rootRequiredMsg
                    : 'Connection Failed',
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                errorMessage,
                textAlign: TextAlign.center,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
              if (isPrivilegeError) ...[
                const SizedBox(height: 16),
                Text(
                  strings.reconnectAsRootMsg,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      );
    }

    if (!isConnected) {
      return _AdminEmptyState(strings: strings);
    }

    if (!isRoot) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.gpp_bad, size: 80, color: colorScheme.error),
              const SizedBox(height: 16),
              Text(
                strings.rootRequiredMsg,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                strings.reconnectAsRootMsg,
                textAlign: TextAlign.center,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    // DefaultTabController organizes all Admin tabs
    return DefaultTabController(
      length: 5,
      child: Column(
        children: [
          TabBar(
            isScrollable: !desktop,
            tabAlignment: !desktop ? TabAlignment.center : TabAlignment.fill,
            tabs: [
              Tab(text: strings.userAccounts, icon: const Icon(Icons.people)),
              Tab(
                  text: strings.activeSessions,
                  icon: const Icon(Icons.co_present)),
              Tab(
                  text: strings.systemServices,
                  icon: const Icon(Icons.settings_suggest)),
              Tab(text: strings.listeningPorts, icon: const Icon(Icons.lan)),
              Tab(
                  text: strings.systemPower,
                  icon: const Icon(Icons.power_settings_new)),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _UsersTab(
                  strings: strings,
                  colorScheme: colorScheme,
                  viewModel: viewModel,
                ),
                _SessionsTab(
                  strings: strings,
                  colorScheme: colorScheme,
                  viewModel: viewModel,
                ),
                _ServicesTab(
                  strings: strings,
                  colorScheme: colorScheme,
                  viewModel: viewModel,
                ),
                _PortsTab(
                  strings: strings,
                  colorScheme: colorScheme,
                  viewModel: viewModel,
                ),
                _PowerTab(
                  strings: strings,
                  colorScheme: colorScheme,
                  viewModel: viewModel,
                ),
              ],
            ),
          ),
        ],
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
