import 'dart:async';
import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../models/connection.dart';
import 'background_service.dart';
import 'storage_service.dart';

enum SshConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

class SshSession {
  final SSHClient client;
  final SSHSession session;
  final StreamController<String> outputController;
  final StreamSubscription<Uint8List> _stdoutSub;
  final StreamSubscription<Uint8List> _stderrSub;

  SshSession({
    required this.client,
    required this.session,
    required this.outputController,
    required StreamSubscription<Uint8List> stdoutSub,
    required StreamSubscription<Uint8List> stderrSub,
  })  : _stdoutSub = stdoutSub,
        _stderrSub = stderrSub;

  Stream<String> get output => outputController.stream;

  void write(String data) {
    session.stdin.add(utf8.encode(data));
  }

  void writeBytes(Uint8List data) {
    session.stdin.add(data);
  }

  void resize(int width, int height) {
    session.resizeTerminal(width, height);
  }

  Future<void> close() async {
    await _stdoutSub.cancel();
    await _stderrSub.cancel();
    await outputController.close();
    session.close();
    client.close();
  }
}

class SshService extends ChangeNotifier {
  final StorageService _storageService;

  SshConnectionState _state = SshConnectionState.disconnected;
  String? _errorMessage;
  SshSession? _currentSession;
  String? _activeConnectionId;
  Timer? _keepAliveTimer;
  int _keepAliveFailures = 0;
  bool _keepAliveInFlight = false;

  SshConnectionState get state => _state;
  String? get errorMessage => _errorMessage;
  SshSession? get currentSession => _currentSession;
  bool get isConnected => _state == SshConnectionState.connected;
  String? get activeConnectionId => _activeConnectionId;

  SshService(this._storageService);

  Future<bool> ensureConnected(String connectionId) async {
    if (_activeConnectionId == connectionId && isConnected) {
      final ok = await _probeCurrentSession();
      if (ok) return true;

      debugPrint('SSH session probe failed; reconnecting.');
      _markConnectionLost('Connection lost while app was in background');
    }

    await connect(connectionId);
    return _activeConnectionId == connectionId && isConnected;
  }

  Future<void> connect(String connectionId) async {
    if (_state == SshConnectionState.connecting) return;

    if (_currentSession != null) {
      await disconnect();
    }
    _keepAliveFailures = 0;

    final config = _storageService.getConnection(connectionId);
    if (config == null) {
      _setError('Connection config not found');
      return;
    }

    _state = SshConnectionState.connecting;
    _errorMessage = null;
    _activeConnectionId = connectionId;
    notifyListeners();

    try {
      final password = await _storageService.getPassword(connectionId);
      final privateKey = await _storageService.getPrivateKey(connectionId);

      final socket = await SSHSocket.connect(
        config.host,
        config.port,
        timeout: const Duration(seconds: 15),
      );

      final identities = (config.authMethod == AuthMethod.privateKey ||
                  config.authMethod == AuthMethod.both) &&
              privateKey != null &&
              privateKey.isNotEmpty
          ? SSHKeyPair.fromPem(privateKey, password)
          : null;

      final client = SSHClient(
        socket,
        username: config.username,
        identities: identities,
        keepAliveInterval: Duration(seconds: _keepAliveIntervalSeconds(config)),
        onPasswordRequest: () {
          if (config.authMethod == AuthMethod.privateKey) {
            return null;
          }
          return password?.isNotEmpty == true ? password : null;
        },
      );

      final session = await client.shell(
        pty: SSHPtyConfig(
          width: config.terminalWidth,
          height: config.terminalHeight,
          type: 'xterm-256color',
        ),
      );

      final outputController = StreamController<String>.broadcast();

      final stdoutSub = session.stdout.listen(
        (data) {
          outputController.add(utf8.decode(data, allowMalformed: true));
        },
        onError: (error) {
          debugPrint('SSH stdout error: $error');
          outputController
              .add('\r\n\x1b[31m[Connection error: $error]\x1b[0m\r\n');
          _handleDisconnect();
        },
        onDone: () {
          debugPrint('SSH stdout done');
          _handleDisconnect();
        },
      );

      final stderrSub = session.stderr.listen(
        (data) {
          outputController.add(utf8.decode(data, allowMalformed: true));
        },
        onError: (error) {
          debugPrint('SSH stderr error: $error');
        },
      );

      _currentSession = SshSession(
        client: client,
        session: session,
        outputController: outputController,
        stdoutSub: stdoutSub,
        stderrSub: stderrSub,
      );

      _state = SshConnectionState.connected;
      _keepAliveFailures = 0;

      if (config.keepAlive) {
        _startKeepAlive(config);
        try {
          await BackgroundServiceManager.start(connectionName: config.name);
          BackgroundServiceManager.updateStatus(
            'Connected to ${config.name} - keep-alive every '
            '${_keepAliveIntervalSeconds(config)}s',
          );
        } catch (e) {
          debugPrint('Failed to start background service: $e');
        }
      } else {
        unawaited(BackgroundServiceManager.stop());
      }

      notifyListeners();
    } on TimeoutException {
      _activeConnectionId = null;
      _setError('Connection timed out');
    } on SSHMessageError catch (e) {
      _activeConnectionId = null;
      _setError('SSH connection failed: ${e.message}');
    } on SSHError catch (e) {
      _activeConnectionId = null;
      _setError('SSH connection failed: $e');
    } catch (e) {
      _activeConnectionId = null;
      _setError('Connection failed: $e');
    }
  }

  Future<void> disconnect() async {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _keepAliveFailures = 0;
    _keepAliveInFlight = false;

    final session = _currentSession;
    _currentSession = null;
    if (session != null) {
      try {
        await session.close();
      } catch (_) {}
    }

    _state = SshConnectionState.disconnected;
    _activeConnectionId = null;
    _errorMessage = null;

    try {
      await BackgroundServiceManager.stop();
    } catch (e) {
      debugPrint('Failed to stop background service: $e');
    }
    notifyListeners();
  }

  void resizeTerminal(int width, int height) {
    if (_currentSession != null && isConnected) {
      _currentSession!.resize(width, height);
    }
  }

  void sendData(String data) {
    if (_currentSession != null && isConnected) {
      _currentSession!.write(data);
    }
  }

  void sendBytes(Uint8List data) {
    if (_currentSession != null && isConnected) {
      _currentSession!.writeBytes(data);
    }
  }

  void _startKeepAlive(ConnectionConfig config) {
    _keepAliveTimer?.cancel();
    _keepAliveFailures = 0;
    _keepAliveInFlight = false;
    _keepAliveTimer = Timer.periodic(
      Duration(seconds: _keepAliveIntervalSeconds(config)),
      (_) {
        if (_currentSession != null && isConnected) {
          unawaited(_sendKeepAlivePing());
        }
      },
    );
  }

  Future<void> _sendKeepAlivePing() async {
    final session = _currentSession;
    if (session == null || !isConnected || _keepAliveInFlight) return;

    _keepAliveInFlight = true;
    try {
      await _pingSession(session, timeout: const Duration(seconds: 20));
      _keepAliveFailures = 0;
    } catch (e) {
      _keepAliveFailures += 1;
      debugPrint('Keep-alive failed ($_keepAliveFailures/3): $e');
    } finally {
      _keepAliveInFlight = false;
    }
  }

  int _keepAliveIntervalSeconds(ConnectionConfig config) {
    return 3;
  }

  void _handleDisconnect() {
    if (_state == SshConnectionState.disconnected) return;
    _keepAliveTimer?.cancel();
    _keepAliveFailures = 0;
    _keepAliveInFlight = false;
    _state = SshConnectionState.disconnected;
    _currentSession = null;
    _errorMessage = 'Connection closed';
    unawaited(BackgroundServiceManager.stop());
    notifyListeners();
  }

  Future<bool> _probeCurrentSession() async {
    final session = _currentSession;
    if (session == null || !isConnected) return false;

    try {
      await _pingSession(session, timeout: const Duration(seconds: 5));
      _keepAliveFailures = 0;
      return true;
    } catch (e) {
      debugPrint('SSH probe failed: $e');
      return false;
    }
  }

  Future<void> _pingSession(
    SshSession session, {
    required Duration timeout,
  }) {
    return session.client.ping().timeout(timeout);
  }

  void _markConnectionLost(String message) {
    _keepAliveTimer?.cancel();
    _keepAliveFailures = 0;
    _keepAliveInFlight = false;
    final session = _currentSession;
    _state = SshConnectionState.disconnected;
    _currentSession = null;
    _errorMessage = message;
    if (session != null) {
      unawaited(session.close());
    }
    unawaited(BackgroundServiceManager.stop());
    notifyListeners();
  }

  void _setError(String message) {
    _state = SshConnectionState.error;
    _errorMessage = message;
    Future.delayed(const Duration(seconds: 5), () {
      if (_state == SshConnectionState.error) {
        _state = SshConnectionState.disconnected;
        notifyListeners();
      }
    });
    notifyListeners();
  }

  @override
  void dispose() {
    _keepAliveTimer?.cancel();
    _currentSession?.close();
    super.dispose();
  }
}
