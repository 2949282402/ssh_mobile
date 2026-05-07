import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import '../models/connection.dart';
import 'app_log_service.dart';
import 'background_service.dart';
import 'storage_service.dart';
import 'terminal_history_service.dart';

enum SshConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

class SshSession {
  final String id;
  final String connectionId;
  final String connectionName;
  final StreamController<String> outputController;
  final StringBuffer _outputBuffer = StringBuffer();
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
    this.fontSize = 14,
    required this.outputController,
    this.state = SshConnectionState.connecting,
    this.errorMessage,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : displayName = displayName ?? connectionName,
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Stream<String> get output => outputController.stream;
  bool get isConnected => state == SshConnectionState.connected;
  String get outputText => _outputBuffer.toString();
  int get estimatedMemoryBytes {
    // Rough per-window local cache size. Dart strings are UTF-16, so this
    // intentionally estimates the terminal text cache rather than process RSS.
    return _outputBuffer.length * 2;
  }

  String? get tmuxKillCommand {
    final name = tmuxSessionName;
    if (name == null || name.isEmpty) return null;
    return "tmux kill-session -t ${_shellQuote(name)}";
  }

  void addOutput(String data) {
    _outputBuffer.write(data);
    outputController.add(data);
  }

  Future<void> close() async {
    await outputController.close();
  }

  static String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }
}

class SshService extends ChangeNotifier {
  final StorageService _storageService;
  final FlutterBackgroundService _backgroundService =
      FlutterBackgroundService();
  final TerminalHistoryService _historyService = TerminalHistoryService();

  final Map<String, SshSession> _sessions = {};
  final Map<String, _LocalSshRuntime> _localRuntimes = {};
  final Map<String, Completer<void>> _connectCompleters = {};
  final Set<String> _closingSessionIds = {};
  final Random _random = Random();
  StreamSubscription<Map<String, dynamic>?>? _stateSub;
  StreamSubscription<Map<String, dynamic>?>? _outputSub;
  StreamSubscription<Map<String, dynamic>?>? _keepAliveSub;
  StreamSubscription<Map<String, dynamic>?>? _appLogSub;
  String? _lastSessionId;
  String? _lastErrorMessage;
  bool _restoredTmuxSessions = false;

  SshService(this._storageService) {
    if (_usesBackgroundService) {
      _listenToBackgroundService();
    } else {
      AppLogService.instance.info(
        'Background SSH service disabled on this platform',
      );
    }
  }

  bool get _usesBackgroundService {
    return !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
  }

  List<SshSession> get sessions => List.unmodifiable(_sessions.values);
  bool get isConnected =>
      _sessions.values.any((session) => session.isConnected);
  SshConnectionState get state =>
      currentSession?.state ??
      (isConnected
          ? SshConnectionState.connected
          : SshConnectionState.disconnected);
  String? get errorMessage => currentSession?.errorMessage ?? _lastErrorMessage;
  SshSession? get currentSession => _lastSessionId == null
      ? null
      : _sessions[_lastSessionId] ?? _sessions.values.lastOrNull;
  String? get activeConnectionId => currentSession?.connectionId;

  SshSession? getSession(String sessionId) => _sessions[sessionId];

  Future<String> loadSessionHistoryText(String sessionId) {
    return _historyService.readTail(sessionId);
  }

  Future<List<TerminalHistoryRecord>> loadTerminalHistoryRecords() {
    return _storageService.loadTerminalHistoryRecords();
  }

  Future<void> removeTerminalHistoryRecord(String sessionId) {
    return _storageService.removeTerminalHistoryRecord(sessionId);
  }

  bool hasConnectedSession(String connectionId) {
    return _sessions.values.any(
      (session) =>
          session.connectionId == connectionId &&
          session.state == SshConnectionState.connected,
    );
  }

  SshSession? latestSessionForConnection(String connectionId) {
    for (final session in _sessions.values.toList().reversed) {
      if (session.connectionId == connectionId) return session;
    }
    return null;
  }

  int sessionCountForConnection(String connectionId) {
    return _sessions.values
        .where((session) => session.connectionId == connectionId)
        .length;
  }

  Future<void> disconnectSessionsForConnection(String connectionId) async {
    final sessionIds = _sessions.values
        .where((session) => session.connectionId == connectionId)
        .map((session) => session.id)
        .toList();

    for (final sessionId in sessionIds) {
      await disconnectSession(sessionId);
    }
  }

  bool renameSession(String sessionId, String name) {
    final session = _sessions[sessionId];
    final nextName = name.trim();
    if (session == null || nextName.isEmpty) return false;
    if (_isSessionNameTaken(nextName, exceptSessionId: sessionId)) {
      return false;
    }
    session.displayName = nextName;
    unawaited(_saveRestorableTmuxSession(session));
    notifyListeners();
    return true;
  }

  void setSessionFontSize(String sessionId, double fontSize) {
    final session = _sessions[sessionId];
    if (session == null) return;
    session.fontSize = fontSize.clamp(1.0, 28.0);
    unawaited(_saveRestorableTmuxSession(session));
    notifyListeners();
  }

  Future<void> restoreTmuxSessions() async {
    if (_restoredTmuxSessions) return;
    _restoredTmuxSessions = true;
    final storedSessions = await _storageService.loadRestorableTmuxSessions();
    AppLogService.instance.info(
      'Restoring tmux sessions',
      details: 'count=${storedSessions.length}',
    );
    if (storedSessions.isEmpty) return;

    for (final stored in storedSessions) {
      final config = _storageService.getConnection(stored.connectionId);
      if (config?.launchMode != TerminalLaunchMode.tmux) {
        AppLogService.instance.warning(
          'Removing stale restorable tmux session',
          details: 'sessionId=${stored.sessionId}',
        );
        await _storageService.removeRestorableTmuxSession(stored.sessionId);
        continue;
      }

      _sessions[stored.sessionId] = SshSession(
        id: stored.sessionId,
        connectionId: stored.connectionId,
        connectionName: config!.name,
        displayName: _uniqueSessionName(stored.displayName),
        tmuxSessionName: stored.tmuxSessionName,
        tmuxAutoDeleteSeconds: config.tmuxAutoDeleteSeconds,
        fontSize: stored.fontSize,
        outputController: StreamController<String>.broadcast(),
        state: SshConnectionState.disconnected,
        errorMessage: 'Waiting to reconnect tmux session',
      );
      _lastSessionId = stored.sessionId;
    }

    notifyListeners();

    for (final session in _sessions.values.toList()) {
      final config = _storageService.getConnection(session.connectionId);
      if (config?.launchMode != TerminalLaunchMode.tmux ||
          session.isConnected) {
        continue;
      }
      unawaited(connect(session.connectionId, sessionId: session.id));
    }
  }

  Future<String?> openSession(
    String connectionId, {
    String? displayName,
  }) async {
    final sessionId = _createSessionId(connectionId);
    AppLogService.instance.info(
      'Opening SSH session',
      details: 'connectionId=$connectionId sessionId=$sessionId',
    );
    await connect(
      connectionId,
      sessionId: sessionId,
      displayName: displayName,
    );
    final session = _sessions[sessionId];
    if (session?.isConnected == true) return sessionId;

    _lastErrorMessage = session?.errorMessage ?? _lastErrorMessage;
    AppLogService.instance.warning(
      'Open SSH session failed',
      details:
          'connectionId=$connectionId sessionId=$sessionId error=$_lastErrorMessage',
    );
    await _removeFailedOpenSession(sessionId);
    return null;
  }

  Future<bool> ensureSessionConnected(
    String sessionId,
    String connectionId,
  ) async {
    final existing = _sessions[sessionId];
    if (existing?.isConnected == true) {
      _lastSessionId = sessionId;
      return true;
    }

    await connect(connectionId, sessionId: sessionId);
    return _sessions[sessionId]?.isConnected == true;
  }

  Future<bool> ensureConnected(String connectionId) async {
    final existing = latestSessionForConnection(connectionId);
    if (existing?.isConnected == true) {
      _lastSessionId = existing!.id;
      return true;
    }

    final sessionId = await openSession(connectionId);
    return sessionId != null;
  }

  Future<void> connect(
    String connectionId, {
    String? sessionId,
    String? displayName,
  }) async {
    final config = _storageService.getConnection(connectionId);
    if (config == null) {
      AppLogService.instance.error(
        'Connection config not found',
        details: 'connectionId=$connectionId sessionId=$sessionId',
      );
      _setSessionError(
        sessionId ?? _createSessionId(connectionId),
        connectionId,
        'Unknown',
        'Connection config not found',
      );
      return;
    }

    final id = sessionId ?? _createSessionId(connectionId);
    final requestedDisplayName = displayName?.trim();
    if (requestedDisplayName?.isNotEmpty == true &&
        _isSessionNameTaken(requestedDisplayName!, exceptSessionId: id)) {
      AppLogService.instance.warning(
        'Window name already exists',
        details: 'name=$requestedDisplayName sessionId=$id',
      );
      _setSessionError(
        id,
        connectionId,
        config.name,
        'Window name already exists',
      );
      return;
    }
    final defaultDisplayName = requestedDisplayName?.isNotEmpty == true
        ? requestedDisplayName!
        : _defaultDisplayName(config.host, connectionId);
    final session = _sessions.putIfAbsent(
      id,
      () => SshSession(
        id: id,
        connectionId: connectionId,
        connectionName: config.name,
        displayName: defaultDisplayName,
        outputController: StreamController<String>.broadcast(),
      ),
    );

    if (session.state == SshConnectionState.connecting &&
        _connectCompleters.containsKey(id)) {
      await _connectCompleters[id]!.future;
      return;
    }

    session.state = SshConnectionState.connecting;
    session.errorMessage = null;
    session.tmuxAutoDeleteSeconds = config.tmuxAutoDeleteSeconds;
    session.updatedAt = DateTime.now();
    _lastErrorMessage = null;
    _lastSessionId = id;
    final connectCompleter = Completer<void>();
    _connectCompleters[id] = connectCompleter;
    unawaited(_saveTerminalHistoryRecord(session));
    AppLogService.instance.info(
      'Session connecting',
      details:
          'sessionId=$id connection=${config.name} mode=${config.launchMode.name}',
    );
    notifyListeners();

    try {
      final password = await _storageService.getPassword(connectionId);
      final privateKey = await _storageService.getPrivateKey(connectionId);
      _validateAuthSecrets(
        config: config,
        password: password,
        privateKey: privateKey,
      );

      session.tmuxSessionName ??= config.launchMode == TerminalLaunchMode.tmux
          ? _uniqueTmuxSessionName(
              _tmuxSessionNameForSession(session),
              exceptSessionId: id,
            )
          : null;
      if (session.tmuxSessionName != null) {
        AppLogService.instance.info(
          'Using tmux session',
          details: 'sessionId=$id tmux=${session.tmuxSessionName}',
        );
      }
      if (_usesBackgroundService) {
        await BackgroundServiceManager.start(
          connectionName: _notificationSummary(),
        );
        _backgroundService.invoke('sshConnect', {
          'sessionId': id,
          'id': config.id,
          'name': config.name,
          'host': config.host,
          'port': config.port,
          'username': config.username,
          'password': password,
          'privateKey': privateKey,
          'authMethod': config.authMethod.name,
          'terminalWidth': config.terminalWidth,
          'terminalHeight': config.terminalHeight,
          'keepAliveInterval': 3,
          'launchMode': config.launchMode.name,
          'tmuxSessionName': session.tmuxSessionName,
          'tmuxAutoDeleteSeconds': config.tmuxAutoDeleteSeconds,
        });
      } else {
        await _connectLocalSession(
          session: session,
          config: config,
          password: password,
          privateKey: privateKey,
        );
      }

      await connectCompleter.future.timeout(
        const Duration(seconds: 30),
      );
    } on TimeoutException {
      AppLogService.instance.error(
        'Session connect timed out',
        details: 'sessionId=$id connection=${config.name}',
      );
      _setSessionError(id, connectionId, config.name, 'Connection timed out');
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Session connect failed',
        error: e,
        stackTrace: stackTrace,
        details: 'sessionId=$id connection=${config.name}',
      );
      _setSessionError(id, connectionId, config.name, 'Connection failed: $e');
    }
  }

  Future<void> disconnectSession(String sessionId) async {
    AppLogService.instance
        .info('Disconnecting session', details: 'sessionId=$sessionId');
    _closingSessionIds.add(sessionId);
    if (_usesBackgroundService) {
      _backgroundService.invoke('sshDisconnect', {'sessionId': sessionId});
    } else {
      await _closeLocalSession(sessionId, destroyTmux: true);
    }
    final session = _sessions.remove(sessionId);
    if (session != null) {
      session.state = SshConnectionState.disconnected;
      session.errorMessage = 'Closed by user';
      session.updatedAt = DateTime.now();
      unawaited(_saveTerminalHistoryRecord(session));
    }
    await session?.close();
    await _storageService.removeRestorableTmuxSession(sessionId);
    _connectCompleters.remove(sessionId);
    if (_lastSessionId == sessionId) {
      _lastSessionId = _sessions.isEmpty ? null : _sessions.keys.last;
    }
    await _stopServiceIfIdle();
    notifyListeners();
  }

  Future<void> _removeFailedOpenSession(String sessionId) async {
    _closingSessionIds.add(sessionId);
    final session = _sessions.remove(sessionId);
    if (session != null) {
      session.state = SshConnectionState.error;
      session.errorMessage ??= 'Connection failed';
      session.updatedAt = DateTime.now();
      unawaited(_saveTerminalHistoryRecord(session));
    }
    await session?.close();
    await _storageService.removeRestorableTmuxSession(sessionId);
    _connectCompleters.remove(sessionId);
    if (_lastSessionId == sessionId) {
      _lastSessionId = _sessions.isEmpty ? null : _sessions.keys.last;
    }
    await _stopServiceIfIdle();
    notifyListeners();
  }

  Future<void> disconnect() async {
    AppLogService.instance.info(
      'Disconnecting all sessions',
      details: 'count=${_sessions.length}',
    );
    _closingSessionIds.addAll(_sessions.keys);
    if (_usesBackgroundService) {
      _backgroundService.invoke('sshDisconnectAll');
    } else {
      for (final sessionId in _sessions.keys.toList()) {
        await _closeLocalSession(sessionId, destroyTmux: true);
      }
    }
    for (final session in _sessions.values) {
      session.state = SshConnectionState.disconnected;
      session.errorMessage = 'Closed by user';
      session.updatedAt = DateTime.now();
      unawaited(_saveTerminalHistoryRecord(session));
      await session.close();
    }
    _sessions.clear();
    _connectCompleters.clear();
    _lastSessionId = null;
    await _storageService.clearRestorableTmuxSessions();
    await BackgroundServiceManager.stop();
    notifyListeners();
  }

  void resizeTerminal(String sessionId, int width, int height) {
    final session = _sessions[sessionId];
    if (session?.isConnected == true) {
      if (_usesBackgroundService) {
        _backgroundService.invoke('sshResize', {
          'sessionId': sessionId,
          'width': width,
          'height': height,
        });
      } else {
        _localRuntimes[sessionId]?.shell.resizeTerminal(width, height);
      }
    }
  }

  void sendData(String sessionId, String data) {
    final session = _sessions[sessionId];
    if (session?.isConnected == true) {
      if (_usesBackgroundService) {
        _backgroundService.invoke('sshInput', {
          'sessionId': sessionId,
          'data': data,
        });
      } else {
        _localRuntimes[sessionId]?.shell.stdin.add(utf8.encode(data));
      }
    }
  }

  void sendBytes(String sessionId, Uint8List data) {
    sendData(sessionId, String.fromCharCodes(data));
  }

  void _validateAuthSecrets({
    required ConnectionConfig config,
    required String? password,
    required String? privateKey,
  }) {
    final hasPassword = password?.isNotEmpty == true;
    final hasPrivateKey = privateKey?.isNotEmpty == true;

    switch (config.authMethod) {
      case AuthMethod.password:
        if (!hasPassword) {
          throw StateError(
            'Password is missing for this connection. Please edit the server '
            'configuration and save the password again on this device.',
          );
        }
        break;
      case AuthMethod.privateKey:
        if (!hasPrivateKey) {
          throw StateError(
            'Private key is missing for this connection. Please edit the '
            'server configuration and save the private key again on this device.',
          );
        }
        break;
      case AuthMethod.both:
        if (!hasPrivateKey || !hasPassword) {
          throw StateError(
            'Password or private key is missing for this connection. Please '
            'edit the server configuration and save both credentials again on '
            'this device.',
          );
        }
        break;
    }
  }

  Future<void> _connectLocalSession({
    required SshSession session,
    required ConnectionConfig config,
    required String? password,
    required String? privateKey,
  }) async {
    await _closeLocalSession(session.id, destroyTmux: false);
    AppLogService.instance.info(
      'Connecting SSH locally',
      details: 'sessionId=${session.id} host=${config.host}:${config.port}',
    );

    final socket = await SSHSocket.connect(
      config.host,
      config.port,
      timeout: const Duration(seconds: 15),
    );
    final identities = (config.authMethod == AuthMethod.privateKey ||
                config.authMethod == AuthMethod.both) &&
            privateKey?.isNotEmpty == true
        ? SSHKeyPair.fromPem(privateKey!, password)
        : null;
    final client = SSHClient(
      socket,
      username: config.username,
      identities: identities,
      onPasswordRequest: () {
        if (config.authMethod == AuthMethod.privateKey) return null;
        return password!;
      },
    );

    if (config.launchMode == TerminalLaunchMode.tmux) {
      await _ensureLocalTmuxInstalled(client);
    }

    final shell = await client.shell(
      pty: SSHPtyConfig(
        width: config.terminalWidth,
        height: config.terminalHeight,
        type: 'xterm-256color',
      ),
    );
    final runtime = _LocalSshRuntime(
      sessionId: session.id,
      client: client,
      shell: shell,
      tmuxSessionName: config.launchMode == TerminalLaunchMode.tmux
          ? session.tmuxSessionName
          : null,
    );
    _localRuntimes[session.id] = runtime;

    runtime.stdoutSub = shell.stdout.listen(
      (bytes) => _handleLocalOutput(session.id, bytes),
      onError: (Object error) {
        _handleLocalDisconnect(session.id, 'SSH stdout error: $error');
      },
      onDone: () {
        _handleLocalDisconnect(session.id, 'SSH connection closed');
      },
    );
    runtime.stderrSub = shell.stderr.listen(
      (bytes) => _handleLocalOutput(session.id, bytes),
    );

    if (config.launchMode == TerminalLaunchMode.tmux) {
      shell.stdin.add(
        utf8.encode(
          '${_buildTmuxAttachCommand(
            session.tmuxSessionName ?? config.name,
            config.tmuxAutoDeleteSeconds,
          )}\r',
        ),
      );
    }

    runtime.keepAliveTimer = Timer.periodic(
      Duration(seconds: config.keepAliveInterval.clamp(3, 30)),
      (_) async {
        if (runtime.pingInFlight) return;
        runtime.pingInFlight = true;
        try {
          await client.ping().timeout(const Duration(seconds: 10));
          runtime.keepAliveFailures = 0;
        } catch (e) {
          runtime.keepAliveFailures++;
          AppLogService.instance.warning(
            'Local SSH keep-alive failed',
            details:
                'sessionId=${session.id} failures=${runtime.keepAliveFailures} error=$e',
          );
          _handleLocalDisconnect(session.id, 'SSH keep-alive failed: $e');
        } finally {
          runtime.pingInFlight = false;
        }
      },
    );

    session.state = SshConnectionState.connected;
    session.errorMessage = null;
    session.updatedAt = DateTime.now();
    _completeConnect(session.id);
    unawaited(_saveRestorableTmuxSession(session));
    unawaited(_saveTerminalHistoryRecord(session));
    AppLogService.instance.info(
      'Local SSH session connected',
      details: 'sessionId=${session.id} connection=${config.name}',
    );
    notifyListeners();
  }

  void _handleLocalOutput(String sessionId, List<int> bytes) {
    final data = utf8.decode(bytes, allowMalformed: true);
    _sessions[sessionId]?.addOutput(data);
    unawaited(_historyService.append(sessionId, data));
  }

  void _handleLocalDisconnect(String sessionId, String message) {
    if (_closingSessionIds.contains(sessionId)) return;
    final runtime = _localRuntimes.remove(sessionId);
    runtime?.close();
    final session = _sessions[sessionId];
    if (session == null || session.state == SshConnectionState.disconnected) {
      return;
    }
    session.state = SshConnectionState.disconnected;
    session.errorMessage = message;
    session.updatedAt = DateTime.now();
    _completeConnect(sessionId);
    unawaited(_saveTerminalHistoryRecord(session));
    AppLogService.instance.warning(
      'Local SSH session disconnected',
      details: 'sessionId=$sessionId message=$message',
    );
    notifyListeners();
  }

  Future<void> _closeLocalSession(
    String sessionId, {
    required bool destroyTmux,
  }) async {
    final runtime = _localRuntimes.remove(sessionId);
    if (runtime == null) return;
    if (destroyTmux && runtime.tmuxSessionName?.isNotEmpty == true) {
      try {
        await runtime.client
            .run(
                'tmux kill-session -t ${_shellQuote(runtime.tmuxSessionName!)}')
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    runtime.close();
  }

  Future<void> _ensureLocalTmuxInstalled(SSHClient client) async {
    late final SSHRunResult result;
    try {
      result = await client
          .runWithResult('command -v tmux >/dev/null 2>&1')
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      throw StateError(
        'Unable to check tmux on this server. Please install tmux manually '
        'on the server and try again. Detail: $e',
      );
    }
    if (result.exitCode == 0) return;
    throw StateError(
      'tmux is not installed on this server. Please install tmux manually '
      'on the server and try again.',
    );
  }

  String _buildTmuxAttachCommand(String sessionName, int autoDeleteSeconds) {
    final safeName = _sanitizeTmuxSessionName(sessionName);
    final quotedName = _shellQuote(safeName);
    final seconds = autoDeleteSeconds.clamp(30, 86400);
    final idleWatcher = 'idle_start=0; interval=5; '
        'while tmux has-session -t $quotedName 2>/dev/null; do '
        'if tmux list-clients -t $quotedName 2>/dev/null | grep -q .; then '
        'idle_start=0; '
        'else now=\$(date +%s); '
        'if [ "\$idle_start" -eq 0 ]; then idle_start=\$now; fi; '
        'if [ \$((now - idle_start)) -ge $seconds ]; then '
        'tmux kill-session -t $quotedName 2>/dev/null; exit; fi; '
        'fi; sleep \$interval; done';
    return 'tmux has-session -t $quotedName 2>/dev/null || '
        'tmux new-session -d -s $quotedName; '
        'tmux set-option -t $quotedName -q @ssh_mobile_auto_delete_seconds $seconds; '
        'tmux set-option -t $quotedName -q status off; '
        'tmux run-shell -b ${_shellQuote(idleWatcher)}; '
        'tmux attach-session -t $quotedName';
  }

  String _createSessionId(String connectionId) {
    final millis = DateTime.now().millisecondsSinceEpoch;
    final nonce = _random.nextInt(0x7fffffff).toRadixString(16);
    return '$connectionId-$millis-$nonce';
  }

  String _sanitizeTmuxSessionName(String name) {
    final sanitized = name
        .trim()
        // tmux treats "." as a target separator: session.window. Keep session
        // names to plain safe characters so domains like hejulian.cn do not
        // become an invalid tmux target.
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (sanitized.isEmpty) return 'ssh_mobile';
    return sanitized.length > 80 ? sanitized.substring(0, 80) : sanitized;
  }

  String _tmuxSessionNameForSession(SshSession session) {
    final readableName = _sanitizeTmuxSessionName(session.displayName);
    final timestamp = _compactTmuxTimestamp(session.createdAt);
    final suffix = '${timestamp}_${_stableSessionIdSuffix(session.id)}';
    final maxReadableLength = 80 - suffix.length - 1;
    final readablePrefix = readableName.length > maxReadableLength
        ? readableName.substring(0, maxReadableLength)
        : readableName;
    return _sanitizeTmuxSessionName('${readablePrefix}_$suffix');
  }

  String _compactTmuxTimestamp(DateTime time) {
    final local = time.toLocal();
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${local.year}'
        '${twoDigits(local.month)}'
        '${twoDigits(local.day)}'
        '${twoDigits(local.hour)}'
        '${twoDigits(local.minute)}'
        '${twoDigits(local.second)}';
  }

  String _stableSessionIdSuffix(String sessionId) {
    var hash = 0x811c9dc5;
    for (final codeUnit in sessionId.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }

  bool _isTmuxSessionNameTaken(String name, {String? exceptSessionId}) {
    return _sessions.values.any(
      (session) =>
          session.id != exceptSessionId &&
          session.tmuxSessionName?.toLowerCase() == name.toLowerCase(),
    );
  }

  String _uniqueTmuxSessionName(String baseName, {String? exceptSessionId}) {
    final normalized = baseName.isEmpty ? 'ssh_mobile' : baseName;
    if (!_isTmuxSessionNameTaken(normalized,
        exceptSessionId: exceptSessionId)) {
      return normalized;
    }

    var index = 2;
    while (true) {
      final suffix = '_$index';
      final trimmedBase = normalized.length + suffix.length > 80
          ? normalized.substring(0, 80 - suffix.length)
          : normalized;
      final candidate = '$trimmedBase$suffix';
      if (!_isTmuxSessionNameTaken(candidate,
          exceptSessionId: exceptSessionId)) {
        return candidate;
      }
      index++;
    }
  }

  void _listenToBackgroundService() {
    _appLogSub = _backgroundService.on('appLog').listen((event) {
      final level = event?['level'] as String? ?? 'service';
      final message = event?['message'] as String? ?? '';
      final details = event?['details'] as String?;
      if (message.isEmpty) return;
      AppLogService.instance.add(level, message, details: details);
    });

    _stateSub = _backgroundService.on('sshState').listen((event) {
      final sessionId = event?['sessionId'] as String?;
      if (sessionId == null) return;

      final state = event?['state'] as String?;
      final message = event?['message'] as String?;
      final connectionId = event?['connectionId'] as String?;
      final connectionName = event?['connectionName'] as String?;
      AppLogService.instance.info(
        'SSH state: ${state ?? 'unknown'}',
        details:
            'sessionId=$sessionId connection=${connectionName ?? connectionId ?? ''}'
            '${message == null ? '' : ' message=$message'}',
      );

      if (state == 'disconnected' && _closingSessionIds.remove(sessionId)) {
        _completeConnect(sessionId);
        notifyListeners();
        return;
      }

      final session = _sessions.putIfAbsent(
        sessionId,
        () => SshSession(
          id: sessionId,
          connectionId: connectionId ?? '',
          connectionName: connectionName ?? 'SSH',
          displayName: connectionName ?? 'SSH',
          outputController: StreamController<String>.broadcast(),
        ),
      );

      switch (state) {
        case 'connecting':
          session.state = SshConnectionState.connecting;
          session.errorMessage = null;
          _lastSessionId = sessionId;
          break;
        case 'connected':
          session.state = SshConnectionState.connected;
          session.errorMessage = null;
          _lastSessionId = sessionId;
          _completeConnect(sessionId);
          unawaited(_saveRestorableTmuxSession(session));
          break;
        case 'disconnected':
          session.state = SshConnectionState.disconnected;
          session.errorMessage = message;
          _completeConnect(sessionId);
          break;
        case 'error':
          session.state = SshConnectionState.error;
          session.errorMessage = message ?? 'SSH connection failed';
          _lastSessionId = sessionId;
          _completeConnect(sessionId);
          break;
      }

      session.updatedAt = DateTime.now();
      unawaited(_saveTerminalHistoryRecord(session));
      notifyListeners();
    });

    _outputSub = _backgroundService.on('sshOutput').listen((event) {
      final sessionId = event?['sessionId'] as String?;
      final data = event?['data'] as String?;
      if (sessionId == null || data == null) return;
      _sessions[sessionId]?.addOutput(data);
      unawaited(_historyService.append(sessionId, data));
    });

    _keepAliveSub = _backgroundService.on('sshKeepAlive').listen((event) {
      if (event?['ok'] == false) {
        debugPrint(
          'Service keep-alive failed for ${event?['sessionId']}: '
          '${event?['error']}',
        );
      }
    });
  }

  void _completeConnect(String sessionId) {
    final completer = _connectCompleters.remove(sessionId);
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void _setSessionError(
    String sessionId,
    String connectionId,
    String connectionName,
    String message,
  ) {
    final session = _sessions.putIfAbsent(
      sessionId,
      () => SshSession(
        id: sessionId,
        connectionId: connectionId,
        connectionName: connectionName,
        displayName: _defaultDisplayName(connectionName, connectionId),
        outputController: StreamController<String>.broadcast(),
      ),
    );
    session.state = SshConnectionState.error;
    session.errorMessage = message;
    session.updatedAt = DateTime.now();
    _lastSessionId = sessionId;
    _completeConnect(sessionId);
    unawaited(_saveTerminalHistoryRecord(session));
    notifyListeners();
  }

  Future<void> _saveRestorableTmuxSession(SshSession session) async {
    final config = _storageService.getConnection(session.connectionId);
    if (config?.launchMode != TerminalLaunchMode.tmux ||
        session.tmuxSessionName == null ||
        session.tmuxSessionName!.isEmpty) {
      return;
    }

    await _storageService.saveRestorableTmuxSession(
      RestorableTmuxSession(
        sessionId: session.id,
        connectionId: session.connectionId,
        displayName: session.displayName,
        tmuxSessionName: session.tmuxSessionName!,
        fontSize: session.fontSize,
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<void> _saveTerminalHistoryRecord(SshSession session) async {
    await _storageService.saveTerminalHistoryRecord(
      TerminalHistoryRecord(
        sessionId: session.id,
        connectionId: session.connectionId,
        connectionName: session.connectionName,
        displayName: session.displayName,
        tmuxSessionName: session.tmuxSessionName,
        state: session.state.name,
        errorMessage: session.errorMessage,
        createdAt: session.createdAt,
        updatedAt: session.updatedAt,
      ),
    );
  }

  String _notificationSummary() {
    final count = _sessions.values
        .where((session) => session.state != SshConnectionState.disconnected)
        .length;
    return count <= 1 ? '1 SSH session' : '$count SSH sessions';
  }

  String _defaultDisplayName(String connectionName, String connectionId) {
    final existingCount = sessionCountForConnection(connectionId);
    final baseName = '$connectionName ${existingCount + 1}';
    return _uniqueSessionName(baseName);
  }

  String defaultDisplayNameForConnection(String connectionId) {
    final config = _storageService.getConnection(connectionId);
    return _defaultDisplayName(config?.host ?? 'SSH', connectionId);
  }

  bool isSessionNameAvailable(String name) {
    return name.trim().isNotEmpty && !_isSessionNameTaken(name);
  }

  bool _isSessionNameTaken(String name, {String? exceptSessionId}) {
    final normalizedName = name.trim().toLowerCase();
    return _sessions.values.any(
      (session) =>
          session.id != exceptSessionId &&
          session.displayName.trim().toLowerCase() == normalizedName,
    );
  }

  String _uniqueSessionName(String baseName) {
    final normalizedBaseName = baseName.trim();
    if (!_isSessionNameTaken(normalizedBaseName)) return normalizedBaseName;

    var index = 2;
    while (true) {
      final candidate = '$normalizedBaseName ($index)';
      if (!_isSessionNameTaken(candidate)) return candidate;
      index++;
    }
  }

  Future<void> _stopServiceIfIdle() async {
    final hasActive = _sessions.values.any(
      (session) =>
          session.state == SshConnectionState.connected ||
          session.state == SshConnectionState.connecting,
    );
    if (!hasActive) {
      await BackgroundServiceManager.stop();
    } else {
      BackgroundServiceManager.updateStatus(_notificationSummary());
    }
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _outputSub?.cancel();
    _keepAliveSub?.cancel();
    _appLogSub?.cancel();
    unawaited(_historyService.flush());
    for (final runtime in _localRuntimes.values) {
      runtime.close();
    }
    for (final session in _sessions.values) {
      session.close();
    }
    super.dispose();
  }
}

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

extension _LastOrNull<T> on Iterable<T> {
  T? get lastOrNull => isEmpty ? null : last;
}
