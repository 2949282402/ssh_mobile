import 'dart:async';

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
  final StreamController<String> outputController;

  SshSession({required this.outputController});

  Stream<String> get output => outputController.stream;

  Future<void> close() async {
    await outputController.close();
  }
}

class SshService extends ChangeNotifier {
  final StorageService _storageService;
  final FlutterBackgroundService _backgroundService =
      FlutterBackgroundService();

  SshConnectionState _state = SshConnectionState.disconnected;
  String? _errorMessage;
  SshSession? _currentSession;
  String? _activeConnectionId;
  StreamSubscription<Map<String, dynamic>?>? _stateSub;
  StreamSubscription<Map<String, dynamic>?>? _outputSub;
  StreamSubscription<Map<String, dynamic>?>? _keepAliveSub;
  Completer<void>? _connectCompleter;

  SshConnectionState get state => _state;
  String? get errorMessage => _errorMessage;
  SshSession? get currentSession => _currentSession;
  bool get isConnected => _state == SshConnectionState.connected;
  String? get activeConnectionId => _activeConnectionId;

  SshService(this._storageService) {
    _listenToBackgroundService();
  }

  Future<bool> ensureConnected(String connectionId) async {
    if (_activeConnectionId == connectionId && isConnected) {
      return true;
    }

    await connect(connectionId);
    return _activeConnectionId == connectionId && isConnected;
  }

  Future<void> connect(String connectionId) async {
    if (_state == SshConnectionState.connecting) return;

    final config = _storageService.getConnection(connectionId);
    if (config == null) {
      _setError('Connection config not found');
      return;
    }

    _currentSession ??= SshSession(
      outputController: StreamController<String>.broadcast(),
    );
    _state = SshConnectionState.connecting;
    _errorMessage = null;
    _activeConnectionId = connectionId;
    _connectCompleter = Completer<void>();
    notifyListeners();

    try {
      final password = await _storageService.getPassword(connectionId);
      final privateKey = await _storageService.getPrivateKey(connectionId);

      await BackgroundServiceManager.start(connectionName: config.name);
      _backgroundService.invoke('sshConnect', {
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

      await _connectCompleter!.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      _activeConnectionId = null;
      _setError('Connection timed out');
    } catch (e) {
      _activeConnectionId = null;
      _setError('Connection failed: $e');
    }
  }

  Future<void> disconnect() async {
    _backgroundService.invoke('sshDisconnect');
    await BackgroundServiceManager.stop();
    await _currentSession?.close();
    _currentSession = null;
    _state = SshConnectionState.disconnected;
    _activeConnectionId = null;
    _errorMessage = null;
    notifyListeners();
  }

  void resizeTerminal(int width, int height) {
    if (isConnected) {
      _backgroundService.invoke('sshResize', {
        'width': width,
        'height': height,
      });
    }
  }

  void sendData(String data) {
    if (isConnected) {
      _backgroundService.invoke('sshInput', {'data': data});
    }
  }

  void sendBytes(Uint8List data) {
    sendData(String.fromCharCodes(data));
  }

  void _listenToBackgroundService() {
    _stateSub = _backgroundService.on('sshState').listen((event) {
      final state = event?['state'] as String?;
      final message = event?['message'] as String?;
      final connectionId = event?['connectionId'] as String?;

      switch (state) {
        case 'connecting':
          _state = SshConnectionState.connecting;
          _errorMessage = null;
          _activeConnectionId = connectionId ?? _activeConnectionId;
          break;
        case 'connected':
          _state = SshConnectionState.connected;
          _errorMessage = null;
          _activeConnectionId = connectionId ?? _activeConnectionId;
          _completeConnect();
          break;
        case 'disconnected':
          _state = SshConnectionState.disconnected;
          _errorMessage = message;
          _activeConnectionId = null;
          _completeConnect();
          break;
        case 'error':
          _state = SshConnectionState.error;
          _errorMessage = message ?? 'SSH connection failed';
          _activeConnectionId = connectionId ?? _activeConnectionId;
          _completeConnect();
          break;
      }

      notifyListeners();
    });

    _outputSub = _backgroundService.on('sshOutput').listen((event) {
      final data = event?['data'] as String?;
      if (data != null) {
        _currentSession?.outputController.add(data);
      }
    });

    _keepAliveSub = _backgroundService.on('sshKeepAlive').listen((event) {
      if (event?['ok'] == false) {
        debugPrint('Service keep-alive failed: ${event?['error']}');
      }
    });
  }

  void _completeConnect() {
    final completer = _connectCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void _setError(String message) {
    _state = SshConnectionState.error;
    _errorMessage = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _outputSub?.cancel();
    _keepAliveSub?.cancel();
    _currentSession?.close();
    super.dispose();
  }
}
