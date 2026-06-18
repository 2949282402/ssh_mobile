import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../../features/connection/models/connection.dart';
import '../../services/app_log_service.dart';
import '../../services/storage_service.dart';
import 'ssh_host_key_policy.dart';

class SshCredentials {
  final String? password;
  final String? privateKey;

  const SshCredentials({
    required this.password,
    required this.privateKey,
  });
}

class SshClientAuthOptions {
  final List<SSHKeyPair>? identities;
  final SSHPasswordRequestHandler? onPasswordRequest;
  final SSHUserInfoRequestHandler? onUserInfoRequest;

  const SshClientAuthOptions({
    required this.identities,
    required this.onPasswordRequest,
    required this.onUserInfoRequest,
  });
}

class SshClientFactory {
  final StorageService _storageService;
  static final RegExp _passwordPromptPattern = RegExp(
    r'password|passphrase|pass phrase',
    caseSensitive: false,
  );

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
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    final resolvedCredentials = credentials ?? await loadCredentials(config);
    validateAuthSecrets(
      config: config,
      password: resolvedCredentials.password,
      privateKey: resolvedCredentials.privateKey,
    );
    final identities = await identitiesFor(config, resolvedCredentials);
    final authOptions = buildAuthOptions(
      config: config,
      credentials: resolvedCredentials,
      identities: identities,
    );
    final hostKeyPolicy = SshHostKeyPolicy(
      onUnknownHostKey: onUnknownHostKey,
      persistTrust: _persistTrustedHostKey,
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
        onVerifyHostKey: (algorithm, fingerprint) =>
            hostKeyPolicy.verifyHostKey(
          config: config,
          algorithm: algorithm,
          md5Fingerprint: fingerprint,
        ),
        identities: authOptions.identities,
        onPasswordRequest: authOptions.onPasswordRequest,
        onUserInfoRequest: authOptions.onUserInfoRequest,
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

  Future<void> _persistTrustedHostKey(ConnectionConfig config) {
    return _storageService.trustHostKey(
      config.id,
      algorithm: config.hostKeyAlgorithm,
      fingerprint: config.hostKeyFingerprint,
      trustedAt: config.hostKeyTrustedAt,
    );
  }

  static SshClientAuthOptions buildAuthOptions({
    required ConnectionConfig config,
    required SshCredentials credentials,
    required List<SSHKeyPair>? identities,
  }) {
    final password =
        credentials.password?.isNotEmpty == true ? credentials.password : null;
    final usesPassword = config.authMethod != AuthMethod.privateKey;
    return SshClientAuthOptions(
      identities: identities,
      onPasswordRequest: usesPassword ? () => password : null,
      onUserInfoRequest: usesPassword && password != null
          ? (request) => keyboardInteractiveResponsesForPassword(
                request,
                password,
              )
          : null,
    );
  }

  static List<SSHKeyPair> _parsePemKey(Map<String, String?> args) {
    final pem = args['pem']!;
    final passphrase = args['passphrase'];
    return SSHKeyPair.fromPem(pem, passphrase);
  }

  static Future<List<SSHKeyPair>?> identitiesFor(
    ConnectionConfig config,
    SshCredentials credentials,
  ) async {
    final shouldUseKey = config.authMethod == AuthMethod.privateKey ||
        config.authMethod == AuthMethod.both;
    if (!shouldUseKey || credentials.privateKey?.isNotEmpty != true) {
      return null;
    }
    return compute(_parsePemKey, {
      'pem': credentials.privateKey!,
      'passphrase': credentials.password,
    });
  }

  static List<String>? keyboardInteractiveResponsesForPassword(
    Object request,
    String password,
  ) {
    if (password.isEmpty) return null;
    final prompts = _keyboardInteractivePrompts(request);
    if (prompts.isEmpty) return const [];

    final canAnswer = prompts.every((prompt) {
      final text = prompt.promptText.trim();
      if (prompt.echo) return false;
      if (prompts.length == 1) return true;
      return text.isEmpty || _passwordPromptPattern.hasMatch(text);
    });
    if (!canAnswer) return null;
    return List<String>.filled(prompts.length, password);
  }

  static List<_KeyboardInteractivePrompt> _keyboardInteractivePrompts(
    Object request,
  ) {
    final dynamic dynamicRequest = request;
    final prompts = dynamicRequest.prompts;
    if (prompts is! Iterable) {
      return const [];
    }
    return prompts
        .map<_KeyboardInteractivePrompt?>((prompt) {
          final dynamic dynamicPrompt = prompt;
          final promptText = dynamicPrompt.promptText;
          final echo = dynamicPrompt.echo;
          if (promptText is! String || echo is! bool) {
            return null;
          }
          return _KeyboardInteractivePrompt(
            promptText: promptText,
            echo: echo,
          );
        })
        .whereType<_KeyboardInteractivePrompt>()
        .toList(growable: false);
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

class _KeyboardInteractivePrompt {
  final String promptText;
  final bool echo;

  const _KeyboardInteractivePrompt({
    required this.promptText,
    required this.echo,
  });
}
