// SSH Terminal Capability 的跨模块公共合约。
//
// Terminal Feature 只依赖 SshSessionManager 及其公开 Capability，不直接
// 依赖 SshService、Background Service 或旧 App 存储实现。具体实现仍由
// App Scope 的 SSH Owner 提供，以避免在页面或 Feature 内重复创建连接。

import '../model/ssh_session.dart';

/// Terminal 使用的 SSH 会话能力。
///
/// 该接口只描述终端需要的操作；连接创建、Host Key 校验、平台 Runtime
/// 和 Session 生命周期仍由 [SshSessionManager] 的 App Scope 实现负责。
abstract interface class SshTerminalCapability {
  /// 会话状态或列表发生变化时发出的通知流。
  Stream<void> get changes;

  /// 当前所有终端窗口的只读快照。
  List<SshTerminalSession> get sessions;

  /// 按会话 ID 查找当前终端窗口快照。
  SshTerminalSession? getSession(String sessionId);

  /// 最近一次 Manager 级错误，不包含凭据。
  String? get errorMessage;

  /// 读取指定会话的有界历史输出。
  Future<String> loadSessionHistoryText(String sessionId);

  /// 重新连接已有会话。
  Future<bool> ensureSessionConnected(String sessionId, String connectionId);

  /// 更新终端字号并持久化会话元数据。
  void setSessionFontSize(String sessionId, double fontSize);

  /// 向指定交互会话发送文本。
  void sendData(String sessionId, String data);

  /// 更新远端终端尺寸。
  void resizeTerminal(String sessionId, int width, int height);

  /// 关闭一个终端窗口。
  Future<void> disconnectSession(String sessionId);

  /// 关闭全部终端窗口。
  Future<void> disconnect();

  /// 判断窗口名称是否可用。
  bool isSessionNameAvailable(String name);

  /// 重命名已有窗口；名称冲突或窗口不存在时返回 false。
  bool renameSession(String sessionId, String name);

  /// 打开一个新的终端会话。
  Future<String?> openSession(String connectionId, {String? displayName});

  /// 确保指定连接至少存在一个可用会话。
  Future<bool> ensureConnected(String connectionId);
}

/// Terminal UI 使用的 SSH 会话元数据和输出流快照。
///
/// 它不暴露底层 Socket 或关闭句柄；关闭操作必须回到
/// [SshTerminalCapability.disconnectSession]，避免 Feature 误关共享连接。
final class SshTerminalSession {
  /// 创建终端会话快照。
  const SshTerminalSession({
    required this.id,
    required this.connectionId,
    required this.connectionName,
    required this.displayName,
    required this.tmuxSessionName,
    required this.tmuxAutoDeleteSeconds,
    required this.fontSize,
    required this.state,
    required this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
    required this.output,
    required this.outputText,
    required this.estimatedMemoryBytes,
  });

  /// 稳定的本地会话 ID。
  final String id;

  /// 关联的连接配置 ID。
  final String connectionId;

  /// 创建会话时的连接名称快照。
  final String connectionName;

  /// 用户可见的窗口名称。
  final String displayName;

  /// tmux 会话名称；普通 SSH 会话为空。
  final String? tmuxSessionName;

  /// tmux 无人连接后的自动销毁秒数。
  final int? tmuxAutoDeleteSeconds;

  /// 当前终端字号。
  final double fontSize;

  /// 当前连接状态。
  final SshConnectionState state;

  /// 最近一次非敏感错误信息。
  final String? errorMessage;

  /// 会话创建时间。
  final DateTime createdAt;

  /// 会话元数据更新时间。
  final DateTime updatedAt;

  /// 远端输出流；流的关闭由 SSH Owner 管理。
  final Stream<String> output;

  /// 当前有界输出缓存。
  final String outputText;

  /// 输出缓存的估算内存占用。
  final int estimatedMemoryBytes;

  /// 当前是否已连接。
  bool get isConnected => state == SshConnectionState.connected;

  /// 生成安全的 tmux 删除命令。
  String? get tmuxKillCommand {
    final name = tmuxSessionName;
    if (name == null || name.isEmpty) return null;
    return "tmux kill-session -t ${_shellQuote(name)}";
  }

  static String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }
}
