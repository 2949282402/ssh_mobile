// SSH 远端目标绑定模型。
//
// Binding 只保存不可变的路由和认证策略快照；密码、私钥等 secret 只能存在于
// [SshRuntimeTarget] 的短生命周期内，不能序列化、日志记录或放入聊天状态。

import 'dart:convert';

import 'package:connection_core/connection_core.dart';

import 'ssh_credentials.dart';

/// 一次远端操作允许使用的非敏感目标快照。
final class SshTargetBinding {
  /// 从 Connection 配置复制绑定。
  factory SshTargetBinding.fromConfig(ConnectionConfig config) {
    final snapshot = _cloneConfig(config);
    final fingerprint = _normalizeFingerprint(snapshot.hostKeyFingerprint);
    final jumpHost = _normalizeHost(snapshot.jumpHost);
    return SshTargetBinding._(
      snapshot.id,
      snapshot.host.trim().toLowerCase(),
      snapshot.port,
      snapshot.username,
      snapshot.authMethod,
      snapshot.serverPlatform,
      snapshot.launchMode,
      snapshot.tmuxAutoDeleteSeconds,
      fingerprint,
      fingerprint == null
          ? null
          : _normalizeOptionalLower(snapshot.hostKeyAlgorithm),
      jumpHost,
      jumpHost == null ? null : snapshot.jumpPort,
      jumpHost == null ? null : snapshot.jumpUsername,
      snapshot,
    );
  }

  SshTargetBinding._(
    this.id,
    this.host,
    this.port,
    this.username,
    this.authMethod,
    this.serverPlatform,
    this.launchMode,
    this.tmuxAutoDeleteSeconds,
    this.hostKeyFingerprint,
    this.hostKeyAlgorithm,
    this.jumpHost,
    this.jumpPort,
    this.jumpUsername,
    this._snapshot,
  );

  final String id;
  final String host;
  final int port;
  final String username;
  final AuthMethod authMethod;
  final ServerPlatform serverPlatform;
  final TerminalLaunchMode launchMode;
  final int tmuxAutoDeleteSeconds;
  final String? hostKeyFingerprint;
  final String? hostKeyAlgorithm;
  final String? jumpHost;
  final int? jumpPort;
  final String? jumpUsername;
  final ConnectionConfig _snapshot;

  /// 返回不含密码和私钥的新配置副本。
  ConnectionConfig get config => _cloneConfig(_snapshot);

  /// 用于审批快照和审计的稳定非敏感表示。
  String get fingerprint => jsonEncode({
    'id': id,
    'host': host,
    'port': port,
    'username': username,
    'authMethod': authMethod.name,
    'serverPlatform': serverPlatform.name,
    'launchMode': launchMode.name,
    'tmuxAutoDeleteSeconds': tmuxAutoDeleteSeconds,
    'hostKeyFingerprint': hostKeyFingerprint,
    'hostKeyAlgorithm': hostKeyAlgorithm,
    'jumpHost': jumpHost,
    'jumpPort': jumpPort,
    'jumpUsername': jumpUsername,
  });

  /// 判断当前结构是否仍与绑定一致。
  bool matches(ConnectionConfig? candidate) {
    if (candidate == null || candidate.id != id) return false;
    final fingerprint = _normalizeFingerprint(candidate.hostKeyFingerprint);
    final candidateJumpHost = _normalizeHost(candidate.jumpHost);
    return host == candidate.host.trim().toLowerCase() &&
        port == candidate.port &&
        username == candidate.username &&
        authMethod == candidate.authMethod &&
        serverPlatform == candidate.serverPlatform &&
        launchMode == candidate.launchMode &&
        tmuxAutoDeleteSeconds == candidate.tmuxAutoDeleteSeconds &&
        hostKeyFingerprint == fingerprint &&
        hostKeyAlgorithm ==
            (fingerprint == null
                ? null
                : _normalizeOptionalLower(candidate.hostKeyAlgorithm)) &&
        jumpHost == candidateJumpHost &&
        jumpPort == (candidateJumpHost == null ? null : candidate.jumpPort) &&
        jumpUsername ==
            (candidateJumpHost == null ? null : candidate.jumpUsername);
  }

  static ConnectionConfig _cloneConfig(ConnectionConfig source) {
    return ConnectionConfig.fromJson(
      Map<String, dynamic>.from(source.toJson()),
    );
  }

  static String? _normalizeHost(String? value) {
    return _normalizeOptional(value)?.toLowerCase();
  }

  static String? _normalizeOptionalLower(String? value) {
    return _normalizeOptional(value)?.toLowerCase();
  }

  static String? _normalizeOptional(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static String? _normalizeFingerprint(String? value) {
    final trimmed = _normalizeOptional(value);
    if (trimmed == null) return null;
    final compact = trimmed
        .toLowerCase()
        .replaceFirst(RegExp(r'^md5:'), '')
        .replaceAll(':', '');
    if (RegExp(r'^[0-9a-f]{32}$').hasMatch(compact)) {
      return 'md5:$compact';
    }
    return trimmed.toLowerCase();
  }
}

/// 带有短生命周期认证材料的远端目标。
final class SshRuntimeTarget {
  /// 创建并校验目标与绑定的一致性。
  SshRuntimeTarget({
    required this.binding,
    required ConnectionConfig config,
    required this.credentials,
  }) : _configSnapshot = ConnectionConfig.fromJson(
         Map<String, dynamic>.from(config.toJson()),
       ) {
    if (!binding.matches(config)) {
      throw ArgumentError.value(
        config.id,
        'config',
        'Runtime config does not match its target binding.',
      );
    }
  }

  final SshTargetBinding binding;
  final SshCredentials credentials;
  final ConnectionConfig _configSnapshot;

  /// 返回不可变语义上的新配置副本。
  ConnectionConfig get config => ConnectionConfig.fromJson(
    Map<String, dynamic>.from(_configSnapshot.toJson()),
  );
}

/// SSH Core 需要的目标解析契约。
///
/// App 层可以用 ConnectionRepository、CredentialRepository 和 HostKeyRepository
/// 实现该接口，SSH Core 不需要知道 App Shell 存储实现的存在。
abstract interface class SshTargetResolver {
  /// 按审批绑定读取当前配置和安全凭据；目标过期时返回空值。
  Future<SshRuntimeTarget?> resolve(SshTargetBinding binding);

  /// 读取当前非敏感配置，用于区分删除和目标变更。
  ConnectionConfig? getConnection(String connectionId);
}
