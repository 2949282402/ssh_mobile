class ActiveSession {
  final String username;
  final String tty;
  final String loginTime;
  final String ipAddress;

  const ActiveSession({
    required this.username,
    required this.tty,
    required this.loginTime,
    required this.ipAddress,
  });
}

class LinuxUserAccount {
  final String username;
  final int uid;
  final int gid;
  final String homeDir;
  final String shell;
  final String
      status; // 'L' (Locked), 'P' (Password set), 'NP' (No password), or 'Unknown'

  const LinuxUserAccount({
    required this.username,
    required this.uid,
    required this.gid,
    required this.homeDir,
    required this.shell,
    required this.status,
  });

  bool get isLocked => status == 'L';
}

class SystemdService {
  final String name;
  final String loadState;
  final String activeState;
  final String subState;
  final String description;

  const SystemdService({
    required this.name,
    required this.loadState,
    required this.activeState,
    required this.subState,
    required this.description,
  });

  bool get isRunning => activeState == 'active';
  bool get isEnabled => loadState == 'loaded';
}

class LinuxUserProcess {
  final int pid;
  final int rssBytes;
  final double cpuPercent;
  final double memPercent;
  final String command;

  const LinuxUserProcess({
    required this.pid,
    required this.rssBytes,
    required this.cpuPercent,
    required this.memPercent,
    required this.command,
  });
}

class ListeningPort {
  final String protocol;
  final String localAddress;
  final int localPort;
  final String processName;
  final int? pid;

  const ListeningPort({
    required this.protocol,
    required this.localAddress,
    required this.localPort,
    required this.processName,
    this.pid,
  });
}
