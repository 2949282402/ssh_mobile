// SSH Host Key 校验策略。
//
// 首次信任必须经过 UI 提示，已信任指纹或算法变化必须拒绝连接。持久化由
// 注入的 HostKeyRepository 完成，策略本身不依赖 App Shell 存储实现。

import 'dart:async';
import 'dart:typed_data';

import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart';
import 'package:dartssh2/dartssh2.dart';

/// 未知 Host Key 的用户确认回调。
typedef SshHostKeyConfirmation =
    FutureOr<bool> Function(SshHostKeyPromptRequest request);

/// Host Key 信任持久化回调。
typedef SshHostKeyTrustPersister =
    Future<void> Function(ConnectionConfig config);

/// 提示 UI 所需的非敏感 Host Key 信息。
final class SshHostKeyPromptRequest {
  /// 创建 Host Key 提示数据。
  const SshHostKeyPromptRequest({
    required this.connectionId,
    required this.connectionName,
    required this.host,
    required this.port,
    required this.username,
    required this.algorithm,
    required this.fingerprint,
  });

  final String connectionId;
  final String connectionName;
  final String host;
  final int port;
  final String username;
  final String algorithm;
  final String fingerprint;
}

/// SSH Host Key TOFU/固定指纹校验器。
final class SshHostKeyPolicy {
  /// 创建校验策略。
  SshHostKeyPolicy({
    required this.logger,
    this.onUnknownHostKey,
    this.persistTrust,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AppLogger logger;
  final DateTime Function() _now;

  /// 未知 Host Key 的确认回调。
  final SshHostKeyConfirmation? onUnknownHostKey;

  /// 用户确认后的持久化回调。
  final SshHostKeyTrustPersister? persistTrust;

  /// 校验服务端 Host Key，并在首次确认后更新配置快照。
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
      if (trustedFingerprint == fingerprint && algorithmMatches) return true;
      _log(
        LogLevel.warning,
        'SSH host key verification blocked changed fingerprint',
        details:
            'connection=${config.name} host=${config.host}:${config.port} '
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
      _log(
        LogLevel.warning,
        'SSH host key verification blocked untrusted host',
        details:
            'connection=${config.name} host=${config.host}:${config.port} '
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
    _log(
      LogLevel.info,
      'SSH host key trusted',
      details:
          'connection=${config.name} host=${config.host}:${config.port} '
          'algorithm=$algorithm',
    );
    return true;
  }

  /// 将 dartssh2 的 MD5 字节指纹转换为稳定显示格式。
  static String formatMd5Fingerprint(Uint8List fingerprint) {
    return 'MD5:${fingerprint.map(_hexByte).join(':')}';
  }

  /// 规范化历史数据中的 MD5 指纹，兼容有无前缀和冒号格式。
  static String? normalizeFingerprint(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    var normalized = trimmed.toLowerCase();
    if (normalized.startsWith('md5:')) normalized = normalized.substring(4);
    normalized = normalized.replaceAll(':', '');
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(normalized)) return trimmed;
    final parts = <String>[];
    for (var i = 0; i < normalized.length; i += 2) {
      parts.add(normalized.substring(i, i + 2));
    }
    return 'MD5:${parts.join(':')}';
  }

  void _log(LogLevel level, String message, {String? details}) {
    logger.log(
      LogRecord(
        timestamp: DateTime.now(),
        level: level,
        source: 'ssh_core',
        message: message,
        details: details,
      ),
    );
  }

  static String _hexByte(int value) => value.toRadixString(16).padLeft(2, '0');

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}

/// Host Key 未被信任时的异常。
final class SshHostKeyUntrustedException implements Exception, SSHError {
  const SshHostKeyUntrustedException({
    required this.connectionName,
    required this.host,
    required this.port,
    required this.algorithm,
    required this.fingerprint,
  });

  final String connectionName;
  final String host;
  final int port;
  final String algorithm;
  final String fingerprint;

  @override
  String toString() =>
      'Untrusted SSH host key for $connectionName ($host:$port). '
      'Confirm the host key before connecting. '
      'Algorithm: $algorithm, fingerprint: $fingerprint';
}

/// 用户拒绝 Host Key 时的异常。
final class SshHostKeyRejectedException implements Exception, SSHError {
  const SshHostKeyRejectedException({
    required this.connectionName,
    required this.host,
    required this.port,
    required this.algorithm,
    required this.fingerprint,
  });

  final String connectionName;
  final String host;
  final int port;
  final String algorithm;
  final String fingerprint;

  @override
  String toString() =>
      'SSH host key was not trusted for $connectionName ($host:$port). '
      'Algorithm: $algorithm, fingerprint: $fingerprint';
}

/// Host Key 指纹或算法变化时的异常。
final class SshHostKeyMismatchException implements Exception, SSHError {
  const SshHostKeyMismatchException({
    required this.connectionName,
    required this.host,
    required this.port,
    required this.expectedAlgorithm,
    required this.expectedFingerprint,
    required this.actualAlgorithm,
    required this.actualFingerprint,
  });

  final String connectionName;
  final String host;
  final int port;
  final String? expectedAlgorithm;
  final String expectedFingerprint;
  final String actualAlgorithm;
  final String actualFingerprint;

  @override
  String toString() =>
      'SSH host key changed for $connectionName ($host:$port). '
      'Expected ${expectedAlgorithm ?? 'unknown'} $expectedFingerprint, '
      'got $actualAlgorithm $actualFingerprint. Connection blocked.';
}
