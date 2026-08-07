// System Admin 远程命令解析器。
//
// 解析与 SSH 会话/命令编排分离，保持 Service 只负责资源生命周期和业务
// 操作；这些纯函数可由 isolate 调用，也便于后续补充无网络单元测试。

import 'dart:convert';

import '../domain/system_admin_models.dart';

/// 解析 `who` 输出为当前登录会话。
List<ActiveSession> parseActiveSessions(String text) {
  final sessions = <ActiveSession>[];
  for (final line in const LineSplitter().convert(text)) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 2 || parts.first.isEmpty) continue;
    var loginTime = '';
    var ipAddress = '';
    if (parts.length >= 4) {
      loginTime = '${parts[2]} ${parts[3]}';
      if (parts.length >= 5) {
        ipAddress = parts.sublist(4).join(' ').replaceAll(RegExp(r'[()]'), '');
      }
    } else if (parts.length > 2) {
      loginTime = parts.sublist(2).join(' ');
    }
    sessions.add(
      ActiveSession(
        username: parts[0],
        tty: parts[1],
        loginTime: loginTime,
        ipAddress: ipAddress,
      ),
    );
  }
  return sessions;
}

/// 解析 `/etc/passwd` 及其状态输出。
List<LinuxUserAccount> parseLinuxUserAccounts(String text) {
  final sections = text.split('===STATUS===');
  final statusMap = <String, String>{};
  if (sections.length > 1) {
    for (final line in const LineSplitter().convert(sections[1])) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length >= 2 && fields.first.isNotEmpty) {
        statusMap[fields[0]] = fields[1];
      }
    }
  }

  final accounts = <LinuxUserAccount>[];
  for (final line in const LineSplitter().convert(sections.first)) {
    final fields = line.trim().split(':');
    if (fields.length < 7 || fields.first.isEmpty) continue;
    final uid = int.tryParse(fields[2]) ?? -1;
    final gid = int.tryParse(fields[3]) ?? -1;
    final shell = fields[6];
    final isInteractiveShell =
        shell.isNotEmpty &&
        !shell.contains('nologin') &&
        !shell.contains('false') &&
        (shell.endsWith('sh') || shell.contains('sh'));
    if (uid == 0 || (uid >= 1000 && uid < 65534) || isInteractiveShell) {
      accounts.add(
        LinuxUserAccount(
          username: fields[0],
          uid: uid,
          gid: gid,
          homeDir: fields[5],
          shell: shell,
          status: statusMap[fields[0]] ?? 'Unknown',
        ),
      );
    }
  }
  accounts.sort((a, b) {
    if (a.uid == 0) return -1;
    if (b.uid == 0) return 1;
    return a.username.compareTo(b.username);
  });
  return accounts;
}

/// 解析 `ps` 输出为指定用户的进程快照。
List<LinuxUserProcess> parseLinuxUserProcesses(String text) {
  final processes = <LinuxUserProcess>[];
  for (final line in const LineSplitter().convert(text)) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 5 || parts.first.isEmpty) continue;
    processes.add(
      LinuxUserProcess(
        pid: int.tryParse(parts[0]) ?? -1,
        rssBytes: (int.tryParse(parts[1]) ?? 0) * 1024,
        cpuPercent: double.tryParse(parts[2]) ?? 0,
        memPercent: double.tryParse(parts[3]) ?? 0,
        command: parts.sublist(4).join(' '),
      ),
    );
  }
  processes.sort((a, b) => b.rssBytes.compareTo(a.rssBytes));
  return processes;
}

/// 解析 `systemctl list-units` 输出。
List<SystemdService> parseSystemdServices(String text) {
  final services = <SystemdService>[];
  for (final line in const LineSplitter().convert(text)) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 4 || parts.first.isEmpty) continue;
    services.add(
      SystemdService(
        name: parts[0],
        loadState: parts[1],
        activeState: parts[2],
        subState: parts[3],
        description: parts.length > 4 ? parts.sublist(4).join(' ') : '',
      ),
    );
  }
  return services;
}

/// 解析 `ss`/`netstat` 输出为监听端口快照。
List<ListeningPort> parseListeningPorts(String text) {
  final ports = <ListeningPort>[];
  for (final line in const LineSplitter().convert(text)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty ||
        trimmed.startsWith('Netid') ||
        trimmed.startsWith('Active')) {
      continue;
    }
    final fields = trimmed.split(RegExp(r'\s+'));
    if (fields.length < 5) continue;
    final isNetstat = int.tryParse(fields[1]) != null;
    final localAddressIndex = isNetstat ? 3 : 4;
    if (fields.length <= localAddressIndex) continue;
    final address = fields[localAddressIndex];
    final lastColon = address.lastIndexOf(':');
    if (lastColon < 0) continue;

    var processName = '-';
    int? pid;
    final processField = fields.last;
    if (processField.contains('users:')) {
      final match = RegExp(r'"([^"]+)",pid=(\d+)').firstMatch(processField);
      if (match != null) {
        processName = match.group(1) ?? '-';
        pid = int.tryParse(match.group(2) ?? '');
      }
    } else if (RegExp(r'^\d+/').hasMatch(processField)) {
      final processParts = processField.split('/');
      pid = int.tryParse(processParts[0]);
      processName = processParts.sublist(1).join('/');
    }
    ports.add(
      ListeningPort(
        protocol: fields[0],
        localAddress: address.substring(0, lastColon),
        localPort: int.tryParse(address.substring(lastColon + 1)) ?? 0,
        processName: processName,
        pid: pid,
      ),
    );
  }
  ports.sort((a, b) => a.localPort.compareTo(b.localPort));
  return ports;
}
