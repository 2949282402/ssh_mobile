import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/connection.dart';

/// 存储服务 - 连接配置 + 密码安全管理
class StorageService extends ChangeNotifier {
  static const _connectionsKey = 'ssh_connections';
  static const _settingsKey = 'ssh_settings';

  late SharedPreferences _prefs;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  List<ConnectionConfig> _connections = [];
  bool _initialized = false;

  List<ConnectionConfig> get connections => List.unmodifiable(_connections);
  bool get initialized => _initialized;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await _loadConnections();
    _initialized = true;
    notifyListeners();
  }

  /// 加载所有连接配置（密码从安全存储单独拉取）
  Future<void> _loadConnections() async {
    final jsonStr = _prefs.getString(_connectionsKey);
    if (jsonStr == null || jsonStr.isEmpty) {
      _connections = [];
      return;
    }
    try {
      final List<dynamic> list = jsonDecode(jsonStr);
      _connections = list
          .map((e) => ConnectionConfig.fromJson(e as Map<String, dynamic>))
          .toList();

      // 从安全存储恢复密码
      for (final conn in _connections) {
        final password = await _secureStorage.read(key: 'pwd_${conn.id}');
        final privateKey = await _secureStorage.read(key: 'key_${conn.id}');
        if (password != null) {
          conn.password = password;
        }
        if (privateKey != null) {
          conn.privateKey = privateKey;
        }
      }
    } catch (e) {
      debugPrint('加载连接配置失败: $e');
      _connections = [];
    }
  }

  /// 保存所有连接配置
  Future<void> _saveConnections() async {
    final jsonStr = jsonEncode(_connections.map((e) => e.toJson()).toList());
    await _prefs.setString(_connectionsKey, jsonStr);
  }

  /// 添加连接
  Future<void> addConnection(ConnectionConfig config) async {
    // 检查重名
    final exists = _connections.any((c) => c.id == config.id);
    if (exists) {
      throw Exception('连接 ID 已存在');
    }

    _connections.add(config);

    // 安全存储密码/私钥
    if (config.password != null && config.password!.isNotEmpty) {
      await _secureStorage.write(key: 'pwd_${config.id}', value: config.password!);
    }
    if (config.privateKey != null && config.privateKey!.isNotEmpty) {
      await _secureStorage.write(key: 'key_${config.id}', value: config.privateKey!);
    }

    await _saveConnections();
    notifyListeners();
  }

  /// 更新连接
  Future<void> updateConnection(ConnectionConfig config) async {
    final index = _connections.indexWhere((c) => c.id == config.id);
    if (index == -1) {
      throw Exception('连接不存在: ${config.id}');
    }

    _connections[index] = config;

    // 更新密码/私钥
    if (config.password != null && config.password!.isNotEmpty) {
      await _secureStorage.write(key: 'pwd_${config.id}', value: config.password!);
    } else {
      await _secureStorage.delete(key: 'pwd_${config.id}');
    }
    if (config.privateKey != null && config.privateKey!.isNotEmpty) {
      await _secureStorage.write(key: 'key_${config.id}', value: config.privateKey!);
    } else {
      await _secureStorage.delete(key: 'key_${config.id}');
    }

    await _saveConnections();
    notifyListeners();
  }

  /// 删除连接
  Future<void> deleteConnection(String id) async {
    _connections.removeWhere((c) => c.id == id);
    await _secureStorage.delete(key: 'pwd_$id');
    await _secureStorage.delete(key: 'key_$id');
    await _saveConnections();
    notifyListeners();
  }

  /// 获取单个连接
  ConnectionConfig? getConnection(String id) {
    try {
      return _connections.firstWhere((c) => c.id == id);
    } catch (_) {
      return null;
    }
  }

  /// 获取密码（从安全存储）
  Future<String?> getPassword(String id) async {
    return await _secureStorage.read(key: 'pwd_$id');
  }

  /// 获取私钥
  Future<String?> getPrivateKey(String id) async {
    return await _secureStorage.read(key: 'key_$id');
  }
}
