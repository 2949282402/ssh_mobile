import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import 'background_service.dart';
import 'storage_service.dart';

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
  double fontSize;
  SshConnectionState state;
  String? errorMessage;

  SshSession({
    required this.id,
    required this.connectionId,
    required this.connectionName,
    String? displayName,
    this.fontSize = 14,
    required this.outputController,
    this.state = SshConnectionState.connecting,
    this.errorMessage,
  }) : displayName = displayName ?? connectionName;

  Stream<String> get output => outputController.stream;
  bool get isConnected => state == SshConnectionState.connected;
  String get outputText => _outputBuffer.toString();

  void addOutput(String data) {
    _outputBuffer.write(data);
    outputController.add(data);
  }

  Future<void> close() async {
    await outputController.close();
  }
}

class SshService extends ChangeNotifier {
  final StorageService _storageService;
  final FlutterBackgroundService _backgroundService =
      FlutterBackgroundService();

  final Map<String, SshSession> _sessions = {};
  final Map<String, Completer<void>> _connectCompleters = {};
  final Set<String> _closingSessionIds = {};
  final Random _random = Random();
  StreamSubscription<Map<String, dynamic>?>? _stateSub;
  StreamSubscription<Map<String, dynamic>?>? _outputSub;
  StreamSubscription<Map<String, dynamic>?>? _keepAliveSub;
  String? _lastSessionId;
  String? _lastErrorMessage;

  SshService(this._storageService) {
    _listenToBackgroundService();
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

  int activeSessionCountForConnection(String connectionId) {
    return _sessions.values
        .where(
          (session) =>
              session.connectionId == connectionId &&
              (session.state == SshConnectionState.connected ||
                  session.state == SshConnectionState.connecting),
        )
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

  void renameSession(String sessionId, String name) {
    final session = _sessions[sessionId];
    final nextName = name.trim();
    if (session == null || nextName.isEmpty) return;
    session.displayName = nextName;
    notifyListeners();
  }

  void setSessionFontSize(String sessionId, double fontSize) {
    final session = _sessions[sessionId];
    if (session == null) return;
    session.fontSize = fontSize.clamp(1.0, 28.0);
    notifyListeners();
  }

  Future<String?> openSession(String connectionId) async {
    final sessionId = _createSessionId(connectionId);
    await connect(connectionId, sessionId: sessionId);
    final session = _sessions[sessionId];
    if (session?.isConnected == true) return sessionId;

    _lastErrorMessage = session?.errorMessage ?? _lastErrorMessage;
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

  Future<void> connect(String connectionId, {String? sessionId}) async {
    final config = _storageService.getConnection(connectionId);
    if (config == null) {
      _setSessionError(
        sessionId ?? _createSessionId(connectionId),
        connectionId,
        'Unknown',
        'Connection config not found',
      );
      return;
    }

    final id = sessionId ?? _createSessionId(connectionId);
    final defaultDisplayName = _defaultDisplayName(config.name, connectionId);
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
    _lastErrorMessage = null;
    _lastSessionId = id;
    _connectCompleters[id] = Completer<void>();
    notifyListeners();

    try {
      final password = await _storageService.getPassword(connectionId);
      final privateKey = await _storageService.getPrivateKey(connectionId);

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
      });

      await _connectCompleters[id]!.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      _setSessionError(id, connectionId, config.name, 'Connection timed out');
    } catch (e) {
      _setSessionError(id, connectionId, config.name, 'Connection failed: $e');
    }
  }

  Future<void> disconnectSession(String sessionId) async {
    _closingSessionIds.add(sessionId);
    _backgroundService.invoke('sshDisconnect', {'sessionId': sessionId});
    final session = _sessions.remove(sessionId);
    await session?.close();
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
    await session?.close();
    _connectCompleters.remove(sessionId);
    if (_lastSessionId == sessionId) {
      _lastSessionId = _sessions.isEmpty ? null : _sessions.keys.last;
    }
    await _stopServiceIfIdle();
    notifyListeners();
  }

  Future<void> disconnect() async {
    _closingSessionIds.addAll(_sessions.keys);
    _backgroundService.invoke('sshDisconnectAll');
    for (final session in _sessions.values) {
      await session.close();
    }
    _sessions.clear();
    _connectCompleters.clear();
    _lastSessionId = null;
    await BackgroundServiceManager.stop();
    notifyListeners();
  }

  void resizeTerminal(String sessionId, int width, int height) {
    final session = _sessions[sessionId];
    if (session?.isConnected == true) {
      _backgroundService.invoke('sshResize', {
        'sessionId': sessionId,
        'width': width,
        'height': height,
      });
    }
  }

  void sendData(String sessionId, String data) {
    final session = _sessions[sessionId];
    if (session?.isConnected == true) {
      _backgroundService.invoke('sshInput', {
        'sessionId': sessionId,
        'data': data,
      });
    }
  }

  void sendBytes(String sessionId, Uint8List data) {
    sendData(sessionId, String.fromCharCodes(data));
  }

  String _createSessionId(String connectionId) {
    final millis = DateTime.now().millisecondsSinceEpoch;
    final nonce = _random.nextInt(0x7fffffff).toRadixString(16);
    return '$connectionId-$millis-$nonce';
  }

  void _listenToBackgroundService() {
    _stateSub = _backgroundService.on('sshState').listen((event) {
      final sessionId = event?['sessionId'] as String?;
      if (sessionId == null) return;

      final state = event?['state'] as String?;
      final message = event?['message'] as String?;
      final connectionId = event?['connectionId'] as String?;
      final connectionName = event?['connectionName'] as String?;

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

      notifyListeners();
    });

    _outputSub = _backgroundService.on('sshOutput').listen((event) {
      final sessionId = event?['sessionId'] as String?;
      final data = event?['data'] as String?;
      if (sessionId == null || data == null) return;
      _sessions[sessionId]?.addOutput(data);
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
    _lastSessionId = sessionId;
    _completeConnect(sessionId);
    notifyListeners();
  }

  String _notificationSummary() {
    final count = _sessions.values
        .where((session) => session.state != SshConnectionState.disconnected)
        .length;
    return count <= 1 ? '1 SSH session' : '$count SSH sessions';
  }

  String _defaultDisplayName(String connectionName, String connectionId) {
    final existingCount = sessionCountForConnection(connectionId);
    return existingCount == 0
        ? connectionName
        : '$connectionName ${existingCount + 1}';
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
    for (final session in _sessions.values) {
      session.close();
    }
    super.dispose();
  }
}

extension _LastOrNull<T> on Iterable<T> {
  T? get lastOrNull => isEmpty ? null : last;
}
