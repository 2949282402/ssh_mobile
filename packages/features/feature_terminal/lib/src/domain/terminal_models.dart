// Terminal 领域模型；只保存窗口和历史元数据，不保存密码、私钥或原始输出。

/// 可恢复 tmux 会话的元数据快照。
final class RestorableTerminalSession {
  /// 创建可恢复会话记录。
  const RestorableTerminalSession({
    required this.sessionId,
    required this.connectionId,
    required this.displayName,
    required this.tmuxSessionName,
    required this.fontSize,
    required this.updatedAt,
  });

  final String sessionId;
  final String connectionId;
  final String displayName;
  final String tmuxSessionName;
  final double fontSize;
  final DateTime updatedAt;
}

/// 终端窗口历史记录；只存储可展示的连接/状态元数据。
final class TerminalHistoryRecord {
  /// 创建终端历史记录。
  const TerminalHistoryRecord({
    required this.sessionId,
    required this.connectionId,
    required this.connectionName,
    required this.displayName,
    required this.tmuxSessionName,
    required this.state,
    required this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
  });

  final String sessionId;
  final String connectionId;
  final String connectionName;
  final String displayName;
  final String? tmuxSessionName;
  final String state;
  final String? errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 生成安全的 tmux 清理命令，供用户明确复制执行。
  String? get tmuxKillCommand {
    final name = tmuxSessionName;
    if (name == null || name.isEmpty) return null;
    return "tmux kill-session -t ${_shellQuote(name)}";
  }

  static String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }
}
