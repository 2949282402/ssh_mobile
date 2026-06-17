import 'dart:async';
import 'package:flutter/material.dart';
import '../../../services/system_admin_service.dart';
import '../../../services/storage_service.dart';
import '../../connection/models/connection.dart';
import '../../../models/system_admin.dart';

class SystemAdminViewModel extends ChangeNotifier {
  final SystemAdminService _adminService;
  final StorageService _storageService;

  // View state
  static const _serversCollapsedStorageKey = 'system_admin_servers_collapsed';
  bool _serversCollapsed = false;
  bool _restoredServersCollapsed = false;

  // Lists and Loadings
  List<LinuxUserAccount> _accounts = [];
  bool _loadingAccounts = false;

  List<ActiveSession> _sessions = [];
  bool _loadingSessions = false;

  List<SystemdService> _services = [];
  bool _loadingServices = false;

  List<ListeningPort> _ports = [];
  bool _loadingPorts = false;

  String? _lastConnectedId;

  SystemAdminViewModel({
    required SystemAdminService adminService,
    required StorageService storageService,
  })  : _adminService = adminService,
        _storageService = storageService {
    _adminService.addListener(_onAdminServiceChanged);
    if (_adminService.isConnected) {
      _lastConnectedId = _adminService.connectionId;
      refreshAllData();
    }
  }

  @override
  void dispose() {
    _adminService.removeListener(_onAdminServiceChanged);
    super.dispose();
  }

  // Getters from service
  String? get connectionId => _adminService.connectionId;
  bool get isConnecting => _adminService.isConnecting;
  bool get isConnected => _adminService.isConnected;
  String? get errorMessage => _adminService.errorMessage;
  bool get isRoot => _adminService.isRoot;

  List<ConnectionConfig> get connections => _storageService.connections;
  bool get storageInitialized => _storageService.initialized;

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
        refreshAllData();
      }
    } else {
      _lastConnectedId = null;
      _accounts.clear();
      _sessions.clear();
      _services.clear();
      _ports.clear();
      notifyListeners();
    }
  }

  // Connect & Disconnect Actions
  Future<void> connect(String id) async {
    await _adminService.connect(id);
  }

  void disconnect() {
    _adminService.disconnect();
  }

  // Data retrieval wrapper methods
  Future<void> refreshAllData() async {
    final id = connectionId;
    if (id == null) return;
    unawaited(fetchAccounts(id));
    unawaited(fetchSessions(id));
    unawaited(fetchServices(id));
    unawaited(fetchPorts(id));
  }

  Future<void> fetchAccounts(String connId) async {
    _loadingAccounts = true;
    notifyListeners();
    final data = await _adminService.getUserAccounts(connId);
    _accounts = data;
    _loadingAccounts = false;
    notifyListeners();
  }

  Future<void> fetchSessions(String connId) async {
    _loadingSessions = true;
    notifyListeners();
    final data = await _adminService.getActiveSessions(connId);
    _sessions = data;
    _loadingSessions = false;
    notifyListeners();
  }

  Future<void> fetchServices(String connId) async {
    _loadingServices = true;
    notifyListeners();
    final data = await _adminService.getSystemdServices(connId);
    _services = data;
    _loadingServices = false;
    notifyListeners();
  }

  Future<void> fetchPorts(String connId) async {
    _loadingPorts = true;
    notifyListeners();
    final data = await _adminService.getListeningPorts(connId);
    _ports = data;
    _loadingPorts = false;
    notifyListeners();
  }

  // Administration actions
  Future<void> createUser(String username, String password,
      {String shell = '/bin/bash'}) async {
    final id = connectionId;
    if (id == null) return;
    await _adminService.createUser(id,
        username: username, password: password, shell: shell);
    await fetchAccounts(id);
  }

  Future<bool> checkUserSudo(String username) async {
    final id = connectionId;
    if (id == null) return false;
    return await _adminService.checkUserSudo(id, username);
  }

  Future<void> setUserSudo(String username, bool grant) async {
    final id = connectionId;
    if (id == null) return;
    await _adminService.setUserSudo(id, username, grant);
    await fetchAccounts(id);
  }

  Future<void> lockUser(String username) async {
    final id = connectionId;
    if (id == null) return;
    await _adminService.lockUser(id, username);
    await fetchAccounts(id);
  }

  Future<void> unlockUser(String username) async {
    final id = connectionId;
    if (id == null) return;
    await _adminService.unlockUser(id, username);
    await fetchAccounts(id);
  }

  Future<void> changePassword(String username, String newPassword) async {
    final id = connectionId;
    if (id == null) return;
    await _adminService.changePassword(id, username, newPassword);
    await fetchAccounts(id);
  }

  Future<String> getUserHomeStorageUsage(String homeDir) async {
    final id = connectionId;
    if (id == null) return 'N/A';
    return await _adminService.getUserHomeStorageUsage(id, homeDir);
  }

  Future<List<LinuxUserProcess>> getUserProcessesAndMemory(
      String username) async {
    final id = connectionId;
    if (id == null) return [];
    return await _adminService.getUserProcessesAndMemory(id, username);
  }

  Future<void> killActiveSession(String tty) async {
    final id = connectionId;
    if (id == null) return;
    await _adminService.killActiveSession(id, tty);
    await fetchSessions(id);
  }

  Future<void> manageSystemdService(String serviceName, String action) async {
    final id = connectionId;
    if (id == null) return;
    await _adminService.manageSystemdService(id, serviceName, action);
    await fetchServices(id);
  }

  Future<void> rebootServer() async {
    final id = connectionId;
    if (id == null) return;
    await _adminService.rebootServer(id);
  }

  Future<void> shutdownServer() async {
    final id = connectionId;
    if (id == null) return;
    await _adminService.shutdownServer(id);
  }
}
