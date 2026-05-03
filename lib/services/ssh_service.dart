import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:dartssh2/dartssh2.dart';

import '../models/connection.dart';
import 'storage_service.dart';
import 'background_service.dart';

/// SSH 连接状态
enum SshConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

/// SSH 会话数据（终端输出流 + 输入流）
class SshSession {
  final SSHClient client;
  final SSHSession session;

  /// stdout 流（已经是 UTF-8 解码的字符串流）
  final StreamController<String> outputController;
  final StreamSubscription<Uint8List> _stdoutSub;

  SshSession({
    required this.client,
    required this.session,
    required this.outputController,
    required StreamSubscription<Uint8List> stdoutSub,
  }) : _stdoutSub = stdoutSub;

  Stream<String> get output => outputController.stream;

  /// 发送输入到 SSH
  void write(String data) {
    session.stdin.add(utf8.encode(data));
  }

  /// 发送原始字节
  void writeBytes(Uint8List data) {
    session.stdin.add(data);
  }

  /// 调整终端大小
  void resize(int width, int height) {
    session.resize(
      width,
      height,
      0, // pixel width (optional)
      0, // pixel height (optional)
    );
  }

  /// 关闭会话
  void close() {
    _stdoutSub.cancel();
    outputController.close();
    session.close();
    client.close();
  }
}

/// SSH 连接服务 - 管理连接生命周期
class SshService extends ChangeNotifier {
  final StorageService _storageService;

  SshConnectionState _state = SshConnectionState.disconnected;
  String? _errorMessage;
  SshSession? _currentSession;
  String? _activeConnectionId;
  Timer? _keepAliveTimer;

  SshConnectionState get state => _state;
  String? get errorMessage => _errorMessage;
  SshSession? get currentSession => _currentSession;
  bool get isConnected => _state == SshConnectionState.connected;
  String? get activeConnectionId => _activeConnectionId;

  SshService(this._storageService);

  /// 连接到服务器
  Future<void> connect(String connectionId) async {
    if (_state == SshConnectionState.connecting) return;

    // 如果已有连接，先断开
    if (_currentSession != null) {
      await disconnect();
    }

    final config = _storageService.getConnection(connectionId);
    if (config == null) {
      _setError('连接配置不存在');
      return;
    }

    _state = SshConnectionState.connecting;
    _errorMessage = null;
    _activeConnectionId = connectionId;
    notifyListeners();

    try {
      // 获取认证凭据
      final password = await _storageService.getPassword(connectionId);
      final privateKey = await _storageService.getPrivateKey(connectionId);

      // 创建 SSH Socket
      final socket = await SSHSocket.connect(
        config.host,
        config.port,
        timeout: const Duration(seconds: 15),
      );

      // 创建 SSH 客户端
      SSHClient client;

      if (config.authMethod == AuthMethod.privateKey) {
        client = SSHClient(
          socket,
          username: config.username,
          identities: privateKey != null
              ? [SSHKeyPair.fromPem(privateKey)]
              : [],
          onPasswordRequest: () {
            // 私钥本身可能带密码保护
            if (password != null && password.isNotEmpty) {
              return password;
            }
            throw SSHException('需要私钥密码');
          },
        );
      } else {
        // 密码认证
        client = SSHClient(
          socket,
          username: config.username,
          onPasswordRequest: () {
            if (password != null && password.isNotEmpty) {
              return password;
            }
            throw SSHException('认证失败：密码为空');
          },
        );
      }

      // 请求 PTY 并启动 Shell
      final session = await client.shell(
        pty: SSHPtyConfig(
          width: config.terminalWidth,
          height: config.terminalHeight,
          term: 'xterm-256color',
        ),
      );

      // 创建输出流
      final outputController = StreamController<String>.broadcast();

      final stdoutSub = session.stdout.listen(
        (data) {
          // 直接传原始 UTF-8 字节给终端
          outputController.add(utf8.decode(data, allowMalformed: true));
        },
        onError: (error) {
          debugPrint('SSH stdout error: $error');
          outputController.add('\r\n\x1b[31m[连接中断: $error]\x1b[0m\r\n');
          _handleDisconnect();
        },
        onDone: () {
          debugPrint('SSH stdout done');
          _handleDisconnect();
        },
      );

      // 监听 stderr
      session.stderr.listen(
        (data) {
          debugPrint('SSH stderr: ${utf8.decode(data)}');
        },
      );

      _currentSession = SshSession(
        client: client,
        session: session,
        outputController: outputController,
        stdoutSub: stdoutSub,
      );

      _state = SshConnectionState.connected;

      // 启动后台保活
      if (config.keepAlive) {
        await BackgroundServiceManager.start(config);
        _startKeepAlive(config);
      }

      notifyListeners();
    } on SSHException catch (e) {
      _setError('SSH 连接失败: ${e.message}');
      _activeConnectionId = null;
    } on TimeoutException {
      _setError('连接超时，请检查服务器地址和端口');
      _activeConnectionId = null;
    } catch (e) {
      _setError('连接失败: $e');
      _activeConnectionId = null;
    }
  }

  /// 断开连接
  Future<void> disconnect() async {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;

    if (_currentSession != null) {
      try {
        _currentSession!.close();
      } catch (_) {}
      _currentSession = null;
    }

    _state = SshConnectionState.disconnected;
    _activeConnectionId = null;
    _errorMessage = null;

    await BackgroundServiceManager.stop();
    notifyListeners();
  }

  /// 调整终端大小
  void resizeTerminal(int width, int height) {
    if (_currentSession != null && isConnected) {
      _currentSession!.resize(width, height);
    }
  }

  /// 发送数据到 SSH session
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

  /// 心跳保活
  void _startKeepAlive(ConnectionConfig config) {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(
      Duration(seconds: config.keepAliveInterval),
      (_) {
        if (_currentSession != null && isConnected) {
          try {
            _currentSession!.client.sendKeepAlive();
          } catch (e) {
            debugPrint('心跳失败: $e');
            _handleDisconnect();
          }
        }
      },
    );
  }

  /// 处理意外断连
  void _handleDisconnect() {
    if (_state == SshConnectionState.disconnected) return;
    _keepAliveTimer?.cancel();
    _state = SshConnectionState.disconnected;
    _currentSession = null;
    _errorMessage = '连接已断开';
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
