// Playbook Package 测试使用的可控 Port 实现。

import 'dart:convert';

import 'package:feature_playbook/feature_playbook.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

/// 使用可识别前缀模拟加解密，验证敏感字段不会以明文写入数据库。
final class FakePlaybookDataProtection implements PlaybookDataProtectionPort {
  int encryptCalls = 0;
  int decryptCalls = 0;

  @override
  Future<String> encryptString(String plaintext) async {
    encryptCalls += 1;
    return 'encrypted:${base64Encode(utf8.encode(plaintext))}';
  }

  @override
  Future<String> decryptString(String value) async {
    decryptCalls += 1;
    return utf8.decode(base64Decode(value.substring('encrypted:'.length)));
  }

  @override
  bool isEncrypted(String value) => value.startsWith('encrypted:');
}

/// 记录日志但不向测试输出内容的 Logger Fake。
final class FakePlaybookLogger implements PlaybookLoggerPort {
  final List<String> infos = [];
  final List<String> warnings = [];
  final List<String> errors = [];

  @override
  void info(String message, {String? details}) {
    infos.add(details == null ? message : '$message: $details');
  }

  @override
  void warning(String message, {String? details}) {
    warnings.add(details == null ? message : '$message: $details');
  }

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {
    errors.add(details == null ? message : '$message: $details');
  }
}

/// 返回固定成功结果并记录绑定目标的 SSH Fake。
final class FakePlaybookSshPort implements PlaybookSshPort {
  final List<String> commands = [];
  final List<ssh_core.SshTargetBinding> bindings = [];

  @override
  Future<ssh_core.RemoteCommandResult> runCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    commands.add('$connectionId:$command');
    return _success;
  }

  @override
  Future<ssh_core.RemoteCommandResult> runCommandForBinding({
    required ssh_core.SshTargetBinding binding,
    required String command,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    bindings.add(binding);
    commands.add('${binding.id}:$command');
    return _success;
  }

  static const _success = ssh_core.RemoteCommandResult(
    exitCode: 0,
    stdout: 'ok',
    stderr: '',
  );
}
