import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
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
        initialNotificationContent: 'SSH connection is active',
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
          ? 'SSH connection is active'
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
      description:
          'Keeps active SSH sessions alive while the app is in background.',
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

  Timer? heartbeatTimer;

  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();
    service.setForegroundNotificationInfo(
      title: 'SSH Mobile',
      content: 'SSH connection is active',
    );
  }

  service.on('update').listen((event) {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: event?['title'] as String? ?? 'SSH Mobile',
        content: event?['content'] as String? ?? 'SSH connection is active',
      );
    }
  });

  service.on('stopService').listen((event) {
    heartbeatTimer?.cancel();
    service.stopSelf();
  });

  heartbeatTimer = Timer.periodic(const Duration(seconds: 60), (_) {
    service.invoke('heartbeat', {
      'timestamp': DateTime.now().toIso8601String(),
    });
  });
}
