import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/connection.dart';
import '../models/system_admin.dart';
import '../services/app_settings.dart';
import '../services/sftp_service.dart';
import '../services/storage_service.dart';
import '../services/system_admin_service.dart';
import '../utils/responsive.dart';
import '../widgets/tactile_feedback.dart';
import '../widgets/overflow_scroll_text.dart';

part 'system_admin/system_admin_server_pane.dart';

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
  List<SystemdService> _filteredServices = [];
  bool _loadingServices = false;
  final TextEditingController _serviceSearchController =
      TextEditingController();

  // Listening ports
  List<ListeningPort> _ports = [];
  bool _loadingPorts = false;

  @override
  void initState() {
    super.initState();
    _serviceSearchController.addListener(_filterServices);
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
    _serviceSearchController.dispose();
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
        _filteredServices.clear();
        _ports.clear();
      });
    }
  }

  void _filterServices() {
    final query = _serviceSearchController.text.trim().toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredServices = List.from(_services);
      } else {
        _filteredServices = _services
            .where((s) =>
                s.name.toLowerCase().contains(query) ||
                s.description.toLowerCase().contains(query))
            .toList();
      }
    });
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
      _filterServices();
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

    final adminService = context.watch<SystemAdminService>();
    final selectedConnectionId = adminService.connectionId;
    final isConnecting = adminService.isConnecting;
    final isConnected = adminService.isConnected;
    final errorMessage = adminService.errorMessage;
    final isRoot = adminService.isRoot;

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
              tooltip: strings.switchToChinese == '中文' ? 'Refresh All' : '刷新全部',
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
              strings.switchToChinese == '中文'
                  ? 'Connecting and verifying privilege level...'
                  : '正在连接并验证权限级别...',
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
                  strings.switchToChinese == '中文'
                      ? 'Please reconnect as "root" user or with administrative authorization.'
                      : '请以 root 账户重新连接，或确保连接的账户拥有完整的管理员权限。',
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
                strings.switchToChinese == '中文'
                    ? 'Please reconnect as "root" user or with administrative authorization.'
                    : '请以 root 账户重新连接，或确保连接的账户拥有完整的管理员权限。',
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
                _buildUsersTab(strings, colorScheme, selectedConnectionId),
                _buildSessionsTab(strings, colorScheme, selectedConnectionId),
                _buildServicesTab(strings, colorScheme, selectedConnectionId),
                _buildPortsTab(strings, colorScheme, selectedConnectionId),
                _buildPowerTab(strings, colorScheme, selectedConnectionId),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- Users Tab Implementation ---
  Widget _buildUsersTab(
      AppStrings strings, ColorScheme colorScheme, String connectionId) {
    if (_loadingAccounts) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                strings.switchToChinese == '中文' ? 'Local Accounts' : '本地账号列表',
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.person_add),
                label: Text(strings.createUser),
                onPressed: () => _openCreateUserDialog(strings, connectionId),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _fetchAccounts(connectionId),
            child: _accounts.isEmpty
                ? const Center(child: Text('No accounts found.'))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: _accounts.length,
                    itemBuilder: (context, index) {
                      final account = _accounts[index];
                      return Card(
                        child: ExpansionTile(
                          leading: CircleAvatar(
                            backgroundColor: account.uid == 0
                                ? colorScheme.errorContainer
                                : colorScheme.primaryContainer,
                            child: Icon(
                              account.uid == 0 ? Icons.security : Icons.person,
                              color: account.uid == 0
                                  ? colorScheme.onErrorContainer
                                  : colorScheme.onPrimaryContainer,
                            ),
                          ),
                          title: Row(
                            children: [
                              Text(account.username,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold)),
                              const SizedBox(width: 8),
                              Text('(${account.uid}/${account.gid})',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: colorScheme.onSurfaceVariant)),
                              const Spacer(),
                              if (account.isLocked)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: colorScheme.error
                                        .withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    strings.lockUser,
                                    style: TextStyle(
                                        color: colorScheme.error,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold),
                                  ),
                                )
                              else
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: colorScheme.primary
                                        .withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    strings.unlockUser,
                                    style: TextStyle(
                                        color: colorScheme.primary,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                            ],
                          ),
                          subtitle: OverflowScrollText(
                            '${account.homeDir}  •  ${account.shell}',
                            selectable: false,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 12,
                              color:
                                  colorScheme.onSurface.withValues(alpha: 0.58),
                            ),
                          ),
                          children: [
                            _UserDetailActions(
                              connectionId: connectionId,
                              account: account,
                              strings: strings,
                              colorScheme: colorScheme,
                              onStatusChanged: () =>
                                  _fetchAccounts(connectionId),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  // --- Sessions Tab Implementation ---
  Widget _buildSessionsTab(
      AppStrings strings, ColorScheme colorScheme, String connectionId) {
    if (_loadingSessions) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_sessions.isEmpty) {
      return const Center(child: Text('No active sessions.'));
    }

    return RefreshIndicator(
      onRefresh: () => _fetchSessions(connectionId),
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _sessions.length,
        itemBuilder: (context, index) {
          final s = _sessions[index];
          return Card(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.computer)),
              title: Row(
                children: [
                  Text(s.username,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(width: 12),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(s.tty,
                        style: TextStyle(
                            color: colorScheme.onSecondaryContainer,
                            fontSize: 11)),
                  ),
                ],
              ),
              subtitle: OverflowScrollText(
                '${s.loginTime} ${s.ipAddress.isNotEmpty ? '(${s.ipAddress})' : ''}',
                selectable: false,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurface.withValues(alpha: 0.58),
                ),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.login_outlined),
                color: colorScheme.error,
                tooltip:
                    strings.switchToChinese == '中文' ? 'Kill Session' : '断开会话',
                onPressed: () => _confirmKillSession(s, connectionId),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmKillSession(
      ActiveSession session, String connectionId) async {
    final language = context.read<AppSettings>().language;
    final strings = AppStrings(language);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.actionConfirm),
        content: Text(
          strings.switchToChinese == '中文'
              ? 'Kill the active session of user "${session.username}" on TTY "${session.tty}"?'
              : '确定要强行断开用户 "${session.username}" 在终端 "${session.tty}" 的会话吗？',
        ),
        actions: [
          TextButton(
            child: Text(strings.cancel),
            onPressed: () => Navigator.pop(context, false),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.switchToChinese == '中文' ? 'Kill' : '断开'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (confirm == true) {
      try {
        await context
            .read<SystemAdminService>()
            .killActiveSession(connectionId, session.tty);
        if (!mounted) return;
        _fetchSessions(connectionId);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  // --- Services Tab Implementation ---
  Widget _buildServicesTab(
      AppStrings strings, ColorScheme colorScheme, String connectionId) {
    if (_loadingServices) {
      return const Center(child: CircularProgressIndicator());
    }

    return RefreshIndicator(
      onRefresh: () => _fetchServices(connectionId),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _serviceSearchController,
              decoration: InputDecoration(
                hintText: strings.switchToChinese == '中文'
                    ? 'Search services...'
                    : '搜索服务...',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _filteredServices.length,
              itemBuilder: (context, index) {
                final service = _filteredServices[index];
                return Card(
                  child: ListTile(
                    leading: Icon(
                      service.isRunning ? Icons.play_circle : Icons.stop_circle,
                      color: service.isRunning
                          ? colorScheme.secondary
                          : colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
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
                        color: colorScheme.onSurface.withValues(alpha: 0.58),
                      ),
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (action) =>
                          _manageService(service.name, action, connectionId),
                      itemBuilder: (context) => [
                        PopupMenuItem(
                            value: 'start', child: Text(strings.serviceStart)),
                        PopupMenuItem(
                            value: 'stop', child: Text(strings.serviceStop)),
                        PopupMenuItem(
                            value: 'restart',
                            child: Text(strings.serviceRestart)),
                        PopupMenuItem(
                            value: 'enable',
                            child: Text(strings.serviceEnable)),
                        PopupMenuItem(
                            value: 'disable',
                            child: Text(strings.serviceDisable)),
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

  Future<void> _manageService(
      String name, String action, String connectionId) async {
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
      await context
          .read<SystemAdminService>()
          .manageSystemdService(connectionId, name, action);
      if (!mounted) return;
      _fetchServices(connectionId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Action failed: $e')));
    }
  }

  // --- Ports Tab Implementation ---
  Widget _buildPortsTab(
      AppStrings strings, ColorScheme colorScheme, String connectionId) {
    if (_loadingPorts) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_ports.isEmpty) {
      return const Center(child: Text('No listening ports found.'));
    }

    return RefreshIndicator(
      onRefresh: () => _fetchPorts(connectionId),
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _ports.length,
        itemBuilder: (context, index) {
          final p = _ports[index];
          return Card(
            child: ListTile(
              leading: Icon(
                p.protocol.contains('udp')
                    ? Icons.radio_button_checked
                    : Icons.swap_horizontal_circle,
                color: colorScheme.secondary,
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
                          color: colorScheme.surfaceContainerHighest,
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
                  color: colorScheme.onSurface.withValues(alpha: 0.58),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // --- Power Tab Implementation ---
  Widget _buildPowerTab(
      AppStrings strings, ColorScheme colorScheme, String connectionId) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.power_settings_new, size: 96, color: colorScheme.error),
            const SizedBox(height: 24),
            Text(
              strings.systemPower,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              strings.switchToChinese == '中文'
                  ? 'Reboot or power down the remote server. Authenticated as root.'
                  : '远程服务器系统控制，将直接向系统发送硬件关机或重启指令。',
              textAlign: TextAlign.center,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 36),
            SizedBox(
              width: 250,
              child: FilledButton.icon(
                icon: const Icon(Icons.cached),
                label: Text(strings.rebootServer),
                style: FilledButton.styleFrom(
                  backgroundColor: colorScheme.tertiary,
                  padding: const EdgeInsets.all(16),
                ),
                onPressed: () => _confirmPowerAction('reboot', connectionId),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: 250,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.power_off),
                label: Text(strings.shutdownServer),
                style: OutlinedButton.styleFrom(
                  foregroundColor: colorScheme.error,
                  side: BorderSide(color: colorScheme.error),
                  padding: const EdgeInsets.all(16),
                ),
                onPressed: () => _confirmPowerAction('shutdown', connectionId),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmPowerAction(String action, String connectionId) async {
    final colorScheme = Theme.of(context).colorScheme;
    final language = context.read<AppSettings>().language;
    final strings = AppStrings(language);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
            action == 'reboot' ? strings.rebootServer : strings.shutdownServer),
        content: Text(strings.powerConfirmContent),
        actions: [
          TextButton(
            child: Text(strings.cancel),
            onPressed: () => Navigator.pop(context, false),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.switchToChinese == '中文' ? 'Confirm' : '确定'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (confirm == true) {
      try {
        final adminService = context.read<SystemAdminService>();
        if (action == 'reboot') {
          await adminService.rebootServer(connectionId);
        } else {
          await adminService.shutdownServer(connectionId);
        }
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Command executed. Disconnecting...')),
        );
        adminService.disconnect();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to execute power action: $e')),
        );
      }
    }
  }

  void _openCreateUserDialog(AppStrings strings, String connectionId) {
    showDialog(
      context: context,
      builder: (context) => _CreateUserDialog(
        connectionId: connectionId,
        strings: strings,
        onCreated: () => _fetchAccounts(connectionId),
      ),
    );
  }
}

class _UserDetailActions extends StatefulWidget {
  final String connectionId;
  final LinuxUserAccount account;
  final AppStrings strings;
  final ColorScheme colorScheme;
  final VoidCallback onStatusChanged;

  const _UserDetailActions({
    required this.connectionId,
    required this.account,
    required this.strings,
    required this.colorScheme,
    required this.onStatusChanged,
  });

  @override
  State<_UserDetailActions> createState() => _UserDetailActionsState();
}

class _UserDetailActionsState extends State<_UserDetailActions> {
  String _storageUsed = 'Loading...';
  bool _isAdmin = false;
  bool _loadingSudo = true;

  @override
  void initState() {
    super.initState();
    _loadStorageInfo();
    _loadSudoInfo();
  }

  Future<void> _loadStorageInfo() async {
    final adminService = context.read<SystemAdminService>();
    final size = await adminService.getUserHomeStorageUsage(
        widget.connectionId, widget.account.homeDir);
    if (!mounted) return;
    setState(() {
      _storageUsed = size;
    });
  }

  Future<void> _loadSudoInfo() async {
    final adminService = context.read<SystemAdminService>();
    final isAdmin = await adminService.checkUserSudo(
        widget.connectionId, widget.account.username);
    if (!mounted) return;
    setState(() {
      _isAdmin = isAdmin;
      _loadingSudo = false;
    });
  }

  Future<void> _toggleSudoPrivilege() async {
    setState(() => _loadingSudo = true);
    try {
      final admin = context.read<SystemAdminService>();
      await admin.setUserSudo(
          widget.connectionId, widget.account.username, !_isAdmin);
      await _loadSudoInfo();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingSudo = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('${widget.strings.storageUsed}: ',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(_storageUsed),
              const SizedBox(width: 24),
              Text('${widget.strings.sudoStatus}: ',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              _loadingSudo
                  ? const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5))
                  : Text(_isAdmin
                      ? widget.strings.administrator
                      : widget.strings.normalUser),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                icon: Icon(
                    widget.account.isLocked ? Icons.lock_open : Icons.lock),
                label: Text(widget.account.isLocked
                    ? widget.strings.unlockUser
                    : widget.strings.lockUser),
                onPressed: _toggleUserLock,
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.password),
                label: Text(widget.strings.changePassword),
                onPressed: _openPasswordDialog,
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.folder_shared),
                label: Text(widget.strings.viewHomeDir),
                onPressed: _openHomeExplorer,
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.donut_large),
                label: Text(widget.strings.usageStats),
                onPressed: _openProcessesDialog,
              ),
              if (!_loadingSudo)
                ElevatedButton.icon(
                  icon: Icon(_isAdmin ? Icons.gpp_bad : Icons.verified_user),
                  label: Text(_isAdmin
                      ? widget.strings.revokeSudo
                      : widget.strings.grantSudo),
                  onPressed: _toggleSudoPrivilege,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _toggleUserLock() async {
    try {
      final admin = context.read<SystemAdminService>();
      if (widget.account.isLocked) {
        await admin.unlockUser(widget.connectionId, widget.account.username);
      } else {
        await admin.lockUser(widget.connectionId, widget.account.username);
      }
      widget.onStatusChanged();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  void _openPasswordDialog() {
    showDialog(
      context: context,
      builder: (context) => _ChangePasswordDialog(
        connectionId: widget.connectionId,
        username: widget.account.username,
        strings: widget.strings,
      ),
    );
  }

  void _openHomeExplorer() {
    showDialog(
      context: context,
      builder: (context) => _HomeDirectoryExplorerDialog(
        connectionId: widget.connectionId,
        homeDir: widget.account.homeDir,
        strings: widget.strings,
      ),
    );
  }

  void _openProcessesDialog() {
    showDialog(
      context: context,
      builder: (context) => _UserProcessesDialog(
        connectionId: widget.connectionId,
        username: widget.account.username,
        strings: widget.strings,
      ),
    );
  }
}

// --- Change Password Dialog ---
class _ChangePasswordDialog extends StatefulWidget {
  final String connectionId;
  final String username;
  final AppStrings strings;

  const _ChangePasswordDialog({
    required this.connectionId,
    required this.username,
    required this.strings,
  });

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _controller = TextEditingController();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.strings.changePasswordTitle} (${widget.username})'),
      content: TextField(
        controller: _controller,
        obscureText: true,
        decoration: InputDecoration(
          labelText: widget.strings.enterNewPassword,
          border: const OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          child: Text(widget.strings.cancel),
          onPressed: () => Navigator.pop(context),
        ),
        FilledButton(
          onPressed: _busy ? null : _savePassword,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(widget.strings.save),
        ),
      ],
    );
  }

  Future<void> _savePassword() async {
    final newPwd = _controller.text.trim();
    if (newPwd.isEmpty) return;

    setState(() => _busy = true);
    try {
      await context.read<SystemAdminService>().changePassword(
            widget.connectionId,
            widget.username,
            newPwd,
          );
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.strings.passwordChangedSuccess)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e')),
      );
    }
  }
}

// --- Home Directory Explorer Dialog ---
class _HomeDirectoryExplorerDialog extends StatefulWidget {
  final String connectionId;
  final String homeDir;
  final AppStrings strings;

  const _HomeDirectoryExplorerDialog({
    required this.connectionId,
    required this.homeDir,
    required this.strings,
  });

  @override
  State<_HomeDirectoryExplorerDialog> createState() =>
      _HomeDirectoryExplorerDialogState();
}

class _HomeDirectoryExplorerDialogState
    extends State<_HomeDirectoryExplorerDialog> {
  late String _currentPath;
  List<SftpEntry> _entries = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _currentPath = widget.homeDir;
    _loadDirectory(_currentPath);
  }

  Future<void> _loadDirectory(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final sftpService = context.read<SftpService>();
      final items = await sftpService.listDirectoryForConnection(
          widget.connectionId, path);
      if (!mounted) return;
      setState(() {
        _currentPath = path;
        _entries = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.strings.viewHomeDir),
          const SizedBox(height: 4),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              _currentPath,
              style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.normal),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: _buildContent(),
      ),
      actions: [
        if (_currentPath != widget.homeDir)
          TextButton(
            child: Text(widget.strings.switchToChinese == '中文'
                ? 'Back to Home'
                : '返回主目录'),
            onPressed: () => _loadDirectory(widget.homeDir),
          ),
        TextButton(
          child: Text(widget.strings.close),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }

  Widget _buildContent() {
    final colorScheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, color: colorScheme.error, size: 48),
            const SizedBox(height: 12),
            Text('Error listing files:\n$_error', textAlign: TextAlign.center),
          ],
        ),
      );
    }

    if (_entries.isEmpty) {
      return const Center(child: Text('This directory is empty.'));
    }

    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        final isSelf = entry.name == '.';
        if (isSelf) return const SizedBox.shrink();

        return ListTile(
          dense: true,
          leading: Icon(
            entry.isDirectory ? Icons.folder : Icons.insert_drive_file,
            color: entry.isDirectory ? Colors.amber : colorScheme.primary,
          ),
          title: Text(entry.name,
              style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: entry.isDirectory ? null : Text(entry.sizeLabel),
          onTap: () {
            if (entry.isDirectory) {
              _loadDirectory(entry.path);
            } else {
              _viewFileDetail(entry);
            }
          },
        );
      },
    );
  }

  void _viewFileDetail(SftpEntry entry) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(entry.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Size: ${entry.sizeLabel}'),
            if (entry.modifiedLabel != null)
              Text('Last Modified: ${entry.modifiedLabel}'),
            const SizedBox(height: 16),
            const Text(
              'Files can be full-edited, downloaded, or renamed from the SFTP tab.',
              style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
            ),
          ],
        ),
        actions: [
          TextButton(
            child: Text(widget.strings.close),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }
}

// --- User Processes and Resource Usage Dialog ---
class _UserProcessesDialog extends StatefulWidget {
  final String connectionId;
  final String username;
  final AppStrings strings;

  const _UserProcessesDialog({
    required this.connectionId,
    required this.username,
    required this.strings,
  });

  @override
  State<_UserProcessesDialog> createState() => _UserProcessesDialogState();
}

class _UserProcessesDialogState extends State<_UserProcessesDialog> {
  List<LinuxUserProcess> _processes = [];
  bool _loading = false;
  double _totalMemoryMB = 0;

  @override
  void initState() {
    super.initState();
    _loadProcesses();
  }

  Future<void> _loadProcesses() async {
    setState(() => _loading = true);
    final admin = context.read<SystemAdminService>();
    final list = await admin.getUserProcessesAndMemory(
        widget.connectionId, widget.username);

    // Sum memory
    int totalBytes = 0;
    for (final p in list) {
      totalBytes += p.rssBytes;
    }

    if (!mounted) return;
    setState(() {
      _processes = list;
      _totalMemoryMB = totalBytes / (1024 * 1024);
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Text('${widget.strings.usageStats} (${widget.username})'),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${widget.strings.memoryUsed}:',
                          style: TextStyle(
                              color: colorScheme.onSecondaryContainer,
                              fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '${_totalMemoryMB.toStringAsFixed(2)} MB',
                          style: TextStyle(
                            color: colorScheme.onSecondaryContainer,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${widget.strings.activeProcesses} (${_processes.length}):',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: _processes.isEmpty
                        ? const Center(child: Text('No active processes.'))
                        : ListView.builder(
                            itemCount: _processes.length,
                            itemBuilder: (context, index) {
                              final p = _processes[index];
                              final memMB = p.rssBytes / (1024 * 1024);
                              return Card(
                                child: ListTile(
                                  dense: true,
                                  title: OverflowScrollText(
                                    p.command,
                                    selectable: false,
                                    maxLines: 1,
                                    style: const TextStyle(
                                        fontFamily: 'monospace', fontSize: 12),
                                  ),
                                  subtitle: Text(
                                      'PID: ${p.pid}  •  CPU: ${p.cpuPercent}%  •  RAM: ${p.memPercent}%'),
                                  trailing:
                                      Text('${memMB.toStringAsFixed(1)} M'),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _loadProcesses,
        ),
        TextButton(
          child: Text(widget.strings.close),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }
}

class _CreateUserDialog extends StatefulWidget {
  final String connectionId;
  final AppStrings strings;
  final VoidCallback onCreated;

  const _CreateUserDialog({
    required this.connectionId,
    required this.strings,
    required this.onCreated,
  });

  @override
  State<_CreateUserDialog> createState() => _CreateUserDialogState();
}

class _CreateUserDialogState extends State<_CreateUserDialog> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _shellController = TextEditingController(text: '/bin/bash');
  bool _busy = false;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _shellController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.strings.createUser),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: 'Username',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: InputDecoration(
                labelText: widget.strings.enterNewPassword,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _shellController,
              decoration: InputDecoration(
                labelText: widget.strings.loginShell,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          child: Text(widget.strings.cancel),
          onPressed: () => Navigator.pop(context),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(widget.strings.save),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final user = _usernameController.text.trim();
    final pwd = _passwordController.text.trim();
    final sh = _shellController.text.trim();
    if (user.isEmpty || pwd.isEmpty) return;

    setState(() => _busy = true);
    try {
      final admin = context.read<SystemAdminService>();
      await admin.createUser(
        widget.connectionId,
        username: user,
        password: pwd,
        shell: sh,
      );
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.strings.userCreatedSuccess)),
      );
      widget.onCreated();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e')),
      );
    }
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
              strings.switchToChinese == '中文'
                  ? 'System O&M Administration'
                  : '系统运维管理',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              strings.switchToChinese == '中文'
                  ? 'Select a server from the list to connect and manage local accounts, services, ports, and power status.'
                  : '请从列表中选择服务器进行连接，以管理本地账户、系统服务、监听端口和电源状态。',
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
