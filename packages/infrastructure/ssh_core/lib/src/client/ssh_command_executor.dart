// SSH 一次性命令执行器。
//
// AI、诊断和 Playbook 通过该边界执行普通 SSH exec，不复用交互终端或 tmux
// Session；调用方必须自行提供已经经过安全边界解析的 SSHClient。

import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import '../model/ssh_session.dart';

/// 在独立 SSH Client 上执行一条远端命令。
Future<RemoteCommandResult> executeSshCommand({
  required SSHClient client,
  required String command,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final result = await client.runWithResult(command).timeout(timeout);
  return RemoteCommandResult(
    exitCode: result.exitCode,
    stdout: utf8.decode(result.stdout, allowMalformed: true),
    stderr: utf8.decode(result.stderr, allowMalformed: true),
  );
}
