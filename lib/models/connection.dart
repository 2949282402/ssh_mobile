import 'dart:convert';

/// SSH 连接配置模型
class ConnectionConfig {
  final String id;
  String name;
  String host;
  int port;
  String username;
  String? password; // 仅内存中，不持久化明文
  String? privateKey; // 私钥内容
  AuthMethod authMethod; // 认证方式
  int terminalWidth;
  int terminalHeight;
  bool keepAlive; // 是否保持后台连接
  int keepAliveInterval; // 心跳间隔（秒）
  DateTime createdAt;
  DateTime updatedAt;
  String? jumpHost; // 跳板机
  int? jumpPort;
  String? jumpUsername;
  String? group; // 分组

  ConnectionConfig({
    required this.id,
    required this.name,
    required this.host,
    this.port = 22,
    required this.username,
    this.password,
    this.privateKey,
    this.authMethod = AuthMethod.password,
    this.terminalWidth = 80,
    this.terminalHeight = 24,
    this.keepAlive = true,
    this.keepAliveInterval = 30,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.jumpHost,
    this.jumpPort,
    this.jumpUsername,
    this.group,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'host': host,
      'port': port,
      'username': username,
      // 密码不序列化到普通 JSON，单独存安全存储
      'authMethod': authMethod.name,
      'terminalWidth': terminalWidth,
      'terminalHeight': terminalHeight,
      'keepAlive': keepAlive,
      'keepAliveInterval': keepAliveInterval,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'jumpHost': jumpHost,
      'jumpPort': jumpPort,
      'jumpUsername': jumpUsername,
      'group': group,
    };
  }

  factory ConnectionConfig.fromJson(Map<String, dynamic> json) {
    return ConnectionConfig(
      id: json['id'] as String,
      name: json['name'] as String,
      host: json['host'] as String,
      port: (json['port'] as num?)?.toInt() ?? 22,
      username: json['username'] as String,
      authMethod: AuthMethod.fromName(json['authMethod'] as String?),
      terminalWidth: (json['terminalWidth'] as num?)?.toInt() ?? 80,
      terminalHeight: (json['terminalHeight'] as num?)?.toInt() ?? 24,
      keepAlive: json['keepAlive'] as bool? ?? true,
      keepAliveInterval:
          (json['keepAliveInterval'] as num?)?.toInt() ?? 30,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      jumpHost: json['jumpHost'] as String?,
      jumpPort: (json['jumpPort'] as num?)?.toInt(),
      jumpUsername: json['jumpUsername'] as String?,
      group: json['group'] as String?,
    );
  }

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
    String? jumpHost,
    int? jumpPort,
    String? jumpUsername,
    String? group,
  }) {
    return ConnectionConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      password: password ?? this.password,
      privateKey: privateKey ?? this.privateKey,
      authMethod: authMethod ?? this.authMethod,
      terminalWidth: terminalWidth ?? this.terminalWidth,
      terminalHeight: terminalHeight ?? this.terminalHeight,
      keepAlive: keepAlive ?? this.keepAlive,
      keepAliveInterval: keepAliveInterval ?? this.keepAliveInterval,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      jumpHost: jumpHost ?? this.jumpHost,
      jumpPort: jumpPort ?? this.jumpPort,
      jumpUsername: jumpUsername ?? this.jumpUsername,
      group: group ?? this.group,
    );
  }
}

/// 认证方式
enum AuthMethod {
  password, // 密码
  privateKey, // 私钥
  both, // 私钥 + 密码（私钥带密码保护）

  String get name {
    switch (this) {
      case AuthMethod.password:
        return 'password';
      case AuthMethod.privateKey:
        return 'privateKey';
      case AuthMethod.both:
        return 'both';
    }
  }

  String get displayName {
    switch (this) {
      case AuthMethod.password:
        return '密码认证';
      case AuthMethod.privateKey:
        return '私钥认证';
      case AuthMethod.both:
        return '私钥+密码';
    }
  }

  static AuthMethod fromName(String? name) {
    switch (name) {
      case 'privateKey':
        return AuthMethod.privateKey;
      case 'both':
        return AuthMethod.both;
      default:
        return AuthMethod.password;
    }
  }
}
