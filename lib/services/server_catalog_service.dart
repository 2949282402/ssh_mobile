import '../models/connection.dart';
import 'sftp_service.dart';
import 'ssh_client_factory.dart';
import 'ssh_service.dart';
import 'storage_service.dart';

abstract interface class ServerCatalogAdapter {
  List<Map<String, dynamic>> listServerSummaries();

  Map<String, dynamic>? getServerDetails(String connectionId);

  Future<Map<String, dynamic>> updateServerMetadata({
    required String connectionId,
    required Map<String, dynamic> changes,
  });

  Future<Map<String, dynamic>> deleteServer(String connectionId);

  Future<Map<String, dynamic>> reorderServers(List<String> orderedIds);
}

class ServerCatalogService implements ServerCatalogAdapter {
  final StorageService storageService;
  final SshClientAdapter sshService;
  final SftpClientAdapter sftpService;
  late final SshClientFactory _clientFactory = SshClientFactory(storageService);

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
    required this.storageService,
    required this.sshService,
    required this.sftpService,
  });

  @override
  List<Map<String, dynamic>> listServerSummaries() {
    return storageService.connections.map(_buildServerSummary).toList();
  }

  @override
  Map<String, dynamic>? getServerDetails(String connectionId) {
    final config = storageService.getConnection(connectionId);
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
  }) async {
    final current = storageService.getConnection(connectionId);
    if (current == null) {
      throw StateError('Connection config not found.');
    }
    _validateUpdateKeys(changes.keys);
    final next = current.copyWith(
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
      keepAliveInterval: _readOptionalInt(changes, 'keepAliveInterval') ??
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
    final client = await _clientFactory.connectClient(
      next,
      timeout: const Duration(seconds: 10),
    );
    client.close();
    await storageService.updateConnection(next);
    return {
      'updated': true,
      'server': _buildServerDetails(next),
    };
  }

  @override
  Future<Map<String, dynamic>> deleteServer(String connectionId) async {
    final config = storageService.getConnection(connectionId);
    if (config == null) {
      throw StateError('Connection config not found.');
    }
    await sshService.disconnectSessionsForConnection(connectionId);
    await sftpService.disconnectConnection(
      connectionId,
      notify: false,
      forgetPath: true,
    );
    await storageService.deleteConnection(connectionId);
    return {
      'deleted': true,
      'connectionId': connectionId,
      'name': config.name,
    };
  }

  @override
  Future<Map<String, dynamic>> reorderServers(List<String> orderedIds) async {
    final current = storageService.connections.map((item) => item.id).toList();
    if (orderedIds.length != current.length ||
        orderedIds.toSet().length != orderedIds.length ||
        !current.toSet().containsAll(orderedIds)) {
      throw StateError(
        'orderedIds must contain every saved server id exactly once.',
      );
    }
    for (var targetIndex = 0; targetIndex < orderedIds.length; targetIndex++) {
      final wantedId = orderedIds[targetIndex];
      final currentIndex = storageService.connections.indexWhere(
        (item) => item.id == wantedId,
      );
      if (currentIndex == -1 || currentIndex == targetIndex) continue;
      await storageService.reorderConnections(currentIndex, targetIndex);
    }
    return {
      'reordered': true,
      'orderedIds': orderedIds,
    };
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

  void _validateUpdateKeys(Iterable<Object?> keys) {
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

  String? _readOptionalString(Map<String, dynamic> source, String key) {
    if (!source.containsKey(key)) return null;
    final value = source[key];
    if (value == null) return null;
    if (value is! String) {
      throw StateError('Field $key must be a string.');
    }
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  int? _readOptionalInt(Map<String, dynamic> source, String key) {
    if (!source.containsKey(key)) return null;
    final value = source[key];
    if (value == null) return null;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    throw StateError('Field $key must be an integer.');
  }

  bool? _readOptionalBool(Map<String, dynamic> source, String key) {
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
