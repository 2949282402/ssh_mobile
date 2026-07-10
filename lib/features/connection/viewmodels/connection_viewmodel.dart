import 'dart:async';
import 'package:flutter/foundation.dart';

import '../../../core/services/ssh_client_factory.dart';
import '../../../core/services/ssh_host_key_policy.dart';
import '../../../services/ssh_service.dart';
import '../../../services/sftp_service.dart';
import '../../../services/performance_monitor_service.dart';
import '../models/connection.dart';
import '../../../services/storage_service.dart';

class ConnectionViewModel extends ChangeNotifier {
  final ConnectionRepository _connectionRepository;
  final SshService _sshService;
  final SftpService _sftpService;
  final PerformanceMonitorService _performanceService;

  List<ConnectionConfig> _connections = [];
  bool _isLoading = false;
  bool _isSaving = false;
  bool _isVerifying = false;
  String? _errorMessage;

  ConnectionViewModel({
    required this._connectionRepository,
    required this._sshService,
    required this._sftpService,
    required this._performanceService,
  });

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
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    _isSaving = true;
    _isVerifying = true;
    _errorMessage = null;
    notifyListeners();

    try {
      if (kIsWeb) {
        _isVerifying = false;
        notifyListeners();
        if (isEditing) {
          await _connectionRepository.updateConnection(config);
        } else {
          await _connectionRepository.addConnection(config);
        }
        _connections = _connectionRepository.connections;
        return true;
      }

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
        hostKeyFingerprint: config.hostKeyFingerprint,
        hostKeyAlgorithm: config.hostKeyAlgorithm,
        hostKeyTrustedAt: config.hostKeyTrustedAt,
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
        onUnknownHostKey: onUnknownHostKey,
      );
      try {
        await client.ping().timeout(const Duration(seconds: 8));
      } finally {
        client.close();
      }
      config.hostKeyFingerprint = clientConfig.hostKeyFingerprint;
      config.hostKeyAlgorithm = clientConfig.hostKeyAlgorithm;
      config.hostKeyTrustedAt = clientConfig.hostKeyTrustedAt;

      _isVerifying = false;
      notifyListeners();

      final activeWindowCount = isEditing
          ? _sshService.sessionCountForConnection(config.id)
          : 0;
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

  Future<String?> openTerminalSession(
    String connectionId,
    String windowName, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    _errorMessage = null;
    notifyListeners();
    try {
      final sessionId = await _sshService.openSession(
        connectionId,
        displayName: windowName,
        onUnknownHostKey: onUnknownHostKey,
      );
      if (sessionId == null) {
        _errorMessage = _sshService.errorMessage;
      }
      return sessionId;
    } catch (e) {
      _errorMessage = e.toString();
      return null;
    } finally {
      notifyListeners();
    }
  }

  Future<void> deleteConnectionWithCleanup(String connectionId) async {
    _errorMessage = null;
    notifyListeners();
    try {
      await _sshService.disconnectSessionsForConnection(connectionId);
      await _sftpService.disconnectConnection(connectionId, forgetPath: true);
      _performanceService.stopForConnection(connectionId);
      await _connectionRepository.deleteConnection(connectionId);
      _connections = _connectionRepository.connections;
    } catch (e) {
      _errorMessage = e.toString();
    } finally {
      notifyListeners();
    }
  }

  Future<void> deleteConnectionsWithCleanup(List<String> connectionIds) async {
    _errorMessage = null;
    notifyListeners();
    try {
      for (final id in connectionIds) {
        await _sshService.disconnectSessionsForConnection(id);
        await _sftpService.disconnectConnection(id, forgetPath: true);
        _performanceService.stopForConnection(id);
      }
      await _connectionRepository.deleteConnections(connectionIds);
      _connections = _connectionRepository.connections;
    } catch (e) {
      _errorMessage = e.toString();
    } finally {
      notifyListeners();
    }
  }
}
