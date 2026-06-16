import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/connection/models/connection.dart';
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
  static const _serversCollapsedStorageKey = 'system_admin_servers_collapsed';

  bool _serversCollapsed = false;
  bool _restoredServersCollapsed = false;

  SystemAdminService? _adminService;
  String? _lastConnectedId;

  // Active user accounts
  List<LinuxUserAccount> _accounts = [];
  bool _loadingAccounts = false;

  // Active tty sessions
  List<ActiveSession> _sessions = [];
  bool _loadingSessions = false;

  // Systemd services
  List<SystemdService> _services = [];
  bool _loadingServices = false;

  // Listening ports
  List<ListeningPort> _ports = [];
  bool _loadingPorts = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _adminService = context.read<SystemAdminService>();
      _adminService!.addListener(_onAdminServiceChanged);
      if (_adminService!.isConnected) {
        _lastConnectedId = _adminService!.connectionId;
        _refreshAllData();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restoredServersCollapsed) return;
    _restoredServersCollapsed = true;
    final stored = PageStorage.maybeOf(context)?.readState(
      context,
      identifier: _serversCollapsedStorageKey,
    );
    if (stored is bool) _serversCollapsed = stored;
  }

  @override
  void dispose() {
    _adminService?.removeListener(_onAdminServiceChanged);
    super.dispose();
  }

  void _collapseServers() {
    _setServersCollapsed(true);
  }

  void _expandServers() {
    _setServersCollapsed(false);
  }

  void _setServersCollapsed(bool collapsed) {
    if (_serversCollapsed == collapsed) return;
    setState(() => _serversCollapsed = collapsed);
    PageStorage.maybeOf(context)?.writeState(
      context,
      collapsed,
      identifier: _serversCollapsedStorageKey,
    );
  }

  void _onAdminServiceChanged() {
    if (!mounted) return;
    final service = _adminService;
    if (service == null) return;

    if (service.isConnected) {
      if (_lastConnectedId != service.connectionId) {
        _lastConnectedId = service.connectionId;
        _refreshAllData();
      }
    } else {
      _lastConnectedId = null;
      setState(() {
        _accounts.clear();
        _sessions.clear();
        _services.clear();
        _ports.clear();
      });
    }
  }

  Future<void> _refreshAllData() async {
    final id = _adminService?.connectionId;
    if (id == null) return;
    _fetchAccounts(id);
    _fetchSessions(id);
    _fetchServices(id);
    _fetchPorts(id);
  }

  Future<void> _fetchAccounts(String connectionId) async {
    setState(() => _loadingAccounts = true);
    final adminService = context.read<SystemAdminService>();
    final accounts = await adminService.getUserAccounts(connectionId);
    if (!mounted) return;
    setState(() {
      _accounts = accounts;
      _loadingAccounts = false;
    });
  }

  Future<void> _fetchSessions(String connectionId) async {
    setState(() => _loadingSessions = true);
    final adminService = context.read<SystemAdminService>();
    final sessions = await adminService.getActiveSessions(connectionId);
    if (!mounted) return;
    setState(() {
      _sessions = sessions;
      _loadingSessions = false;
    });
  }

  Future<void> _fetchServices(String connectionId) async {
    setState(() => _loadingServices = true);
    final adminService = context.read<SystemAdminService>();
    final services = await adminService.getSystemdServices(connectionId);
    if (!mounted) return;
    setState(() {
      _services = services;
      _loadingServices = false;
    });
  }

  Future<void> _fetchPorts(String connectionId) async {
    setState(() => _loadingPorts = true);
    final adminService = context.read<SystemAdminService>();
    final ports = await adminService.getListeningPorts(connectionId);
    if (!mounted) return;
    setState(() {
      _ports = ports;
      _loadingPorts = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AppStrings(language);
    final storageReady = context.select<StorageService, bool>(
      (storage) => storage.initialized,
    );
    final connections = context.select<StorageService, List<ConnectionConfig>>(
      (storage) => storage.connections,
    );

    final selectedConnectionId = context.select<SystemAdminService, String?>(
      (service) => service.connectionId,
    );
    final isConnecting = context.select<SystemAdminService, bool>(
      (service) => service.isConnecting,
    );
    final isConnected = context.select<SystemAdminService, bool>(
      (service) => service.isConnected,
    );
    final errorMessage = context.select<SystemAdminService, String?>(
      (service) => service.errorMessage,
    );
    final isRoot = context.select<SystemAdminService, bool>(
      (service) => service.isRoot,
    );

    final desktop = isDesktopLayout(context);
    final colorScheme = Theme.of(context).colorScheme;

    final selectedConnection =
        _selectedConnection(connections, selectedConnectionId);
    final serversCollapsed = _serversCollapsed && connections.isNotEmpty;

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
              onPressed: _refreshAllData,
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
                          onExpand: _expandServers,
                        )
                      : _AdminServerPane(
                          connections: connections,
                          strings: strings,
                          onCollapse: _collapseServers,
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
                          onExpand: _expandServers,
                        )
                      : _AdminMobileServerStrip(
                          key: const ValueKey('admin-server-expanded'),
                          connections: connections,
                          strings: strings,
                          onCollapse: _collapseServers,
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
                  connectionId: selectedConnectionId,
                  accounts: _accounts,
                  isLoading: _loadingAccounts,
                  onRefresh: () => _fetchAccounts(selectedConnectionId),
                ),
                _SessionsTab(
                  strings: strings,
                  colorScheme: colorScheme,
                  connectionId: selectedConnectionId,
                  sessions: _sessions,
                  isLoading: _loadingSessions,
                  onRefresh: () => _fetchSessions(selectedConnectionId),
                ),
                _ServicesTab(
                  strings: strings,
                  colorScheme: colorScheme,
                  connectionId: selectedConnectionId,
                  services: _services,
                  isLoading: _loadingServices,
                  onRefresh: () => _fetchServices(selectedConnectionId),
                ),
                _PortsTab(
                  strings: strings,
                  colorScheme: colorScheme,
                  connectionId: selectedConnectionId,
                  ports: _ports,
                  isLoading: _loadingPorts,
                  onRefresh: () => _fetchPorts(selectedConnectionId),
                ),
                _PowerTab(
                  strings: strings,
                  colorScheme: colorScheme,
                  connectionId: selectedConnectionId,
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
