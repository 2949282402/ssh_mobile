import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

class BackgroundServiceManager {
  static const String _channelId = 'ssh_mobile_foreground';
  static const int _notificationId = 1001;
  static const MethodChannel _powerChannel = MethodChannel('ssh_mobile/power');
  static bool _configured = false;
  static bool _notificationPermissionChecked = false;
  static Future<void>? _prewarmFuture;

  static Future<void> initialize() async {
    await _requestNotificationPermission();
    await prewarm();
  }

  static Future<void> prewarm() async {
    if (_configured) return;
    final existing = _prewarmFuture;
    if (existing != null) {
      await existing;
      return;
    }

    final future = _configureService();
    _prewarmFuture = future;
    try {
      await future;
    } finally {
      _prewarmFuture = null;
    }
  }

  static Future<void> _configureService() async {
    if (_configured) return;
    await _createNotificationChannel();

    final service = FlutterBackgroundService();
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: sshBackgroundServiceEntryPoint,
        autoStart: false,
        autoStartOnBoot: false,
        isForegroundMode: true,
        notificationChannelId: _channelId,
        initialNotificationTitle: 'SSH Mobile',
        initialNotificationContent: 'SSH service is ready',
        foregroundServiceNotificationId: _notificationId,
        foregroundServiceTypes: const [AndroidForegroundType.dataSync],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: sshBackgroundServiceEntryPoint,
      ),
    );

    _configured = true;
  }

  static Future<void> start({String? connectionName}) async {
    await initialize();
    await _acquirePowerLocks();
    unawaited(_requestBatteryOptimizationExemption());

    final service = FlutterBackgroundService();
    if (!await service.isRunning()) {
      await service.startService();
    }

    service.invoke('update', {
      'title': 'SSH Mobile',
      'content': connectionName == null || connectionName.isEmpty
          ? 'SSH service is running'
          : 'Connected to $connectionName',
    });
  }

  static Future<void> stop() async {
    final service = FlutterBackgroundService();
    if (await service.isRunning()) {
      service.invoke('stopService');
    }
    await _releasePowerLocks();
  }

  static Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      return await _powerChannel
              .invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestBatteryOptimizationExemption() async {
    try {
      await _powerChannel.invokeMethod<bool>(
        'requestBatteryOptimizationExemption',
      );
    } catch (_) {}
  }

  static Future<void> openAppSettings() async {
    try {
      await _powerChannel.invokeMethod<bool>('openAppSettings');
    } catch (_) {}
  }

  static void updateStatus(String content) {
    FlutterBackgroundService().invoke('update', {
      'title': 'SSH Mobile',
      'content': content,
    });
  }

  static Future<void> _requestNotificationPermission() async {
    if (_notificationPermissionChecked) return;
    _notificationPermissionChecked = true;

    final status = await Permission.notification.status;
    if (status.isDenied || status.isRestricted || status.isLimited) {
      await Permission.notification.request();
    }
  }

  static Future<void> _createNotificationChannel() async {
    const channel = AndroidNotificationChannel(
      _channelId,
      'SSH connection',
      description: 'Keeps active SSH sessions alive in a foreground service.',
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
      showBadge: false,
    );

    final plugin = FlutterLocalNotificationsPlugin();
    await plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  static Future<void> _acquirePowerLocks() async {
    try {
      await _powerChannel.invokeMethod<bool>('acquireLocks');
    } catch (_) {}
  }

  static Future<void> _releasePowerLocks() async {
    try {
      await _powerChannel.invokeMethod<bool>('releaseLocks');
    } catch (_) {}
  }

  static Future<void> _requestBatteryOptimizationExemption() async {
    try {
      final ignoring = await _powerChannel
              .invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
          true;
      if (!ignoring) {
        await _powerChannel.invokeMethod<bool>(
          'requestBatteryOptimizationExemption',
        );
      }
    } catch (_) {}
  }
}

@pragma('vm:entry-point')
void sshBackgroundServiceEntryPoint(ServiceInstance service) {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final sessions = <String, _BackgroundSshSession>{};

  void setNotification(String content) {
    if (service is AndroidServiceInstance) {
      service.setAsForegroundService();
      service.setForegroundNotificationInfo(
        title: 'SSH Mobile',
        content: content,
      );
    }
  }

  void emitState(
    String state, {
    required String sessionId,
    String? message,
    String? connectionId,
    String? connectionName,
  }) {
    service.invoke('sshState', {
      'sessionId': sessionId,
      'state': state,
      if (message != null) 'message': message,
      if (connectionId != null) 'connectionId': connectionId,
      if (connectionName != null) 'connectionName': connectionName,
    });
  }

  String notificationSummary() {
    final count = sessions.length;
    if (count == 0) return 'SSH service is running';
    if (count == 1) {
      return 'Connected to ${sessions.values.first.connectionName}';
    }
    return '$count SSH sessions running';
  }

  void closeSsh(String sessionId, {bool notify = true, String? message}) {
    final session = sessions.remove(sessionId);
    if (session == null) return;
    session.close();
    if (notify) {
      emitState(
        'disconnected',
        sessionId: sessionId,
        message: message ?? 'Connection closed',
        connectionId: session.connectionId,
        connectionName: session.connectionName,
      );
      setNotification(notificationSummary());
    }
  }

  void closeAll({bool notify = true}) {
    final ids = sessions.keys.toList();
    for (final sessionId in ids) {
      closeSsh(sessionId, notify: notify);
    }
    setNotification('SSH service is running');
  }

  String sanitizeTmuxSessionName(String name) {
    final sanitized = name
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (sanitized.isEmpty) return 'ssh_mobile';
    return sanitized.length > 80 ? sanitized.substring(0, 80) : sanitized;
  }

  String buildTmuxAttachCommand(String sessionName, int autoDeleteSeconds) {
    final safeName = sanitizeTmuxSessionName(sessionName);
    final seconds = autoDeleteSeconds.clamp(30, 86400);
    final hook = 'run-shell "sleep $seconds; tmux list-clients -t $safeName '
        '2>/dev/null | grep -q . || tmux kill-session -t $safeName '
        '2>/dev/null"';
    return 'if command -v tmux >/dev/null 2>&1; then '
        'tmux has-session -t $safeName 2>/dev/null || '
        'tmux new-session -d -s $safeName; '
        "tmux set-hook -t $safeName client-detached '$hook'; "
        'tmux attach-session -t $safeName; '
        'else echo "tmux is not installed on this server"; exit 127; fi';
  }

  String buildTmuxInstallCommand() {
    return r'''
if command -v tmux >/dev/null 2>&1; then
  echo "tmux is already installed"
  exit 0
fi

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo -n"
else
  echo "tmux is missing and sudo is not available"
  exit 126
fi

if command -v apt-get >/dev/null 2>&1; then
  $SUDO apt-get update && $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y tmux
elif command -v dnf >/dev/null 2>&1; then
  $SUDO dnf install -y tmux
elif command -v yum >/dev/null 2>&1; then
  $SUDO yum install -y tmux
elif command -v pacman >/dev/null 2>&1; then
  $SUDO pacman -Sy --noconfirm tmux
elif command -v zypper >/dev/null 2>&1; then
  $SUDO zypper --non-interactive install tmux
elif command -v apk >/dev/null 2>&1; then
  $SUDO apk add tmux
elif command -v pkg >/dev/null 2>&1; then
  $SUDO pkg install -y tmux
else
  echo "No supported package manager found for installing tmux"
  exit 127
fi

command -v tmux >/dev/null 2>&1
''';
  }

  Future<void> installTmuxIfAllowed({
    required SSHClient client,
    required bool allowTmuxInstall,
    required String sessionId,
    required ServiceInstance service,
  }) async {
    late final SSHRunResult tmuxCheck;
    try {
      tmuxCheck = await client
          .runWithResult('command -v tmux >/dev/null 2>&1')
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      throw StateError(
        'Unable to check tmux on this server. Please install tmux manually '
        'on the server and try again. Detail: $e',
      );
    }
    if (tmuxCheck.exitCode == 0) return;

    if (!allowTmuxInstall) {
      throw StateError('tmux is not installed on this server');
    }

    service.invoke('sshOutput', {
      'sessionId': sessionId,
      'data':
          '\r\n\x1b[33m[tmux is missing, installing on the server...]\x1b[0m\r\n',
    });

    late final SSHRunResult installResult;
    try {
      installResult = await client
          .runWithResult(buildTmuxInstallCommand(), runInPty: true)
          .timeout(const Duration(minutes: 5));
    } catch (e) {
      throw StateError(
        'tmux automatic install failed. Please install tmux manually on the '
        'server and try again. Detail: $e',
      );
    }
    final output = utf8.decode(installResult.output, allowMalformed: true);
    if (output.trim().isNotEmpty) {
      service.invoke('sshOutput', {
        'sessionId': sessionId,
        'data': '$output\r\n',
      });
    }

    if (installResult.exitCode != 0) {
      final detail = output.trim();
      final tail =
          detail.length > 500 ? detail.substring(detail.length - 500) : detail;
      throw StateError(
        'tmux automatic install failed with exit code '
        '${installResult.exitCode}. Please install tmux manually on the '
        'server and try again${tail.isEmpty ? '' : '. Detail: $tail'}',
      );
    }
  }

  Future<void> connectSsh(Map<String, dynamic> data) async {
    final sessionId = data['sessionId'] as String?;
    if (sessionId == null || sessionId.isEmpty) {
      return;
    }
    closeSsh(sessionId, notify: false);
    final connectionId = data['id'] as String?;
    final name = data['name'] as String? ?? 'server';
    emitState(
      'connecting',
      sessionId: sessionId,
      connectionId: connectionId,
      connectionName: name,
    );
    setNotification('Connecting to $name...');

    try {
      final host = data['host'] as String;
      final port = (data['port'] as num?)?.toInt() ?? 22;
      final username = data['username'] as String;
      final authMethod = data['authMethod'] as String? ?? 'password';
      final password = data['password'] as String?;
      final privateKey = data['privateKey'] as String?;
      final width = (data['terminalWidth'] as num?)?.toInt() ?? 80;
      final height = (data['terminalHeight'] as num?)?.toInt() ?? 24;
      final keepAliveSeconds =
          (data['keepAliveInterval'] as num?)?.toInt() ?? 3;
      final launchMode = data['launchMode'] as String? ?? 'ssh';
      final allowTmuxInstall = data['allowTmuxInstall'] as bool? ?? false;
      final tmuxSessionName =
          sanitizeTmuxSessionName(data['tmuxSessionName'] as String? ?? name);
      final tmuxAutoDeleteSeconds =
          ((data['tmuxAutoDeleteSeconds'] as num?)?.toInt() ?? 600)
              .clamp(30, 86400);

      final socket = await SSHSocket.connect(
        host,
        port,
        timeout: const Duration(seconds: 15),
      );

      final identities = (authMethod == 'privateKey' || authMethod == 'both') &&
              privateKey != null &&
              privateKey.isNotEmpty
          ? SSHKeyPair.fromPem(privateKey, password)
          : null;

      final client = SSHClient(
        socket,
        username: username,
        identities: identities,
        onPasswordRequest: () {
          if (authMethod == 'privateKey') return null;
          return password?.isNotEmpty == true ? password : null;
        },
      );

      if (launchMode == 'tmux') {
        try {
          await installTmuxIfAllowed(
            client: client,
            allowTmuxInstall: allowTmuxInstall,
            sessionId: sessionId,
            service: service,
          );
        } catch (_) {
          client.close();
          rethrow;
        }
      }

      final shell = await client.shell(
        pty: SSHPtyConfig(
          width: width,
          height: height,
          type: 'xterm-256color',
        ),
      );

      final runtime = _BackgroundSshSession(
        sessionId: sessionId,
        connectionId: connectionId,
        connectionName: name,
        tmuxSessionName: launchMode == 'tmux' ? tmuxSessionName : null,
        tmuxAutoDeleteSeconds: tmuxAutoDeleteSeconds,
        launchMode: launchMode,
        reconnectData: Map<String, dynamic>.from(data),
        client: client,
        shell: shell,
      );
      sessions[sessionId] = runtime;

      runtime.stdoutSub = shell.stdout.listen(
        (bytes) {
          service.invoke('sshOutput', {
            'sessionId': sessionId,
            'data': utf8.decode(bytes, allowMalformed: true),
          });
        },
        onError: (Object error) {
          service.invoke('sshOutput', {
            'sessionId': sessionId,
            'data': '\r\n\x1b[31m[Connection error: $error]\x1b[0m\r\n',
          });
          closeSsh(sessionId);
        },
        onDone: () => closeSsh(sessionId),
      );

      runtime.stderrSub = shell.stderr.listen(
        (bytes) {
          service.invoke('sshOutput', {
            'sessionId': sessionId,
            'data': utf8.decode(bytes, allowMalformed: true),
          });
        },
      );

      if (launchMode == 'tmux') {
        final command = buildTmuxAttachCommand(
          tmuxSessionName,
          tmuxAutoDeleteSeconds,
        );
        shell.stdin.add(utf8.encode('$command\r'));
      }

      runtime.keepAliveTimer = Timer.periodic(
        Duration(seconds: keepAliveSeconds.clamp(3, 30)),
        (_) async {
          if (runtime.pingInFlight) return;
          runtime.pingInFlight = true;
          try {
            await runtime.client.ping().timeout(const Duration(seconds: 10));
            runtime.keepAliveFailures = 0;
            service.invoke('sshKeepAlive', {
              'sessionId': sessionId,
              'ok': true,
              'timestamp': DateTime.now().toIso8601String(),
            });
          } catch (e) {
            service.invoke('sshKeepAlive', {
              'sessionId': sessionId,
              'ok': false,
              'error': e.toString(),
              'timestamp': DateTime.now().toIso8601String(),
            });
            if (!sessions.containsKey(runtime.sessionId) ||
                runtime.reconnecting) {
              return;
            }
            runtime.keepAliveFailures++;
            if (runtime.launchMode == 'tmux') {
              runtime.reconnecting = true;
              service.invoke('sshOutput', {
                'sessionId': runtime.sessionId,
                'data':
                    '\r\n\x1b[33m[Connection lost, reconnecting tmux session...]\x1b[0m\r\n',
              });
              closeSsh(runtime.sessionId, notify: false);
              unawaited(connectSsh(runtime.reconnectData));
            } else {
              closeSsh(
                runtime.sessionId,
                message: 'Connection lost: $e',
              );
            }
          } finally {
            runtime.pingInFlight = false;
          }
        },
      );

      emitState(
        'connected',
        sessionId: sessionId,
        connectionId: connectionId,
        connectionName: name,
      );
      setNotification(notificationSummary());
    } catch (e) {
      closeSsh(sessionId, notify: false);
      emitState(
        'error',
        sessionId: sessionId,
        message: 'Connection failed: $e',
        connectionId: connectionId,
        connectionName: name,
      );
      setNotification('SSH connection failed');
    }
  }

  setNotification('SSH service is running');

  service.on('sshConnect').listen((event) {
    if (event != null) {
      unawaited(connectSsh(event));
    }
  });

  service.on('sshInput').listen((event) {
    final sessionId = event?['sessionId'] as String?;
    final data = event?['data'] as String?;
    final session = sessionId == null ? null : sessions[sessionId];
    if (data != null && session != null) {
      session.shell.stdin.add(utf8.encode(data));
    }
  });

  service.on('sshResize').listen((event) {
    final sessionId = event?['sessionId'] as String?;
    final width = (event?['width'] as num?)?.toInt();
    final height = (event?['height'] as num?)?.toInt();
    final session = sessionId == null ? null : sessions[sessionId];
    if (width != null && height != null && session != null) {
      session.shell.resizeTerminal(width, height);
    }
  });

  service.on('sshDisconnect').listen((event) {
    final sessionId = event?['sessionId'] as String?;
    if (sessionId != null) {
      closeSsh(sessionId);
    }
  });

  service.on('sshDisconnectAll').listen((event) {
    closeAll();
  });

  service.on('update').listen((event) {
    setNotification(
      event?['content'] as String? ?? 'SSH service is running',
    );
  });

  service.on('stopService').listen((event) {
    closeAll(notify: false);
    service.stopSelf();
  });
}

class _BackgroundSshSession {
  final String sessionId;
  final String? connectionId;
  final String connectionName;
  final String? tmuxSessionName;
  final int tmuxAutoDeleteSeconds;
  final String launchMode;
  final Map<String, dynamic> reconnectData;
  final SSHClient client;
  final SSHSession shell;
  StreamSubscription<List<int>>? stdoutSub;
  StreamSubscription<List<int>>? stderrSub;
  Timer? keepAliveTimer;
  bool pingInFlight = false;
  bool reconnecting = false;
  int keepAliveFailures = 0;

  _BackgroundSshSession({
    required this.sessionId,
    required this.connectionId,
    required this.connectionName,
    required this.tmuxSessionName,
    required this.tmuxAutoDeleteSeconds,
    required this.launchMode,
    required this.reconnectData,
    required this.client,
    required this.shell,
  });

  void close() {
    keepAliveTimer?.cancel();
    stdoutSub?.cancel();
    stderrSub?.cancel();
    shell.close();
    client.close();
    pingInFlight = false;
  }
}
