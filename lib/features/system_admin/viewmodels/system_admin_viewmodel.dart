import 'package:flutter/material.dart';
import '../../../services/system_admin_service.dart';
import '../../../services/storage_service.dart';
import '../../../widgets/system_power_confirm_flow.dart';
import '../../connection/models/connection.dart';
import '../../../models/system_admin.dart';

class SystemAdminViewModel extends ChangeNotifier {
  final SystemAdminService _adminService;
  final StorageService _storageService;

  // View state
  static const _serversCollapsedStorageKey = 'system_admin_servers_collapsed';
  bool _serversCollapsed = false;
  bool _restoredServersCollapsed = false;
  String? _selectedConnectionId;

  // Lists and Loadings
  List<LinuxUserAccount> _accounts = [];
  bool _loadingAccounts = false;
  String? _accountsLoadedFor;

  List<ActiveSession> _sessions = [];
  bool _loadingSessions = false;
  String? _sessionsLoadedFor;

  List<SystemdService> _services = [];
  bool _loadingServices = false;
  String? _servicesLoadedFor;

  List<ListeningPort> _ports = [];
  bool _loadingPorts = false;
  String? _portsLoadedFor;

  String? _lastConnectedId;
  String? _connectingConnectionId;

  SystemAdminViewModel({
    required SystemAdminService adminService,
    required StorageService storageService,
  })  : _adminService = adminService,
        _storageService = storageService {
    _adminService.addListener(_onAdminServiceChanged);
    _storageService.addListener(_onStorageChanged);
    if (_adminService.isConnected) {
      _selectedConnectionId = _adminService.connectionId;
      _lastConnectedId = _adminService.connectionId;
    }
  }

  @override
  void dispose() {
    _adminService.removeListener(_onAdminServiceChanged);
    _storageService.removeListener(_onStorageChanged);
    super.dispose();
  }

  // Getters from service
  String? get managementConnectionId => _adminService.connectionId;
  String? get selectedConnectionId => _selectedConnectionId;
  String? get connectionId => _selectedConnectionId;
  bool get isConnecting => _adminService.isConnecting;
  bool get isConnected => _adminService.isConnected;
  String? get errorMessage => _adminService.errorMessage;
  bool get isRoot => _adminService.isRoot;

  String? get activeManagementConnectionId {
    final currentManagementId = _adminService.connectionId;
    if (currentManagementId == null) return null;
    if (currentManagementId != _selectedConnectionId) return null;
    return currentManagementId;
  }

  bool get canManageSelectedConnection {
    return activeManagementConnectionId != null &&
        _adminService.isConnected &&
        _adminService.isRoot;
  }

  bool get isConnectingSelectedConnection {
    return _adminService.connectionId == _selectedConnectionId &&
        _adminService.isConnecting;
  }

  bool get isConnectedSelectedConnection {
    return _adminService.connectionId == _selectedConnectionId &&
        _adminService.isConnected;
  }

  bool get hasManagementErrorForSelectedConnection {
    return _adminService.connectionId == _selectedConnectionId &&
        _adminService.errorMessage != null;
  }

  List<ConnectionConfig> get connections => _storageService.connections;
  bool get storageInitialized => _storageService.initialized;
  ConnectionConfig? get selectedConnection =>
      connectionById(_selectedConnectionId);
  bool get hasValidSelection {
    if (_selectedConnectionId == null) return false;
    return selectedConnection != null;
  }

  // Local state getters
  bool get serversCollapsed => _serversCollapsed && connections.isNotEmpty;
  List<LinuxUserAccount> get accounts => _accounts;
  bool get loadingAccounts => _loadingAccounts;

  List<ActiveSession> get sessions => _sessions;
  bool get loadingSessions => _loadingSessions;

  List<SystemdService> get services => _services;
  bool get loadingServices => _loadingServices;

  List<ListeningPort> get ports => _ports;
  bool get loadingPorts => _loadingPorts;

  ConnectionConfig? connectionById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final connection in connections) {
      if (connection.id == id) return connection;
    }
    return null;
  }

  bool isConnectingConnection(String id) {
    return _connectingConnectionId == id && _adminService.isConnecting;
  }

  void restoreServersCollapsed(BuildContext context) {
    if (_restoredServersCollapsed) return;
    _restoredServersCollapsed = true;
    final stored = PageStorage.maybeOf(context)?.readState(
      context,
      identifier: _serversCollapsedStorageKey,
    );
    if (stored is bool) {
      _serversCollapsed = stored;
      notifyListeners();
    }
  }

  void setServersCollapsed(BuildContext context, bool collapsed) {
    if (_serversCollapsed == collapsed) return;
    _serversCollapsed = collapsed;
    PageStorage.maybeOf(context)?.writeState(
      context,
      collapsed,
      identifier: _serversCollapsedStorageKey,
    );
    notifyListeners();
  }

  void _onAdminServiceChanged() {
    if (_adminService.isConnected) {
      if (_lastConnectedId != _adminService.connectionId) {
        _lastConnectedId = _adminService.connectionId;

        _selectedConnectionId ??= _adminService.connectionId;

        notifyListeners();
      } else {
        notifyListeners();
      }
    } else {
      _lastConnectedId = null;
      _clearManagementData();
      notifyListeners();
    }
  }

  void _onStorageChanged() {
    if (_selectedConnectionId != null &&
        connectionById(_selectedConnectionId) == null) {
      clearInvalidSelection();
      return;
    }
    notifyListeners();
  }

  void _clearManagementData() {
    _accounts.clear();
    _sessions.clear();
    _services.clear();
    _ports.clear();

    _loadingAccounts = false;
    _loadingSessions = false;
    _loadingServices = false;
    _loadingPorts = false;

    _accountsLoadedFor = null;
    _sessionsLoadedFor = null;
    _servicesLoadedFor = null;
    _portsLoadedFor = null;
  }

  void clearInvalidSelection() {
    final oldSelectedId = _selectedConnectionId;
    if (oldSelectedId == null) return;

    _selectedConnectionId = null;
    _clearManagementData();

    if (_adminService.connectionId == oldSelectedId) {
      _adminService.disconnect();
    }

    notifyListeners();
  }

  void validateSelectedConnection() {
    if (_selectedConnectionId == null) return;
    if (connectionById(_selectedConnectionId) != null) return;
    clearInvalidSelection();
  }

  // Connect & Disconnect Actions
  void selectConnection(String id) {
    if (_selectedConnectionId == id) return;
    _selectedConnectionId = id;
    _clearManagementData();
    notifyListeners();
  }

  Future<void> connect(String id) async {
    await _adminService.connect(id);
  }

  Future<void> connectIfNeeded(String id) async {
    if (_selectedConnectionId != id) return;

    if (_connectingConnectionId == id && _adminService.isConnecting) return;

    if (_adminService.isConnected &&
        _adminService.connectionId == id &&
        _adminService.isRoot) {
      return;
    }

    _connectingConnectionId = id;
    notifyListeners();

    try {
      await _adminService.connect(id);
    } finally {
      if (_connectingConnectionId == id) {
        _connectingConnectionId = null;
        notifyListeners();
      }
    }
  }

  void disconnect() {
    _adminService.disconnect();
  }

  // Data retrieval wrapper methods
  Future<void> refreshAllData() async {
    final id = activeManagementConnectionId;
    if (id == null) return;
    await fetchAccounts(id, force: true);
    await fetchSessions(id, force: true);
    await fetchServices(id, force: true);
    await fetchPorts(id, force: true);
  }

  Future<void> fetchAccounts(String connId, {bool force = false}) async {
    if (!force && _accountsLoadedFor == connId) return;
    if (activeManagementConnectionId != connId) return;

    _loadingAccounts = true;
    notifyListeners();
    try {
      final data = await _adminService.getUserAccounts(connId);
      if (_selectedConnectionId != connId ||
          activeManagementConnectionId != connId) {
        return;
      }
      _accounts = data;
      _accountsLoadedFor = connId;
    } finally {
      if (_selectedConnectionId == connId) {
        _loadingAccounts = false;
        notifyListeners();
      }
    }
  }

  Future<void> fetchSessions(String connId, {bool force = false}) async {
    if (!force && _sessionsLoadedFor == connId) return;
    if (activeManagementConnectionId != connId) return;

    _loadingSessions = true;
    notifyListeners();
    try {
      final data = await _adminService.getActiveSessions(connId);
      if (_selectedConnectionId != connId ||
          activeManagementConnectionId != connId) {
        return;
      }
      _sessions = data;
      _sessionsLoadedFor = connId;
    } finally {
      if (_selectedConnectionId == connId) {
        _loadingSessions = false;
        notifyListeners();
      }
    }
  }

  Future<void> fetchServices(String connId, {bool force = false}) async {
    if (!force && _servicesLoadedFor == connId) return;
    if (activeManagementConnectionId != connId) return;

    _loadingServices = true;
    notifyListeners();
    try {
      final data = await _adminService.getSystemdServices(connId);
      if (_selectedConnectionId != connId ||
          activeManagementConnectionId != connId) {
        return;
      }
      _services = data;
      _servicesLoadedFor = connId;
    } finally {
      if (_selectedConnectionId == connId) {
        _loadingServices = false;
        notifyListeners();
      }
    }
  }

  Future<void> fetchPorts(String connId, {bool force = false}) async {
    if (!force && _portsLoadedFor == connId) return;
    if (activeManagementConnectionId != connId) return;

    _loadingPorts = true;
    notifyListeners();
    try {
      final data = await _adminService.getListeningPorts(connId);
      if (_selectedConnectionId != connId ||
          activeManagementConnectionId != connId) {
        return;
      }
      _ports = data;
      _portsLoadedFor = connId;
    } finally {
      if (_selectedConnectionId == connId) {
        _loadingPorts = false;
        notifyListeners();
      }
    }
  }

  // Administration actions
  Future<void> createUser(String username, String password,
      {String shell = '/bin/bash'}) async {
    final id = activeManagementConnectionId;
    if (id == null) return;
    await _adminService.createUser(id,
        username: username, password: password, shell: shell);
    await fetchAccounts(id, force: true);
  }

  Future<bool> checkUserSudo(String username) async {
    final id = activeManagementConnectionId;
    if (id == null) return false;
    return await _adminService.checkUserSudo(id, username);
  }

  Future<void> setUserSudo(String username, bool grant) async {
    final id = activeManagementConnectionId;
    if (id == null) return;
    await _adminService.setUserSudo(id, username, grant);
    await fetchAccounts(id, force: true);
  }

  Future<void> lockUser(String username) async {
    final id = activeManagementConnectionId;
    if (id == null) return;
    await _adminService.lockUser(id, username);
    await fetchAccounts(id, force: true);
  }

  Future<void> unlockUser(String username) async {
    final id = activeManagementConnectionId;
    if (id == null) return;
    await _adminService.unlockUser(id, username);
    await fetchAccounts(id, force: true);
  }

  Future<void> changePassword(String username, String newPassword) async {
    final id = activeManagementConnectionId;
    if (id == null) return;
    await _adminService.changePassword(id, username, newPassword);
    await fetchAccounts(id, force: true);
  }

  Future<String> getUserHomeStorageUsage(String homeDir) async {
    final id = activeManagementConnectionId;
    if (id == null) return 'N/A';
    return await _adminService.getUserHomeStorageUsage(id, homeDir);
  }

  Future<List<LinuxUserProcess>> getUserProcessesAndMemory(
      String username) async {
    final id = activeManagementConnectionId;
    if (id == null) return [];
    return await _adminService.getUserProcessesAndMemory(id, username);
  }

  Future<void> killActiveSession(String tty) async {
    final id = activeManagementConnectionId;
    if (id == null) return;
    await _adminService.killActiveSession(id, tty);
    await fetchSessions(id, force: true);
  }

  Future<void> manageSystemdService(String serviceName, String action) async {
    final id = activeManagementConnectionId;
    if (id == null) return;
    await _adminService.manageSystemdService(id, serviceName, action);
    await fetchServices(id, force: true);
  }

  Future<void> rebootServer(SystemPowerConfirmationToken token) async {
    if (token.action != SystemPowerAction.reboot) {
      throw ArgumentError('Invalid token action for rebootServer');
    }
    if (!token.isFresh) {
      throw StateError('System power confirmation token expired');
    }
    final id = activeManagementConnectionId;
    if (id == null) return;
    await _adminService.rebootServer(id, token);
  }

  Future<void> shutdownServer(SystemPowerConfirmationToken token) async {
    if (token.action != SystemPowerAction.shutdown) {
      throw ArgumentError('Invalid token action for shutdownServer');
    }
    if (!token.isFresh) {
      throw StateError('System power confirmation token expired');
    }
    final id = activeManagementConnectionId;
    if (id == null) return;
    await _adminService.shutdownServer(id, token);
  }
}
