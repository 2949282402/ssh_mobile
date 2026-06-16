import 'dart:async';
import 'package:flutter/foundation.dart';

import '../../../core/services/ssh_client_factory.dart';
import '../../../services/ssh_service.dart';
import '../models/connection.dart';
import '../../../services/storage_service.dart';

class ConnectionViewModel extends ChangeNotifier {
  final ConnectionRepository _connectionRepository;
  final SshService _sshService;

  List<ConnectionConfig> _connections = [];
  bool _isLoading = false;
  bool _isSaving = false;
  bool _isVerifying = false;
  String? _errorMessage;

  ConnectionViewModel({
    required ConnectionRepository connectionRepository,
    required SshService sshService,
  })  : _connectionRepository = connectionRepository,
        _sshService = sshService;

  List<ConnectionConfig> get connections => _connections;
  bool get isLoading => _isLoading;
  bool get isSaving => _isSaving;
  bool get isVerifying => _isVerifying;
  String? get errorMessage => _errorMessage;

  Future<void> fetchConnections() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      _connections = _connectionRepository.connections;
    } catch (e) {
      _errorMessage = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> deleteConnection(String id) async {
    _errorMessage = null;
    notifyListeners();
    try {
      await _connectionRepository.deleteConnection(id);
      _connections = _connectionRepository.connections;
    } catch (e) {
      _errorMessage = e.toString();
    } finally {
      notifyListeners();
    }
  }

  Future<void> deleteConnections(List<String> ids) async {
    _errorMessage = null;
    notifyListeners();
    try {
      await _connectionRepository.deleteConnections(ids);
      _connections = _connectionRepository.connections;
    } catch (e) {
      _errorMessage = e.toString();
    } finally {
      notifyListeners();
    }
  }

  Future<void> reorderConnections(int oldIndex, int newIndex) async {
    try {
      await _connectionRepository.reorderConnections(oldIndex, newIndex);
      _connections = _connectionRepository.connections;
      notifyListeners();
    } catch (e) {
      _errorMessage = e.toString();
      notifyListeners();
    }
  }

  Future<bool> verifyAndSaveConnection({
    required ConnectionConfig config,
    required bool isEditing,
    required String? rawPassword,
    required String? rawPrivateKey,
    required Future<bool> Function(int activeWindows) confirmDisconnectCallback,
  }) async {
    _isSaving = true;
    _isVerifying = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final clientConfig = ConnectionConfig(
        id: config.id,
        name: config.name,
        host: config.host,
        port: config.port,
        username: config.username,
        password: rawPassword,
        privateKey: rawPrivateKey,
        authMethod: config.authMethod,
        launchMode: config.launchMode,
        serverPlatform: config.serverPlatform,
        tmuxAutoDeleteSeconds: config.tmuxAutoDeleteSeconds,
        keepAlive: config.keepAlive,
        jumpHost: config.jumpHost,
        jumpPort: config.jumpPort,
        jumpUsername: config.jumpUsername,
      );

      final factory = SshClientFactory(_connectionRepository as StorageService);
      final client = await factory.connectClient(
        clientConfig,
        timeout: const Duration(seconds: 12),
        credentials: SshCredentials(
          password: rawPassword,
          privateKey: rawPrivateKey,
        ),
      );
      try {
        await client.ping().timeout(const Duration(seconds: 8));
      } finally {
        client.close();
      }

      _isVerifying = false;
      notifyListeners();

      final activeWindowCount =
          isEditing ? _sshService.sessionCountForConnection(config.id) : 0;
      if (activeWindowCount > 0) {
        _isSaving = false;
        notifyListeners();
        final confirmed = await confirmDisconnectCallback(activeWindowCount);
        if (!confirmed) {
          return false;
        }
        _isSaving = true;
        notifyListeners();
      }

      if (isEditing) {
        await _connectionRepository.updateConnection(config);
        if (activeWindowCount > 0) {
          await _sshService.disconnectSessionsForConnection(config.id);
        }
      } else {
        await _connectionRepository.addConnection(config);
      }

      _connections = _connectionRepository.connections;
      return true;
    } catch (e) {
      _errorMessage = e.toString();
      rethrow;
    } finally {
      _isVerifying = false;
      _isSaving = false;
      notifyListeners();
    }
  }

  ConnectionConfig? getConnection(String id) {
    return _connectionRepository.getConnection(id);
  }

  Future<String?> getPassword(String id) {
    return _connectionRepository.getPassword(id);
  }

  Future<String?> getPrivateKey(String id) {
    return _connectionRepository.getPrivateKey(id);
  }
}
