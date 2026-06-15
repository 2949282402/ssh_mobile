part of '../ssh_service.dart';

class _LocalSshRuntime {
  final String sessionId;
  final SSHClient client;
  final SSHSession shell;
  final String? tmuxSessionName;
  StreamSubscription<List<int>>? stdoutSub;
  StreamSubscription<List<int>>? stderrSub;
  Timer? keepAliveTimer;
  bool pingInFlight = false;
  int keepAliveFailures = 0;

  _LocalSshRuntime({
    required this.sessionId,
    required this.client,
    required this.shell,
    required this.tmuxSessionName,
  });

  void close() {
    keepAliveTimer?.cancel();
    stdoutSub?.cancel();
    stderrSub?.cancel();
    shell.close();
    client.close();
  }
}
