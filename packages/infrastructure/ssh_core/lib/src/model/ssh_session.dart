// SSH 交互会话模型。
//
// 该模型只保存会话元数据和有界输出缓存；真正的 Socket、Shell、Timer 与
// Subscription 由 Runtime/Session Pool 持有，Feature 只能通过 Lease 使用。

import 'dart:async';
import 'dart:collection';

/// SSH 会话生命周期状态。
enum SshConnectionState {
  /// 尚未建立连接。
  disconnected,

  /// 正在建立连接。
  connecting,

  /// 已建立交互连接。
  connected,

  /// 连接或重连失败。
  error,
}

/// SSH 远端命令的解码结果。
final class RemoteCommandResult {
  /// 创建命令结果。
  const RemoteCommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  /// 远端退出码；连接异常时可能为空。
  final int? exitCode;

  /// UTF-8 解码后的标准输出。
  final String stdout;

  /// UTF-8 解码后的标准错误。
  final String stderr;
}

/// 由 Session Manager 共享的交互式 SSH 会话。
final class SshSession {
  /// 输出缓存上限，防止长期会话无限增长内存。
  static const int maxOutputCacheChars = 200000;

  /// 默认终端字号。
  static const double defaultTerminalFontSize = 8.0;

  /// 允许的最小终端字号。
  static const double minTerminalFontSize = 4.0;

  /// 允许的最大终端字号。
  static const double maxTerminalFontSize = 28.0;

  /// 创建一个由 Session Pool 管理的会话。
  SshSession({
    required this.id,
    required this.connectionId,
    required this.connectionName,
    String? displayName,
    this.tmuxSessionName,
    this.tmuxAutoDeleteSeconds,
    this.fontSize = defaultTerminalFontSize,
    StreamController<String>? outputController,
    this.state = SshConnectionState.connecting,
    this.errorMessage,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : displayName = displayName ?? connectionName,
       outputController =
           outputController ?? StreamController<String>.broadcast(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  /// 稳定的本地会话 id。
  final String id;

  /// 关联的连接配置 id。
  final String connectionId;

  /// 创建会话时的连接名称快照。
  final String connectionName;

  /// 向消费者广播远端输出的控制器；关闭由 Pool 负责。
  final StreamController<String> outputController;

  final Queue<String> _outputChunks = Queue<String>();
  String? _cachedOutputText;
  int _outputCharCount = 0;
  bool _closed = false;

  /// 用户可见的窗口名称。
  String displayName;

  /// tmux 会话名称；普通 SSH 会话为空。
  String? tmuxSessionName;

  /// tmux 空闲自动回收秒数。
  int? tmuxAutoDeleteSeconds;

  /// 当前终端字号。
  double fontSize;

  /// 当前连接状态。
  SshConnectionState state;

  /// 最近一次错误信息。
  String? errorMessage;

  /// 会话创建时间。
  DateTime createdAt;

  /// 最近一次元数据更新时间。
  DateTime updatedAt;

  /// 远端输出流。
  Stream<String> get output => outputController.stream;

  /// 当前是否已连接。
  bool get isConnected => state == SshConnectionState.connected;

  /// 有界输出缓存文本。
  String get outputText => _cachedOutputText ??= _outputChunks.join();

  /// 估算输出缓存占用的 UTF-16 字节数。
  int get estimatedMemoryBytes => _outputCharCount * 2;

  /// 生成安全的 tmux 删除命令。
  String? get tmuxKillCommand {
    final name = tmuxSessionName;
    if (name == null || name.isEmpty) return null;
    return "tmux kill-session -t ${_shellQuote(name)}";
  }

  /// 追加输出并同步更新有界缓存。
  void addOutput(String data) {
    if (_closed || data.isEmpty) return;
    if (data.length >= maxOutputCacheChars) {
      _outputChunks
        ..clear()
        ..add(data.substring(data.length - maxOutputCacheChars));
      _outputCharCount = maxOutputCacheChars;
    } else {
      _outputChunks.add(data);
      _outputCharCount += data.length;
      while (_outputCharCount > maxOutputCacheChars &&
          _outputChunks.isNotEmpty) {
        final overflow = _outputCharCount - maxOutputCacheChars;
        final first = _outputChunks.removeFirst();
        if (first.length <= overflow) {
          _outputCharCount -= first.length;
        } else {
          _outputChunks.addFirst(first.substring(overflow));
          _outputCharCount -= overflow;
          break;
        }
      }
    }
    _cachedOutputText = null;
    outputController.add(data);
  }

  /// 由 Session Pool 调用，关闭输出流并释放会话缓存。
  ///
  /// Feature 不应直接调用此方法；共享会话必须通过 [SshSessionLease.release]
  /// 交还给 Pool，由 Pool 在 idle timeout 后统一关闭。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _outputChunks.clear();
    _cachedOutputText = null;
    await outputController.close();
  }

  static String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }
}
