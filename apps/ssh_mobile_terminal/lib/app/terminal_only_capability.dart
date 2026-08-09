// Terminal-only App 的 SSH 能力占位实现。
//
// 该 App 是用于验证依赖裁剪的独立编译切片，真实 SSH 连接仍由 Full App
// 的 App Shell 注入。这里保留完整公开 Capability 的安全空实现，确保
// Terminal 页面在没有连接配置时仍能展示空状态，而不是创建第二套 SSH Owner。

import 'dart:async';

import 'package:ssh_core/ssh_core.dart';

/// 不创建网络连接的 Terminal Capability。
final class TerminalOnlyCapability implements SshTerminalCapability {
  /// 创建一个空的终端能力快照。
  TerminalOnlyCapability();

  final StreamController<void> _changes = StreamController<void>.broadcast();
  bool _closed = false;

  /// 该切片未装配真实 SSH Runtime，因此不会创建会话。
  static const String unavailableMessage =
      'The Terminal-only build slice does not configure a server session.';

  @override
  Stream<void> get changes => _changes.stream;

  @override
  List<SshTerminalSession> get sessions => const [];

  @override
  SshTerminalSession? getSession(String sessionId) => null;

  @override
  String? get errorMessage => unavailableMessage;

  @override
  Future<String> loadSessionHistoryText(String sessionId) async => '';

  @override
  Future<bool> ensureSessionConnected(
    String sessionId,
    String connectionId,
  ) async => false;

  @override
  void setSessionFontSize(String sessionId, double fontSize) {}

  @override
  void sendData(String sessionId, String data) {}

  @override
  void resizeTerminal(String sessionId, int width, int height) {}

  @override
  Future<void> disconnectSession(String sessionId) async {}

  @override
  Future<void> disconnect() async {}

  @override
  bool isSessionNameAvailable(String name) => name.trim().isNotEmpty;

  @override
  bool renameSession(String sessionId, String name) => false;

  @override
  Future<String?> openSession(
    String connectionId, {
    String? displayName,
  }) async {
    _emitChange();
    return null;
  }

  @override
  Future<bool> ensureConnected(String connectionId) async => false;

  /// 释放 Capability 的通知流；Owner 在 Runtime 关闭时调用。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _changes.close();
  }

  void _emitChange() {
    if (!_closed) _changes.add(null);
  }
}
