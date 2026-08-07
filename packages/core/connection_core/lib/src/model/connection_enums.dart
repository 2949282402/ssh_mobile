/// Connection 领域使用的认证方式。
enum AuthMethod {
  password,
  privateKey,
  both;

  /// 返回用于数据库和协议边界的稳定名称。
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

  /// 返回设置页面使用的英文显示名称。
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

  /// 从持久化名称恢复认证方式；未知值安全回退到密码认证。
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

/// 远端服务器的平台类型，影响命令和终端启动策略。
enum ServerPlatform {
  linux,
  windows;

  /// 返回用于数据库和协议边界的稳定名称。
  String get name {
    switch (this) {
      case ServerPlatform.linux:
        return 'linux';
      case ServerPlatform.windows:
        return 'windows';
    }
  }

  /// 返回设置页面使用的英文显示名称。
  String get displayName {
    switch (this) {
      case ServerPlatform.linux:
        return 'Linux';
      case ServerPlatform.windows:
        return 'Windows';
    }
  }

  /// 从历史名称恢复平台；未知值安全回退到 Linux。
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

/// 终端启动模式。
enum TerminalLaunchMode {
  ssh,
  tmux;

  /// 返回用于数据库和协议边界的稳定名称。
  String get name {
    switch (this) {
      case TerminalLaunchMode.ssh:
        return 'ssh';
      case TerminalLaunchMode.tmux:
        return 'tmux';
    }
  }

  /// 返回设置页面使用的英文显示名称。
  String get displayName {
    switch (this) {
      case TerminalLaunchMode.ssh:
        return 'SSH';
      case TerminalLaunchMode.tmux:
        return 'SSH + tmux';
    }
  }

  /// 从持久化名称恢复模式；未知值安全回退到普通 SSH。
  static TerminalLaunchMode fromName(String? name) {
    switch (name) {
      case 'tmux':
        return TerminalLaunchMode.tmux;
      default:
        return TerminalLaunchMode.ssh;
    }
  }
}
