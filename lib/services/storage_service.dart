import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/connection.dart';

class StorageService extends ChangeNotifier {
  static const _connectionsKey = 'ssh_connections';
  static const _powerGuideSeenKey = 'power_guide_seen';

  late SharedPreferences _prefs;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  List<ConnectionConfig> _connections = [];
  bool _initialized = false;
  bool _powerGuideSeen = false;

  List<ConnectionConfig> get connections => List.unmodifiable(_connections);
  bool get initialized => _initialized;
  bool get powerGuideSeen => _powerGuideSeen;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _powerGuideSeen = _prefs.getBool(_powerGuideSeenKey) ?? false;
    await _loadConnections();
    _initialized = true;
    notifyListeners();
  }

  Future<void> _loadConnections() async {
    final jsonStr = _prefs.getString(_connectionsKey);
    if (jsonStr == null || jsonStr.isEmpty) {
      _connections = [];
      return;
    }

    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      _connections = list
          .map(
              (item) => ConnectionConfig.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('Failed to load SSH connections: $e');
      _connections = [];
    }
  }

  Future<void> _saveConnections() async {
    if (!_initialized) return;
    final jsonStr =
        jsonEncode(_connections.map((item) => item.toJson()).toList());
    await _prefs.setString(_connectionsKey, jsonStr);
  }

  Future<void> addConnection(ConnectionConfig config) async {
    _ensureInitialized();

    final exists = _connections.any((item) => item.id == config.id);
    if (exists) {
      throw StateError('Connection id already exists: ${config.id}');
    }

    _connections.add(config);
    await _saveSecrets(config);
    await _saveConnections();
    notifyListeners();
  }

  Future<void> updateConnection(ConnectionConfig config) async {
    _ensureInitialized();

    final index = _connections.indexWhere((item) => item.id == config.id);
    if (index == -1) {
      throw StateError('Connection does not exist: ${config.id}');
    }

    _connections[index] = config;
    await _saveSecrets(config);
    await _saveConnections();
    notifyListeners();
  }

  Future<void> deleteConnection(String id) async {
    if (!_initialized) return;

    _connections.removeWhere((item) => item.id == id);
    await _secureStorage.delete(key: 'pwd_$id');
    await _secureStorage.delete(key: 'key_$id');
    await _saveConnections();
    notifyListeners();
  }

  ConnectionConfig? getConnection(String id) {
    try {
      return _connections.firstWhere((item) => item.id == id);
    } catch (_) {
      return null;
    }
  }

  Future<String?> getPassword(String id) async {
    if (!_initialized) return null;
    return _secureStorage.read(key: 'pwd_$id');
  }

  Future<String?> getPrivateKey(String id) async {
    if (!_initialized) return null;
    return _secureStorage.read(key: 'key_$id');
  }

  Future<void> markPowerGuideSeen() async {
    if (!_initialized) return;
    _powerGuideSeen = true;
    await _prefs.setBool(_powerGuideSeenKey, true);
    notifyListeners();
  }

  Future<void> _saveSecrets(ConnectionConfig config) async {
    if (config.password != null && config.password!.isNotEmpty) {
      await _secureStorage.write(
          key: 'pwd_${config.id}', value: config.password);
    } else {
      await _secureStorage.delete(key: 'pwd_${config.id}');
    }

    if (config.privateKey != null && config.privateKey!.isNotEmpty) {
      await _secureStorage.write(
          key: 'key_${config.id}', value: config.privateKey);
    } else {
      await _secureStorage.delete(key: 'key_${config.id}');
    }
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError('Storage service is not initialized yet.');
    }
  }
}
