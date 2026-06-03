import 'package:dartssh2/dartssh2.dart';

import '../models/connection.dart';
import 'app_log_service.dart';
import 'storage_service.dart';

class SshCredentials {
  final String? password;
  final String? privateKey;

  const SshCredentials({
    required this.password,
    required this.privateKey,
  });
}

class SshClientFactory {
  final StorageService _storageService;

  const SshClientFactory(this._storageService);

  Future<SshCredentials> loadCredentials(ConnectionConfig config) async {
    final password = await _storageService.getPassword(config.id);
    final privateKey = await _storageService.getPrivateKey(config.id);
    validateAuthSecrets(
      config: config,
      password: password,
      privateKey: privateKey,
    );
    return SshCredentials(password: password, privateKey: privateKey);
  }

  Future<SSHClient> connectClient(
    ConnectionConfig config, {
    Duration timeout = const Duration(seconds: 15),
    SshCredentials? credentials,
  }) async {
    final resolvedCredentials = credentials ?? await loadCredentials(config);
    validateAuthSecrets(
      config: config,
      password: resolvedCredentials.password,
      privateKey: resolvedCredentials.privateKey,
    );
    AppLogService.instance.info(
      'SshClientFactory: connecting socket',
      details:
          'connection=${config.name} host=${config.host}:${config.port} user=${config.username} authMethod=${config.authMethod.name}',
    );
    final socket = await SSHSocket.connect(
      config.host,
      config.port,
      timeout: timeout,
    );

    try {
      return SSHClient(
        socket,
        username: config.username,
        identities: identitiesFor(config, resolvedCredentials),
        onPasswordRequest: () {
          if (config.authMethod == AuthMethod.privateKey) return null;
          return resolvedCredentials.password!;
        },
      );
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'SshClientFactory: client setup failed',
        error: e,
        stackTrace: stackTrace,
        details: 'connection=${config.name}',
      );
      socket.close();
      rethrow;
    }
  }

  List<SSHKeyPair>? identitiesFor(
    ConnectionConfig config,
    SshCredentials credentials,
  ) {
    final shouldUseKey = config.authMethod == AuthMethod.privateKey ||
        config.authMethod == AuthMethod.both;
    if (!shouldUseKey || credentials.privateKey?.isNotEmpty != true) {
      return null;
    }
    return SSHKeyPair.fromPem(credentials.privateKey!, credentials.password);
  }

  static void validateAuthSecrets({
    required ConnectionConfig config,
    required String? password,
    required String? privateKey,
  }) {
    final hasPassword = password?.isNotEmpty == true;
    final hasPrivateKey = privateKey?.isNotEmpty == true;

    StateError missingError(String message) {
      final error = StateError(message);
      AppLogService.instance.add(
        'warning',
        'SshClientFactory: credential validation failed: $message',
        details:
            'connection=${config.name} authMethod=${config.authMethod.name}',
      );
      return error;
    }

    switch (config.authMethod) {
      case AuthMethod.password:
        if (!hasPassword) {
          throw missingError(
            'Password is missing for this connection. Please edit the server '
            'configuration and save the password again on this device.',
          );
        }
        break;
      case AuthMethod.privateKey:
        if (!hasPrivateKey) {
          throw missingError(
            'Private key is missing for this connection. Please edit the '
            'server configuration and save the private key again on this device.',
          );
        }
        break;
      case AuthMethod.both:
        if (!hasPrivateKey || !hasPassword) {
          throw missingError(
            'Password or private key is missing for this connection. Please '
            'edit the server configuration and save both credentials again on '
            'this device.',
          );
        }
        break;
    }
  }
}
