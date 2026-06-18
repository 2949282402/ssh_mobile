import 'dart:async';
import 'dart:typed_data';

import '../../features/connection/models/connection.dart';
import '../../services/app_log_service.dart';

typedef SshHostKeyConfirmation = FutureOr<bool> Function(
  SshHostKeyPromptRequest request,
);

typedef SshHostKeyTrustPersister = Future<void> Function(
  ConnectionConfig config,
);

class SshHostKeyPromptRequest {
  final String connectionId;
  final String connectionName;
  final String host;
  final int port;
  final String username;
  final String algorithm;
  final String fingerprint;

  const SshHostKeyPromptRequest({
    required this.connectionId,
    required this.connectionName,
    required this.host,
    required this.port,
    required this.username,
    required this.algorithm,
    required this.fingerprint,
  });
}

class SshHostKeyPolicy {
  final SshHostKeyConfirmation? onUnknownHostKey;
  final SshHostKeyTrustPersister? persistTrust;
  final DateTime Function() _now;

  SshHostKeyPolicy({
    this.onUnknownHostKey,
    this.persistTrust,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  Future<bool> verifyHostKey({
    required ConnectionConfig config,
    required String algorithm,
    required Uint8List md5Fingerprint,
  }) async {
    final fingerprint = formatMd5Fingerprint(md5Fingerprint);
    final trustedFingerprint = normalizeFingerprint(config.hostKeyFingerprint);
    final trustedAlgorithm = _nonEmpty(config.hostKeyAlgorithm);

    if (trustedFingerprint != null) {
      final algorithmMatches =
          trustedAlgorithm == null || trustedAlgorithm == algorithm;
      if (trustedFingerprint == fingerprint && algorithmMatches) {
        return true;
      }

      AppLogService.instance.warning(
        'SSH host key verification blocked changed fingerprint',
        details: 'connection=${config.name} host=${config.host}:${config.port} '
            'algorithm=$algorithm trustedAlgorithm=$trustedAlgorithm',
      );
      throw SshHostKeyMismatchException(
        connectionName: config.name,
        host: config.host,
        port: config.port,
        expectedAlgorithm: trustedAlgorithm,
        expectedFingerprint: trustedFingerprint,
        actualAlgorithm: algorithm,
        actualFingerprint: fingerprint,
      );
    }

    final confirm = onUnknownHostKey;
    if (confirm == null) {
      AppLogService.instance.warning(
        'SSH host key verification blocked untrusted host',
        details: 'connection=${config.name} host=${config.host}:${config.port} '
            'algorithm=$algorithm',
      );
      throw SshHostKeyUntrustedException(
        connectionName: config.name,
        host: config.host,
        port: config.port,
        algorithm: algorithm,
        fingerprint: fingerprint,
      );
    }

    final accepted = await confirm(
      SshHostKeyPromptRequest(
        connectionId: config.id,
        connectionName: config.name,
        host: config.host,
        port: config.port,
        username: config.username,
        algorithm: algorithm,
        fingerprint: fingerprint,
      ),
    );
    if (!accepted) {
      throw SshHostKeyRejectedException(
        connectionName: config.name,
        host: config.host,
        port: config.port,
        algorithm: algorithm,
        fingerprint: fingerprint,
      );
    }

    config.hostKeyAlgorithm = algorithm;
    config.hostKeyFingerprint = fingerprint;
    config.hostKeyTrustedAt = _now().toUtc();
    await persistTrust?.call(config);
    AppLogService.instance.info(
      'SSH host key trusted',
      details: 'connection=${config.name} host=${config.host}:${config.port} '
          'algorithm=$algorithm',
    );
    return true;
  }

  static String formatMd5Fingerprint(Uint8List fingerprint) {
    return 'MD5:${fingerprint.map(_hexByte).join(':')}';
  }

  static String? normalizeFingerprint(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    var normalized = trimmed.toLowerCase();
    if (normalized.startsWith('md5:')) {
      normalized = normalized.substring(4);
    }
    normalized = normalized.replaceAll(':', '');
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(normalized)) {
      return trimmed;
    }
    final parts = <String>[];
    for (var i = 0; i < normalized.length; i += 2) {
      parts.add(normalized.substring(i, i + 2));
    }
    return 'MD5:${parts.join(':')}';
  }

  static String _hexByte(int value) => value.toRadixString(16).padLeft(2, '0');

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}

class SshHostKeyUntrustedException implements Exception {
  final String connectionName;
  final String host;
  final int port;
  final String algorithm;
  final String fingerprint;

  const SshHostKeyUntrustedException({
    required this.connectionName,
    required this.host,
    required this.port,
    required this.algorithm,
    required this.fingerprint,
  });

  @override
  String toString() {
    return 'Untrusted SSH host key for $connectionName ($host:$port). '
        'Confirm the host key before connecting. '
        'Algorithm: $algorithm, fingerprint: $fingerprint';
  }
}

class SshHostKeyRejectedException implements Exception {
  final String connectionName;
  final String host;
  final int port;
  final String algorithm;
  final String fingerprint;

  const SshHostKeyRejectedException({
    required this.connectionName,
    required this.host,
    required this.port,
    required this.algorithm,
    required this.fingerprint,
  });

  @override
  String toString() {
    return 'SSH host key was not trusted for $connectionName ($host:$port). '
        'Algorithm: $algorithm, fingerprint: $fingerprint';
  }
}

class SshHostKeyMismatchException implements Exception {
  final String connectionName;
  final String host;
  final int port;
  final String? expectedAlgorithm;
  final String expectedFingerprint;
  final String actualAlgorithm;
  final String actualFingerprint;

  const SshHostKeyMismatchException({
    required this.connectionName,
    required this.host,
    required this.port,
    required this.expectedAlgorithm,
    required this.expectedFingerprint,
    required this.actualAlgorithm,
    required this.actualFingerprint,
  });

  @override
  String toString() {
    return 'SSH host key changed for $connectionName ($host:$port). '
        'Expected ${expectedAlgorithm ?? 'unknown'} $expectedFingerprint, '
        'got $actualAlgorithm $actualFingerprint. Connection blocked.';
  }
}
