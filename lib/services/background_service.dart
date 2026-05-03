import 'dart:async';
import 'package:flutter_background_service/flutter_background_service.dart';
import '../models/connection.dart';

/// 后台服务管理器 - Android 前台服务保活
class BackgroundServiceManager {
  static bool _isRunning = false;
  static Timer? _heartbeatTimer;

  /// 首次初始化（在 main() 中调用）
  static Future<void> initialize() async {
    final service = FlutterBackgroundService();
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onServiceStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: 'ssh_keep_alive',
        initialNotificationTitle: 'SSH Mobile',
        initialNotificationContent: '准备就绪',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: _onServiceStart,
        onBackground: _onIosBackground,
      ),
    );
  }

  /// 启动后台服务
  static Future<void> start(ConnectionConfig config) async {
    if (_isRunning) return;

    final service = FlutterBackgroundService();

    // 首次配置
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onServiceStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: 'ssh_keep_alive',
        initialNotificationTitle: 'SSH 已连接',
        initialNotificationContent: '${config.name} (${config.host})',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: _onServiceStart,
        onBackground: _onIosBackground,
      ),
    );

    await service.startService();
    _isRunning = true;
  }

  /// 停止后台服务
  static Future<void> stop() async {
    if (!_isRunning) return;
    _heartbeatTimer?.cancel();
    final service = FlutterBackgroundService();
    service.invoke('stopService');
    _isRunning = false;
  }

  /// 更新通知内容
  static Future<void> updateNotification({
    required String host,
    required String status,
  }) async {
    if (!_isRunning) return;
    final service = FlutterBackgroundService();
    service.invoke('updateNotification', {
      'host': host,
      'status': status,
    });
  }

  static bool get isRunning => _isRunning;

  /// Android 服务启动回调（在独立 Isolate 中运行）
  @pragma('vm:entry-point')
  static Future<bool> _onServiceStart(ServiceInstance service) async {
    // 心跳保持
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) {
        service.invoke('heartbeat');
      },
    );

    // 监听停止指令
    service.on('stopService').listen((event) {
      _heartbeatTimer?.cancel();
      service.stopSelf();
    });

    // 更新通知
    service.on('updateNotification').listen((event) {
      if (event != null) {
        final data = event as Map<String, dynamic>;
        service.setNotificationInfo(
          title: 'SSH: ${data['host'] ?? '已连接'}',
          content: data['status'] ?? '连接正常',
        );
      }
    });

    return true;
  }

  /// iOS 后台回调
  @pragma('vm:entry-point')
  static Future<bool> _onIosBackground(ServiceInstance service) async {
    // iOS 后台限制严格，仅维持短暂保活
    return true;
  }
}
