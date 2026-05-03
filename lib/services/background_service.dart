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

  static Future<void> initialize() async {
    if (_configured) return;

    await _requestNotificationPermission();
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

  SSHClient? client;
  SSHSession? shell;
  StreamSubscription<List<int>>? stdoutSub;
  StreamSubscription<List<int>>? stderrSub;
  Timer? keepAliveTimer;
  bool pingInFlight = false;

  void setNotification(String content) {
    if (service is AndroidServiceInstance) {
      service.setAsForegroundService();
      service.setForegroundNotificationInfo(
        title: 'SSH Mobile',
        content: content,
      );
    }
  }

  void emitState(String state, {String? message, String? connectionId}) {
    service.invoke('sshState', {
      'state': state,
      if (message != null) 'message': message,
      if (connectionId != null) 'connectionId': connectionId,
    });
  }

  void closeSsh({bool notify = true}) {
    keepAliveTimer?.cancel();
    keepAliveTimer = null;
    stdoutSub?.cancel();
    stderrSub?.cancel();
    stdoutSub = null;
    stderrSub = null;
    shell?.close();
    client?.close();
    shell = null;
    client = null;
    pingInFlight = false;
    if (notify) {
      emitState('disconnected', message: 'Connection closed');
      setNotification('SSH service is running');
    }
  }

  Future<void> connectSsh(Map<String, dynamic> data) async {
    closeSsh(notify: false);

    final connectionId = data['id'] as String?;
    final name = data['name'] as String? ?? 'server';
    emitState('connecting', connectionId: connectionId);
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

      client = SSHClient(
        socket,
        username: username,
        identities: identities,
        onPasswordRequest: () {
          if (authMethod == 'privateKey') return null;
          return password?.isNotEmpty == true ? password : null;
        },
      );

      shell = await client!.shell(
        pty: SSHPtyConfig(
          width: width,
          height: height,
          type: 'xterm-256color',
        ),
      );

      stdoutSub = shell!.stdout.listen(
        (bytes) {
          service.invoke('sshOutput', {
            'data': utf8.decode(bytes, allowMalformed: true),
          });
        },
        onError: (Object error) {
          service.invoke('sshOutput', {
            'data': '\r\n\x1b[31m[Connection error: $error]\x1b[0m\r\n',
          });
          closeSsh();
        },
        onDone: closeSsh,
      );

      stderrSub = shell!.stderr.listen(
        (bytes) {
          service.invoke('sshOutput', {
            'data': utf8.decode(bytes, allowMalformed: true),
          });
        },
      );

      keepAliveTimer = Timer.periodic(
        Duration(seconds: keepAliveSeconds.clamp(3, 30)),
        (_) async {
          final activeClient = client;
          if (activeClient == null || pingInFlight) return;
          pingInFlight = true;
          try {
            await activeClient.ping().timeout(const Duration(seconds: 10));
            service.invoke('sshKeepAlive', {
              'ok': true,
              'timestamp': DateTime.now().toIso8601String(),
            });
          } catch (e) {
            service.invoke('sshKeepAlive', {
              'ok': false,
              'error': e.toString(),
              'timestamp': DateTime.now().toIso8601String(),
            });
          } finally {
            pingInFlight = false;
          }
        },
      );

      emitState('connected', connectionId: connectionId);
      setNotification('Connected to $name - service keep-alive every 3s');
    } catch (e) {
      closeSsh(notify: false);
      emitState(
        'error',
        message: 'Connection failed: $e',
        connectionId: connectionId,
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
    final data = event?['data'] as String?;
    if (data != null && shell != null) {
      shell!.stdin.add(utf8.encode(data));
    }
  });

  service.on('sshResize').listen((event) {
    final width = (event?['width'] as num?)?.toInt();
    final height = (event?['height'] as num?)?.toInt();
    if (width != null && height != null && shell != null) {
      shell!.resizeTerminal(width, height);
    }
  });

  service.on('sshDisconnect').listen((event) {
    closeSsh();
  });

  service.on('update').listen((event) {
    setNotification(
      event?['content'] as String? ?? 'SSH service is running',
    );
  });

  service.on('stopService').listen((event) {
    closeSsh(notify: false);
    service.stopSelf();
  });
}
