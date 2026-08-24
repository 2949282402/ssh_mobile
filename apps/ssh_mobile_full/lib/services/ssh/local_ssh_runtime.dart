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
  Future<void>? _closeFuture;

  _LocalSshRuntime({
    required this.sessionId,
    required this.client,
    required this.shell,
    required this.tmuxSessionName,
  });

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    keepAliveTimer?.cancel();
    keepAliveTimer = null;
    final subscriptions = <StreamSubscription<List<int>>>[
      ?stdoutSub,
      ?stderrSub,
    ];
    stdoutSub = null;
    stderrSub = null;
    try {
      await Future.wait<void>(
        subscriptions.map((subscription) => subscription.cancel()),
      );
    } finally {
      shell.close();
      client.close();
      pingInFlight = false;
    }
  }
}
