import 'connection_enums.dart';

/// 校验并返回可用于数据库与安全存储绑定的规范 Connection ID。
///
/// ID 不做静默 trim：不同结构记录不能在安全存储层被折叠为同一个目标。
String requireCanonicalConnectionId(String connectionId) {
  if (connectionId.isEmpty || connectionId != connectionId.trim()) {
    throw ArgumentError.value(
      connectionId,
      'connectionId',
      'must be non-empty and have no leading or trailing whitespace',
    );
  }
  return connectionId;
}

/// 不含密码和私钥的 Connection 结构模型。
///
/// 它是 Connection 数据库和跨模块契约的基础类型。字段保持可变是为了兼容
/// 当前应用在 Host Key 信任后就地更新对象的行为；持久化仍由 Repository
/// 负责，不应把这个对象当作数据库句柄或全局状态。
class ConnectionProfile {
  String id;
  String name;
  String host;
  int port;
  String username;
  AuthMethod authMethod;
  int terminalWidth;
  int terminalHeight;
  bool keepAlive;
  int keepAliveInterval;
  TerminalLaunchMode launchMode;
  ServerPlatform serverPlatform;
  int tmuxAutoDeleteSeconds;
  DateTime createdAt;
  DateTime updatedAt;
  String? hostKeyFingerprint;
  String? hostKeyAlgorithm;
  DateTime? hostKeyTrustedAt;
  String? jumpHost;
  int? jumpPort;
  String? jumpUsername;
  String? group;

  /// 创建一个只包含非敏感连接结构的模型。
  ConnectionProfile({
    required String id,
    required this.name,
    required this.host,
    this.port = 22,
    required this.username,
    this.authMethod = AuthMethod.password,
    this.terminalWidth = 80,
    this.terminalHeight = 24,
    this.keepAlive = true,
    this.keepAliveInterval = 3,
    this.launchMode = TerminalLaunchMode.ssh,
    this.serverPlatform = ServerPlatform.linux,
    this.tmuxAutoDeleteSeconds = 600,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.hostKeyFingerprint,
    this.hostKeyAlgorithm,
    this.hostKeyTrustedAt,
    this.jumpHost,
    this.jumpPort,
    this.jumpUsername,
    this.group,
  }) : id = requireCanonicalConnectionId(id),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  /// 将非敏感字段编码为稳定结构；刻意不包含凭据字段。
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'host': host,
      'port': port,
      'username': username,
      'authMethod': authMethod.name,
      'terminalWidth': terminalWidth,
      'terminalHeight': terminalHeight,
      'keepAlive': keepAlive,
      'keepAliveInterval': keepAliveInterval,
      'launchMode': launchMode.name,
      'serverPlatform': serverPlatform.name,
      'tmuxAutoDeleteSeconds': tmuxAutoDeleteSeconds,
      'hostKeyFingerprint': hostKeyFingerprint,
      'hostKeyAlgorithm': hostKeyAlgorithm,
      'hostKeyTrustedAt': hostKeyTrustedAt?.toIso8601String(),
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'jumpHost': jumpHost,
      'jumpPort': jumpPort,
      'jumpUsername': jumpUsername,
      'group': group,
    };
  }

  /// 从非敏感 JSON 恢复配置；未知枚举和缺失字段使用安全默认值。
  factory ConnectionProfile.fromJson(Map<String, dynamic> json) {
    final serverPlatform = ServerPlatform.fromName(
      json['serverPlatform'] as String? ?? json['platform'] as String?,
    );
    final launchMode = TerminalLaunchMode.fromName(
      json['launchMode'] as String?,
    );
    return ConnectionProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      host: json['host'] as String,
      port: (json['port'] as num?)?.toInt() ?? 22,
      username: json['username'] as String,
      authMethod: AuthMethod.fromName(json['authMethod'] as String?),
      terminalWidth: (json['terminalWidth'] as num?)?.toInt() ?? 80,
      terminalHeight: (json['terminalHeight'] as num?)?.toInt() ?? 24,
      keepAlive: json['keepAlive'] as bool? ?? true,
      keepAliveInterval: (json['keepAliveInterval'] as num?)?.toInt() ?? 3,
      launchMode:
          serverPlatform == ServerPlatform.windows &&
              launchMode == TerminalLaunchMode.tmux
          ? TerminalLaunchMode.ssh
          : launchMode,
      serverPlatform: serverPlatform,
      tmuxAutoDeleteSeconds:
          (json['tmuxAutoDeleteSeconds'] as num?)?.toInt() ?? 600,
      hostKeyFingerprint: json['hostKeyFingerprint'] as String?,
      hostKeyAlgorithm: json['hostKeyAlgorithm'] as String?,
      hostKeyTrustedAt: DateTime.tryParse(
        json['hostKeyTrustedAt'] as String? ?? '',
      ),
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      jumpHost: json['jumpHost'] as String?,
      jumpPort: (json['jumpPort'] as num?)?.toInt(),
      jumpUsername: json['jumpUsername'] as String?,
      group: json['group'] as String?,
    );
  }

  /// 按当前应用的兼容规则创建结构副本，并在端点变化时清除 Host Key。
  ConnectionProfile copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    String? username,
    AuthMethod? authMethod,
    int? terminalWidth,
    int? terminalHeight,
    bool? keepAlive,
    int? keepAliveInterval,
    TerminalLaunchMode? launchMode,
    ServerPlatform? serverPlatform,
    int? tmuxAutoDeleteSeconds,
    String? hostKeyFingerprint,
    String? hostKeyAlgorithm,
    DateTime? hostKeyTrustedAt,
    String? jumpHost,
    int? jumpPort,
    String? jumpUsername,
    String? group,
  }) {
    final nextPlatform = serverPlatform ?? this.serverPlatform;
    final nextLaunchMode = launchMode ?? this.launchMode;
    final nextHost = host ?? this.host;
    final nextPort = port ?? this.port;
    final endpointUnchanged = nextHost == this.host && nextPort == this.port;
    return ConnectionProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      host: nextHost,
      port: nextPort,
      username: username ?? this.username,
      authMethod: authMethod ?? this.authMethod,
      terminalWidth: terminalWidth ?? this.terminalWidth,
      terminalHeight: terminalHeight ?? this.terminalHeight,
      keepAlive: keepAlive ?? this.keepAlive,
      keepAliveInterval: keepAliveInterval ?? this.keepAliveInterval,
      launchMode:
          nextPlatform == ServerPlatform.windows &&
              nextLaunchMode == TerminalLaunchMode.tmux
          ? TerminalLaunchMode.ssh
          : nextLaunchMode,
      serverPlatform: nextPlatform,
      tmuxAutoDeleteSeconds:
          tmuxAutoDeleteSeconds ?? this.tmuxAutoDeleteSeconds,
      hostKeyFingerprint:
          hostKeyFingerprint ??
          (endpointUnchanged ? this.hostKeyFingerprint : null),
      hostKeyAlgorithm:
          hostKeyAlgorithm ??
          (endpointUnchanged ? this.hostKeyAlgorithm : null),
      hostKeyTrustedAt:
          hostKeyTrustedAt ??
          (endpointUnchanged ? this.hostKeyTrustedAt : null),
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      jumpHost: jumpHost ?? this.jumpHost,
      jumpPort: jumpPort ?? this.jumpPort,
      jumpUsername: jumpUsername ?? this.jumpUsername,
      group: group ?? this.group,
    );
  }
}

/// 兼容当前应用调用面的运行时连接配置。
///
/// 密码和私钥只存在于内存中的短生命周期对象；[toJson]、Drift 映射和
/// ConnectionTarget 都会排除它们。后续 Feature 迁移完成后，调用方应优先
/// 使用 [ConnectionProfile] 与 [CredentialRepository] 的组合。
class ConnectionConfig extends ConnectionProfile {
  String? password;
  String? privateKey;

  /// 创建带有可选运行时凭据的连接配置。
  ConnectionConfig({
    required super.id,
    required super.name,
    required super.host,
    super.port,
    required super.username,
    this.password,
    this.privateKey,
    super.authMethod,
    super.terminalWidth,
    super.terminalHeight,
    super.keepAlive,
    super.keepAliveInterval,
    super.launchMode,
    super.serverPlatform,
    super.tmuxAutoDeleteSeconds,
    super.createdAt,
    super.updatedAt,
    super.hostKeyFingerprint,
    super.hostKeyAlgorithm,
    super.hostKeyTrustedAt,
    super.jumpHost,
    super.jumpPort,
    super.jumpUsername,
    super.group,
  });

  /// 从非敏感 JSON 恢复配置；凭据字段始终保持为空。
  factory ConnectionConfig.fromJson(Map<String, dynamic> json) {
    final profile = ConnectionProfile.fromJson(json);
    return ConnectionConfig(
      id: profile.id,
      name: profile.name,
      host: profile.host,
      port: profile.port,
      username: profile.username,
      authMethod: profile.authMethod,
      terminalWidth: profile.terminalWidth,
      terminalHeight: profile.terminalHeight,
      keepAlive: profile.keepAlive,
      keepAliveInterval: profile.keepAliveInterval,
      launchMode: profile.launchMode,
      serverPlatform: profile.serverPlatform,
      tmuxAutoDeleteSeconds: profile.tmuxAutoDeleteSeconds,
      createdAt: profile.createdAt,
      updatedAt: profile.updatedAt,
      hostKeyFingerprint: profile.hostKeyFingerprint,
      hostKeyAlgorithm: profile.hostKeyAlgorithm,
      hostKeyTrustedAt: profile.hostKeyTrustedAt,
      jumpHost: profile.jumpHost,
      jumpPort: profile.jumpPort,
      jumpUsername: profile.jumpUsername,
      group: profile.group,
    );
  }

  /// 创建兼容旧调用面的配置副本，同时保留原有凭据回退语义。
  @override
  ConnectionConfig copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    String? username,
    String? password,
    String? privateKey,
    AuthMethod? authMethod,
    int? terminalWidth,
    int? terminalHeight,
    bool? keepAlive,
    int? keepAliveInterval,
    TerminalLaunchMode? launchMode,
    ServerPlatform? serverPlatform,
    int? tmuxAutoDeleteSeconds,
    String? hostKeyFingerprint,
    String? hostKeyAlgorithm,
    DateTime? hostKeyTrustedAt,
    String? jumpHost,
    int? jumpPort,
    String? jumpUsername,
    String? group,
  }) {
    final nextPlatform = serverPlatform ?? this.serverPlatform;
    final nextLaunchMode = launchMode ?? this.launchMode;
    final nextHost = host ?? this.host;
    final nextPort = port ?? this.port;
    final endpointUnchanged = nextHost == this.host && nextPort == this.port;
    return ConnectionConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      host: nextHost,
      port: nextPort,
      username: username ?? this.username,
      password: password ?? this.password,
      privateKey: privateKey ?? this.privateKey,
      authMethod: authMethod ?? this.authMethod,
      terminalWidth: terminalWidth ?? this.terminalWidth,
      terminalHeight: terminalHeight ?? this.terminalHeight,
      keepAlive: keepAlive ?? this.keepAlive,
      keepAliveInterval: keepAliveInterval ?? this.keepAliveInterval,
      launchMode:
          nextPlatform == ServerPlatform.windows &&
              nextLaunchMode == TerminalLaunchMode.tmux
          ? TerminalLaunchMode.ssh
          : nextLaunchMode,
      serverPlatform: nextPlatform,
      tmuxAutoDeleteSeconds:
          tmuxAutoDeleteSeconds ?? this.tmuxAutoDeleteSeconds,
      hostKeyFingerprint:
          hostKeyFingerprint ??
          (endpointUnchanged ? this.hostKeyFingerprint : null),
      hostKeyAlgorithm:
          hostKeyAlgorithm ??
          (endpointUnchanged ? this.hostKeyAlgorithm : null),
      hostKeyTrustedAt:
          hostKeyTrustedAt ??
          (endpointUnchanged ? this.hostKeyTrustedAt : null),
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      jumpHost: jumpHost ?? this.jumpHost,
      jumpPort: jumpPort ?? this.jumpPort,
      jumpUsername: jumpUsername ?? this.jumpUsername,
      group: group ?? this.group,
    );
  }
}
