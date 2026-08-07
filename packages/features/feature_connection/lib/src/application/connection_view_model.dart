// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:connection_core/connection_core.dart';

import 'connection_ports.dart';

/// Connection Feature 的应用状态协调器。
///
/// ViewModel 只编排 Repository 和 Capability Contract，不创建数据库、
/// Secure Storage、SSH、SFTP 或监控服务。它的生命周期由 Route/Provider
/// 管理，释放时仅解除自身监听，避免误关闭 App Scope 资源。
class ConnectionViewModel extends ChangeNotifier {
  ConnectionViewModel({
    required ConnectionRepository connectionRepository,
    required CredentialRepository credentialRepository,
    required HostKeyRepository hostKeyRepository,
    required ConnectionRuntimePort runtimePort,
    required ConnectionVerificationPort verificationPort,
  }) : _connectionRepository = connectionRepository,
       _credentialRepository = credentialRepository,
       _hostKeyRepository = hostKeyRepository,
       _runtimePort = runtimePort,
       _verificationPort = verificationPort;

  final ConnectionRepository _connectionRepository;
  final CredentialRepository _credentialRepository;
  final HostKeyRepository _hostKeyRepository;
  final ConnectionRuntimePort _runtimePort;
  final ConnectionVerificationPort _verificationPort;

  List<ConnectionConfig> _connections = const [];
  bool _isLoading = false;
  bool _isSaving = false;
  bool _isVerifying = false;
  String? _errorMessage;

  List<ConnectionConfig> get connections => _connections;
  bool get isLoading => _isLoading;
  bool get isSaving => _isSaving;
  bool get isVerifying => _isVerifying;
  String? get errorMessage => _errorMessage;

  /// 从 Repository 重新加载结构快照，避免首屏只看到尚未初始化的空列表。
  Future<void> fetchConnections() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      _connections = List.unmodifiable(
        await _connectionRepository.loadConnections(),
      );
    } catch (error) {
      _errorMessage = error.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 删除单个连接并清理 SSH/SFTP/监控资源及凭据。
  Future<void> deleteConnectionWithCleanup(String connectionId) async {
    _errorMessage = null;
    notifyListeners();
    try {
      await _runtimePort.cleanupConnectionResources(connectionId);
      await _connectionRepository.deleteConnection(connectionId);
      await _credentialRepository.deleteCredentials(connectionId);
      _connections = List.unmodifiable(_connectionRepository.connections);
    } catch (error) {
      _errorMessage = error.toString();
    } finally {
      notifyListeners();
    }
  }

  /// 批量删除连接，保持用户选择的顺序完成资源清理。
  Future<void> deleteConnectionsWithCleanup(List<String> connectionIds) async {
    _errorMessage = null;
    notifyListeners();
    try {
      for (final id in connectionIds) {
        await _runtimePort.cleanupConnectionResources(id);
      }
      await _connectionRepository.deleteConnections(connectionIds);
      for (final id in connectionIds) {
        await _credentialRepository.deleteCredentials(id);
      }
      _connections = List.unmodifiable(_connectionRepository.connections);
    } catch (error) {
      _errorMessage = error.toString();
    } finally {
      notifyListeners();
    }
  }

  /// 只改变连接列表顺序，UI 先乐观更新，Repository 负责最终持久化。
  Future<void> reorderConnections(int oldIndex, int newIndex) async {
    if (oldIndex >= 0 &&
        oldIndex < _connections.length &&
        newIndex >= 0 &&
        newIndex <= _connections.length) {
      final mutable = List<ConnectionConfig>.from(_connections);
      final item = mutable.removeAt(oldIndex);
      mutable.insert(newIndex, item);
      _connections = List.unmodifiable(mutable);
      notifyListeners();
    }
    try {
      await _connectionRepository.reorderConnections(oldIndex, newIndex);
    } catch (error) {
      _errorMessage = error.toString();
      notifyListeners();
    }
  }

  /// 验证登录、处理 Host Key、确认活动窗口后保存连接和凭据。
  Future<bool> verifyAndSaveConnection({
    required ConnectionConfig config,
    required bool isEditing,
    required String? rawPassword,
    required String? rawPrivateKey,
    required Future<bool> Function(int activeWindows) confirmDisconnectCallback,
    ConnectionHostKeyConfirmation? onUnknownHostKey,
  }) async {
    _isSaving = true;
    _isVerifying = true;
    _errorMessage = null;
    notifyListeners();

    try {
      if (!kIsWeb) {
        final clientConfig = _copyForVerification(
          config,
          password: rawPassword,
          privateKey: rawPrivateKey,
        );
        final result = await _verificationPort.verify(
          clientConfig,
          password: rawPassword,
          privateKey: rawPrivateKey,
          onUnknownHostKey: onUnknownHostKey,
        );
        config.hostKeyAlgorithm = result.algorithm ?? config.hostKeyAlgorithm;
        config.hostKeyFingerprint =
            result.fingerprint ?? config.hostKeyFingerprint;
        config.hostKeyTrustedAt = result.trustedAt ?? config.hostKeyTrustedAt;
        if (config.hostKeyFingerprint?.isNotEmpty == true) {
          await _hostKeyRepository.trustHostKey(
            config.id,
            algorithm: config.hostKeyAlgorithm,
            fingerprint: config.hostKeyFingerprint,
            trustedAt: config.hostKeyTrustedAt,
          );
        }
      }

      _isVerifying = false;
      notifyListeners();

      final activeWindowCount = isEditing
          ? await _runtimePort.activeWindowCount(config.id)
          : 0;
      if (activeWindowCount > 0) {
        _isSaving = false;
        notifyListeners();
        final confirmed = await confirmDisconnectCallback(activeWindowCount);
        if (!confirmed) return false;
        _isSaving = true;
        notifyListeners();
      }

      if (isEditing) {
        await _connectionRepository.updateConnection(config);
        if (activeWindowCount > 0) {
          await _runtimePort.disconnectSessionsForConnection(config.id);
        }
      } else {
        await _connectionRepository.addConnection(config);
      }
      await _credentialRepository.saveCredentials(
        connectionId: config.id,
        password: rawPassword,
        privateKey: rawPrivateKey,
      );

      _connections = List.unmodifiable(_connectionRepository.connections);
      return true;
    } catch (error) {
      _errorMessage = error.toString();
      rethrow;
    } finally {
      _isVerifying = false;
      _isSaving = false;
      notifyListeners();
    }
  }

  ConnectionConfig? getConnection(String id) =>
      _connectionRepository.getConnection(id);

  Future<String?> getPassword(String id) =>
      _credentialRepository.getPassword(id);

  Future<String?> getPrivateKey(String id) =>
      _credentialRepository.getPrivateKey(id);

  /// 请求 App Scope 打开终端；失败信息仍由注入的运行时能力提供。
  Future<String?> openTerminalSession(
    String connectionId,
    String windowName, {
    ConnectionHostKeyConfirmation? onUnknownHostKey,
  }) async {
    _errorMessage = null;
    notifyListeners();
    try {
      final sessionId = await _runtimePort.openTerminalSession(
        connectionId,
        windowName,
        onUnknownHostKey: onUnknownHostKey,
      );
      if (sessionId == null) _errorMessage = _runtimePort.errorMessage;
      return sessionId;
    } catch (error) {
      _errorMessage = error.toString();
      return null;
    } finally {
      notifyListeners();
    }
  }

  ConnectionConfig _copyForVerification(
    ConnectionConfig config, {
    required String? password,
    required String? privateKey,
  }) {
    return ConnectionConfig(
      id: config.id,
      name: config.name,
      host: config.host,
      port: config.port,
      username: config.username,
      password: password,
      privateKey: privateKey,
      authMethod: config.authMethod,
      terminalWidth: config.terminalWidth,
      terminalHeight: config.terminalHeight,
      keepAlive: config.keepAlive,
      keepAliveInterval: config.keepAliveInterval,
      launchMode: config.launchMode,
      serverPlatform: config.serverPlatform,
      tmuxAutoDeleteSeconds: config.tmuxAutoDeleteSeconds,
      hostKeyFingerprint: config.hostKeyFingerprint,
      hostKeyAlgorithm: config.hostKeyAlgorithm,
      hostKeyTrustedAt: config.hostKeyTrustedAt,
      createdAt: config.createdAt,
      updatedAt: config.updatedAt,
      jumpHost: config.jumpHost,
      jumpPort: config.jumpPort,
      jumpUsername: config.jumpUsername,
      group: config.group,
    );
  }
}
