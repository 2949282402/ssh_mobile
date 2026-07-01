class ConnectionConfig {
  final String id;
  String name;
  String host;
  int port;
  String username;
  String? password;
  String? privateKey;
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
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

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

  factory ConnectionConfig.fromJson(Map<String, dynamic> json) {
    final serverPlatform = ServerPlatform.fromName(
      json['serverPlatform'] as String? ?? json['platform'] as String?,
    );
    final launchMode = TerminalLaunchMode.fromName(
      json['launchMode'] as String?,
    );
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
      keepAliveInterval: (json['keepAliveInterval'] as num?)?.toInt() ?? 3,
      launchMode: serverPlatform == ServerPlatform.windows &&
              launchMode == TerminalLaunchMode.tmux
          ? TerminalLaunchMode.ssh
          : launchMode,
      serverPlatform: serverPlatform,
      tmuxAutoDeleteSeconds:
          (json['tmuxAutoDeleteSeconds'] as num?)?.toInt() ?? 600,
      hostKeyFingerprint: json['hostKeyFingerprint'] as String?,
      hostKeyAlgorithm: json['hostKeyAlgorithm'] as String?,
      hostKeyTrustedAt:
          DateTime.tryParse(json['hostKeyTrustedAt'] as String? ?? ''),
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
      launchMode: nextPlatform == ServerPlatform.windows &&
              nextLaunchMode == TerminalLaunchMode.tmux
          ? TerminalLaunchMode.ssh
          : nextLaunchMode,
      serverPlatform: nextPlatform,
      tmuxAutoDeleteSeconds:
          tmuxAutoDeleteSeconds ?? this.tmuxAutoDeleteSeconds,
      hostKeyFingerprint: hostKeyFingerprint ??
          (endpointUnchanged ? this.hostKeyFingerprint : null),
      hostKeyAlgorithm: hostKeyAlgorithm ??
          (endpointUnchanged ? this.hostKeyAlgorithm : null),
      hostKeyTrustedAt: hostKeyTrustedAt ??
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

enum ServerPlatform {
  linux,
  windows;

  String get name {
    switch (this) {
      case ServerPlatform.linux:
        return 'linux';
      case ServerPlatform.windows:
        return 'windows';
    }
  }

  String get displayName {
    switch (this) {
      case ServerPlatform.linux:
        return 'Linux';
      case ServerPlatform.windows:
        return 'Windows';
    }
  }

  static ServerPlatform fromName(String? name) {
    switch (name?.toLowerCase()) {
      case 'windows':
      case 'win':
        return ServerPlatform.windows;
      default:
        return ServerPlatform.linux;
    }
  }
}

enum TerminalLaunchMode {
  ssh,
  tmux;

  String get name {
    switch (this) {
      case TerminalLaunchMode.ssh:
        return 'ssh';
      case TerminalLaunchMode.tmux:
        return 'tmux';
    }
  }

  String get displayName {
    switch (this) {
      case TerminalLaunchMode.ssh:
        return 'SSH';
      case TerminalLaunchMode.tmux:
        return 'SSH + tmux';
    }
  }

  static TerminalLaunchMode fromName(String? name) {
    switch (name) {
      case 'tmux':
        return TerminalLaunchMode.tmux;
      default:
        return TerminalLaunchMode.ssh;
    }
  }
}

enum AuthMethod {
  password,
  privateKey,
  both;

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
        return 'Password';
      case AuthMethod.privateKey:
        return 'Private key';
      case AuthMethod.both:
        return 'Private key + password';
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
