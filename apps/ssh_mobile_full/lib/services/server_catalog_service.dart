import 'dart:convert';

import 'package:connection_core/connection_core.dart' as connection_core;

import '../features/connection/models/connection.dart';
import 'app_log_service.dart';
import 'sftp_service.dart';
import '../core/services/ssh_client_factory.dart';
import 'ssh_service.dart';
import 'remote_target_scope.dart';
import 'connection_target_binding.dart';

abstract interface class ServerCatalogAdapter {
  List<Map<String, dynamic>> listServerSummaries();

  Map<String, dynamic>? getServerDetails(String connectionId);

  Future<Map<String, dynamic>> updateServerMetadata({
    required String connectionId,
    required Map<String, dynamic> changes,
    ConnectionTargetBinding? approvedTarget,
    ConnectionConfig? approvedCurrent,
    ConnectionConfig? approvedCandidate,
  });

  Future<Map<String, dynamic>> deleteServer(String connectionId);

  Future<Map<String, dynamic>> reorderServers(List<String> orderedIds);
}

class ServerCatalogService implements ServerCatalogAdapter {
  final connection_core.ConnectionRepository connectionRepository;
  final connection_core.CredentialRepository credentialRepository;
  final connection_core.HostKeyRepository hostKeyRepository;
  final SshClientAdapter sshService;
  final SftpClientAdapter sftpService;
  late final SshClientFactory _clientFactory = SshClientFactory(
    credentialRepository: credentialRepository,
    hostKeyRepository: hostKeyRepository,
    logger: AppLogService.instance,
  );

  static const Set<String> _sensitiveFields = {
    'password',
    'privateKey',
    'private_key',
    'apiKey',
    'api_key',
    'token',
    'secret',
  };
  static const Set<String> _allowedUpdateFields = {
    'name',
    'host',
    'port',
    'username',
    'group',
    'serverPlatform',
    'launchMode',
    'tmuxAutoDeleteSeconds',
    'keepAlive',
    'keepAliveInterval',
    'terminalWidth',
    'terminalHeight',
    'jumpHost',
    'jumpPort',
    'jumpUsername',
  };

  ServerCatalogService({
    required this.connectionRepository,
    required this.credentialRepository,
    required this.hostKeyRepository,
    required this.sshService,
    required this.sftpService,
  });

  @override
  List<Map<String, dynamic>> listServerSummaries() {
    return connectionRepository.connections.map(_buildServerSummary).toList();
  }

  @override
  Map<String, dynamic>? getServerDetails(String connectionId) {
    final config = connectionRepository.getConnection(connectionId);
    if (config == null) return null;
    final latestSession = sshService.latestSessionForConnection(connectionId);
    final sessionCount = sshService.sessionCountForConnection(connectionId);
    return {
      'server': _buildServerDetails(config),
      'sessionOverview': {
        'activeSessionCount': sessionCount,
        'hasConnectedSession': sshService.hasConnectedSession(connectionId),
        'latestSessionId': latestSession?.id,
        'latestSessionDisplayName': latestSession?.displayName,
        'latestSessionState': latestSession?.state.name,
        'latestSessionUpdatedAt': latestSession?.updatedAt.toIso8601String(),
      },
    };
  }

  @override
  Future<Map<String, dynamic>> updateServerMetadata({
    required String connectionId,
    required Map<String, dynamic> changes,
    ConnectionTargetBinding? approvedTarget,
    ConnectionConfig? approvedCurrent,
    ConnectionConfig? approvedCandidate,
  }) async {
    final target = await RemoteTargetScope.resolveIfBound(
      connectionRepository: connectionRepository,
      credentialRepository: credentialRepository,
      connectionId: connectionId,
    );
    final current = target.config;
    if (approvedTarget != null && !approvedTarget.matches(current)) {
      throw RemoteTargetScopeException.targetChanged(connectionId);
    }
    if (approvedCurrent != null &&
        _configFingerprint(approvedCurrent) != _configFingerprint(current)) {
      throw RemoteTargetScopeException.targetChanged(connectionId);
    }
    final next = approvedCandidate == null
        ? buildUpdateCandidate(current, changes)
        : ConnectionConfig.fromJson(approvedCandidate.toJson());
    if (next.id != connectionId) {
      throw StateError('Approved server candidate id does not match target.');
    }
    final client = await _clientFactory.connectClient(
      next,
      credentials: SshCredentials(
        password: target.password,
        privateKey: target.privateKey,
      ),
      timeout: const Duration(seconds: 10),
    );
    client.close();
    final currentConfig = connectionRepository.getConnection(connectionId);
    if (currentConfig == null ||
        !target.binding.matches(currentConfig) ||
        (approvedCurrent != null &&
            _configFingerprint(approvedCurrent) !=
                _configFingerprint(currentConfig))) {
      throw RemoteTargetScopeException.targetChanged(connectionId);
    }
    await connectionRepository.updateConnection(
      ConnectionConfig.fromJson(next.toJson()),
    );
    if (approvedCurrent == null) {
      await credentialRepository.saveCredentials(
        connectionId: connectionId,
        password: target.password,
        privateKey: target.privateKey,
      );
    }
    return {'updated': true, 'server': _buildServerDetails(next)};
  }

  static ConnectionConfig buildUpdateCandidate(
    ConnectionConfig current,
    Map<String, dynamic> changes,
  ) {
    _validateUpdateKeys(changes.keys);
    return current.copyWith(
      name: _readOptionalString(changes, 'name') ?? current.name,
      host: _readOptionalString(changes, 'host') ?? current.host,
      port: _readOptionalInt(changes, 'port') ?? current.port,
      username: _readOptionalString(changes, 'username') ?? current.username,
      group: _readOptionalString(changes, 'group') ?? current.group,
      serverPlatform: changes.containsKey('serverPlatform')
          ? ServerPlatform.fromName(changes['serverPlatform'] as String?)
          : current.serverPlatform,
      launchMode: changes.containsKey('launchMode')
          ? TerminalLaunchMode.fromName(changes['launchMode'] as String?)
          : current.launchMode,
      tmuxAutoDeleteSeconds:
          _readOptionalInt(changes, 'tmuxAutoDeleteSeconds') ??
          current.tmuxAutoDeleteSeconds,
      keepAlive: _readOptionalBool(changes, 'keepAlive') ?? current.keepAlive,
      keepAliveInterval:
          _readOptionalInt(changes, 'keepAliveInterval') ??
          current.keepAliveInterval,
      terminalWidth:
          _readOptionalInt(changes, 'terminalWidth') ?? current.terminalWidth,
      terminalHeight:
          _readOptionalInt(changes, 'terminalHeight') ?? current.terminalHeight,
      jumpHost: changes.containsKey('jumpHost')
          ? _readOptionalString(changes, 'jumpHost')
          : current.jumpHost,
      jumpPort: changes.containsKey('jumpPort')
          ? _readOptionalInt(changes, 'jumpPort')
          : current.jumpPort,
      jumpUsername: changes.containsKey('jumpUsername')
          ? _readOptionalString(changes, 'jumpUsername')
          : current.jumpUsername,
    );
  }

  static String _configFingerprint(ConnectionConfig config) =>
      jsonEncode(config.toJson());

  @override
  Future<Map<String, dynamic>> deleteServer(String connectionId) async {
    final target = await RemoteTargetScope.resolveIfBound(
      connectionRepository: connectionRepository,
      credentialRepository: credentialRepository,
      connectionId: connectionId,
    );
    final config = target.config;
    await sshService.disconnectSessionsForConnection(connectionId);
    await sftpService.disconnectConnection(
      connectionId,
      notify: false,
      forgetPath: true,
    );
    final current = connectionRepository.getConnection(connectionId);
    if (!target.binding.matches(current)) {
      throw RemoteTargetScopeException.targetChanged(connectionId);
    }
    await connectionRepository.deleteConnection(connectionId);
    await credentialRepository.deleteCredentials(connectionId);
    return {'deleted': true, 'connectionId': connectionId, 'name': config.name};
  }

  @override
  Future<Map<String, dynamic>> reorderServers(List<String> orderedIds) async {
    final current = connectionRepository.connections
        .map((item) => item.id)
        .toList();
    if (orderedIds.length != current.length ||
        orderedIds.toSet().length != orderedIds.length ||
        !current.toSet().containsAll(orderedIds)) {
      throw StateError(
        'orderedIds must contain every saved server id exactly once.',
      );
    }
    for (var targetIndex = 0; targetIndex < orderedIds.length; targetIndex++) {
      final wantedId = orderedIds[targetIndex];
      final currentIndex = connectionRepository.connections.indexWhere(
        (item) => item.id == wantedId,
      );
      if (currentIndex == -1 || currentIndex == targetIndex) continue;
      await connectionRepository.reorderConnections(currentIndex, targetIndex);
    }
    return {'reordered': true, 'orderedIds': orderedIds};
  }

  Map<String, dynamic> _buildServerSummary(ConnectionConfig config) {
    return {
      'id': config.id,
      'name': config.name,
      'host': config.host,
      'port': config.port,
      'username': config.username,
      'group': config.group,
      'launchMode': config.launchMode.name,
      'serverPlatform': config.serverPlatform.name,
    };
  }

  Map<String, dynamic> _buildServerDetails(ConnectionConfig config) {
    return {
      ..._buildServerSummary(config),
      'keepAlive': config.keepAlive,
      'keepAliveInterval': config.keepAliveInterval,
      'terminalWidth': config.terminalWidth,
      'terminalHeight': config.terminalHeight,
      'tmuxAutoDeleteSeconds': config.tmuxAutoDeleteSeconds,
      'jumpHost': config.jumpHost,
      'jumpPort': config.jumpPort,
      'jumpUsername': config.jumpUsername,
      'authMethod': config.authMethod.name,
      'createdAt': config.createdAt.toIso8601String(),
      'updatedAt': config.updatedAt.toIso8601String(),
    };
  }

  static void _validateUpdateKeys(Iterable<Object?> keys) {
    for (final rawKey in keys) {
      final key = rawKey?.toString() ?? '';
      if (_sensitiveFields.contains(key)) {
        throw StateError('Sensitive credential fields cannot be updated.');
      }
      if (!_allowedUpdateFields.contains(key)) {
        throw StateError('Unsupported server metadata field: $key');
      }
    }
  }

  static String? _readOptionalString(Map<String, dynamic> source, String key) {
    if (!source.containsKey(key)) return null;
    final value = source[key];
    if (value == null) return null;
    if (value is! String) {
      throw StateError('Field $key must be a string.');
    }
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static int? _readOptionalInt(Map<String, dynamic> source, String key) {
    if (!source.containsKey(key)) return null;
    final value = source[key];
    if (value == null) return null;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    throw StateError('Field $key must be an integer.');
  }

  static bool? _readOptionalBool(Map<String, dynamic> source, String key) {
    if (!source.containsKey(key)) return null;
    final value = source[key];
    if (value == null) return null;
    if (value is bool) return value;
    if (value is String) {
      switch (value.trim().toLowerCase()) {
        case 'true':
        case 'yes':
        case '1':
          return true;
        case 'false':
        case 'no':
        case '0':
          return false;
      }
    }
    throw StateError('Field $key must be a boolean.');
  }
}
