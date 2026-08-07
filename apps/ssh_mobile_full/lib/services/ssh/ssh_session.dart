part of '../ssh_service.dart';

enum SshConnectionState { disconnected, connecting, connected, error }

class SshConnectionOverview {
  static const empty = SshConnectionOverview(
    count: 0,
    latestState: null,
    hasConnected: false,
  );

  final int count;
  final SshConnectionState? latestState;
  final bool hasConnected;

  const SshConnectionOverview({
    required this.count,
    required this.latestState,
    required this.hasConnected,
  });

  @override
  bool operator ==(Object other) {
    return other is SshConnectionOverview &&
        other.count == count &&
        other.latestState == latestState &&
        other.hasConnected == hasConnected;
  }

  @override
  int get hashCode => Object.hash(count, latestState, hasConnected);
}

class SshServerOverviewSnapshot {
  final Map<String, SshConnectionOverview> byConnection;
  final int windowCount;

  const SshServerOverviewSnapshot({
    required this.byConnection,
    required this.windowCount,
  });

  const SshServerOverviewSnapshot.empty()
    : byConnection = const {},
      windowCount = 0;

  SshConnectionOverview forConnection(String connectionId) {
    return byConnection[connectionId] ?? SshConnectionOverview.empty;
  }

  @override
  bool operator ==(Object other) {
    if (other is! SshServerOverviewSnapshot ||
        other.windowCount != windowCount ||
        other.byConnection.length != byConnection.length) {
      return false;
    }
    for (final entry in byConnection.entries) {
      if (other.byConnection[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    windowCount,
    Object.hashAllUnordered(
      byConnection.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
  );
}

abstract interface class SshClientAdapter {
  List<SshSession> get sessions;
  SshServerOverviewSnapshot get serverOverviewSnapshot;
  bool get isConnected;
  SshConnectionState get state;
  String? get errorMessage;
  SshSession? get currentSession;
  String? get activeConnectionId;

  SshSession? getSession(String sessionId);

  Future<String> loadSessionHistoryText(String sessionId);

  Future<List<TerminalHistoryRecord>> loadTerminalHistoryRecords();

  Future<void> removeTerminalHistoryRecord(String sessionId);

  bool hasConnectedSession(String connectionId);

  SshSession? latestSessionForConnection(String connectionId);

  int sessionCountForConnection(String connectionId);

  Future<void> disconnectSessionsForConnection(String connectionId);

  bool renameSession(String sessionId, String name);

  void setSessionFontSize(String sessionId, double fontSize);

  Future<void> restoreTmuxSessions();

  Future<String?> openSession(
    String connectionId, {
    String? displayName,
    SshHostKeyConfirmation? onUnknownHostKey,
  });

  Future<bool> ensureSessionConnected(String sessionId, String connectionId);

  Future<bool> ensureConnected(String connectionId);

  Future<void> connect(
    String connectionId, {
    String? sessionId,
    String? displayName,
    SshHostKeyConfirmation? onUnknownHostKey,
  });

  Future<void> disconnectSession(String sessionId);

  Future<void> disconnect();

  void resizeTerminal(String sessionId, int width, int height);

  void sendData(String sessionId, String data);

  void sendBytes(String sessionId, Uint8List data);

  Future<RemoteCommandResult> runOneShotCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 15),
    SshHostKeyConfirmation? onUnknownHostKey,
  });
}

class SshSession {
  static const int maxOutputCacheChars = 200000;
  static const double defaultTerminalFontSize = 8.0;
  static const double minTerminalFontSize = 4.0;
  static const double maxTerminalFontSize = 28.0;

  final String id;
  final String connectionId;
  final String connectionName;
  final StreamController<String> outputController;
  final Queue<String> _outputChunks = Queue<String>();
  String? _cachedOutputText;
  int _outputCharCount = 0;
  String displayName;
  String? tmuxSessionName;
  int? tmuxAutoDeleteSeconds;
  double fontSize;
  SshConnectionState state;
  String? errorMessage;
  DateTime createdAt;
  DateTime updatedAt;

  SshSession({
    required this.id,
    required this.connectionId,
    required this.connectionName,
    String? displayName,
    this.tmuxSessionName,
    this.tmuxAutoDeleteSeconds,
    this.fontSize = defaultTerminalFontSize,
    required this.outputController,
    this.state = SshConnectionState.connecting,
    this.errorMessage,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : displayName = displayName ?? connectionName,
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  Stream<String> get output => outputController.stream;
  bool get isConnected => state == SshConnectionState.connected;
  String get outputText => _cachedOutputText ??= _outputChunks.join();
  int get estimatedMemoryBytes {
    return _outputCharCount * 2;
  }

  String? get tmuxKillCommand {
    final name = tmuxSessionName;
    if (name == null || name.isEmpty) return null;
    return "tmux kill-session -t ${_shellQuote(name)}";
  }

  void addOutput(String data) {
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

  Future<void> close() async {
    await outputController.close();
  }

  static String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }
}

class RemoteCommandResult {
  final int? exitCode;
  final String stdout;
  final String stderr;

  const RemoteCommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });
}
