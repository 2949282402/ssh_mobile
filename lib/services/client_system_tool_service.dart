import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app_log_service.dart';

class ClientSystemToolService {
  static final ClientSystemToolService instance = ClientSystemToolService._();

  static const String _channelId = 'ssh_mobile_client_tools';
  static const MethodChannel _systemChannel =
      MethodChannel('ssh_mobile/client_system');

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  final Map<String, _ClientAlarm> _alarms = {};
  Future<void>? _initFuture;
  int _nextNotificationId = 2200;

  ClientSystemToolService._();

  Map<String, dynamic> getClientTime() {
    final now = DateTime.now();
    final utc = now.toUtc();
    return {
      'execution': 'client',
      'target': 'client_device',
      'nowLocal': now.toIso8601String(),
      'nowUtc': utc.toIso8601String(),
      'epochMilliseconds': now.millisecondsSinceEpoch,
      'timezoneName': now.timeZoneName,
      'timezoneOffsetMinutes': now.timeZoneOffset.inMinutes,
      'timezoneOffset': _formatOffset(now.timeZoneOffset),
      'localeName': Platform.localeName,
    };
  }

  Map<String, dynamic> getClientDeviceInfo() {
    final now = DateTime.now();
    return {
      'execution': 'client',
      'target': 'client_device',
      'flutterPlatform': defaultTargetPlatform.name,
      'dartOperatingSystem': Platform.operatingSystem,
      'operatingSystemVersion': Platform.operatingSystemVersion,
      'localeName': Platform.localeName,
      'localHostname': Platform.localHostname,
      'numberOfProcessors': Platform.numberOfProcessors,
      'timezoneName': now.timeZoneName,
      'timezoneOffsetMinutes': now.timeZoneOffset.inMinutes,
      'supportsSystemAlarm':
          !kIsWeb && defaultTargetPlatform == TargetPlatform.android,
      'notes': [
        'These values describe the client device running SSH Mobile, not any SSH server.',
      ],
    };
  }

  Future<Map<String, dynamic>> getNetworkInfo() async {
    final base = <String, dynamic>{
      'execution': 'client',
      'target': 'client_device',
      'flutterPlatform': defaultTargetPlatform.name,
      'dartOperatingSystem': Platform.operatingSystem,
    };
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return {
        ...base,
        'supported': false,
        'note':
            'Detailed client network status is currently implemented on Android. Other platforms return basic Dart platform data only.',
      };
    }
    try {
      final result = await _systemChannel.invokeMapMethod<String, dynamic>(
        'getNetworkInfo',
      );
      return {
        ...base,
        'supported': true,
        ...?result,
      };
    } catch (e) {
      return {
        ...base,
        'supported': true,
        'error': e.toString(),
      };
    }
  }

  Future<Map<String, dynamic>> getBatteryStatus() async {
    final base = <String, dynamic>{
      'execution': 'client',
      'target': 'client_device',
      'flutterPlatform': defaultTargetPlatform.name,
      'dartOperatingSystem': Platform.operatingSystem,
    };
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return {
        ...base,
        'supported': false,
        'note':
            'Detailed client battery status is currently implemented on Android.',
      };
    }
    try {
      final result = await _systemChannel.invokeMapMethod<String, dynamic>(
        'getBatteryStatus',
      );
      return {
        ...base,
        'supported': true,
        ...?result,
      };
    } catch (e) {
      return {
        ...base,
        'supported': true,
        'error': e.toString(),
      };
    }
  }

  Future<Map<String, dynamic>> openAppSettings() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return {
        'execution': 'client',
        'target': 'client_device',
        'supported': false,
        'opened': false,
        'note': 'Opening app settings is currently implemented on Android.',
      };
    }
    try {
      final opened = await _systemChannel.invokeMethod<bool>(
            'openAppSettings',
          ) ??
          false;
      return {
        'execution': 'client',
        'target': 'client_device',
        'supported': true,
        'opened': opened,
      };
    } catch (e) {
      return {
        'execution': 'client',
        'target': 'client_device',
        'supported': true,
        'opened': false,
        'error': e.toString(),
      };
    }
  }

  Future<Map<String, dynamic>> setClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    return {
      'execution': 'client',
      'target': 'client_device',
      'updated': true,
      'textLength': text.length,
      'note':
          'Clipboard was updated on the client device running SSH Mobile, not on any SSH server.',
    };
  }

  Future<Map<String, dynamic>> setAlarm({
    String? triggerAt,
    int? delaySeconds,
    int? delayMinutes,
    String? label,
    bool useSystemAlarm = true,
  }) async {
    final now = DateTime.now();
    final fireAt = _resolveFireTime(
      now: now,
      triggerAt: triggerAt,
      delaySeconds: delaySeconds,
      delayMinutes: delayMinutes,
    );
    final title = 'SSH Mobile';
    final body =
        (label?.trim().isNotEmpty == true) ? label!.trim() : 'Client reminder';
    final id = 'client_alarm_${now.microsecondsSinceEpoch}';
    final notificationId = _nextNotificationId++;
    final duration = fireAt.difference(now);

    await _ensureNotificationsInitialized();
    final timer = Timer(duration, () async {
      try {
        await _showNotification(notificationId, title, body);
      } catch (e, stackTrace) {
        AppLogService.instance.error(
          'Client alarm notification failed',
          error: e,
          stackTrace: stackTrace,
          details: 'alarmId=$id',
        );
      } finally {
        _alarms.remove(id);
      }
    });
    _alarms[id] = _ClientAlarm(
      id: id,
      notificationId: notificationId,
      label: body,
      fireAt: fireAt,
      createdAt: now,
      timer: timer,
    );

    final systemAlarm = await _trySetSystemAlarm(
      fireAt: fireAt,
      label: body,
      enabled: useSystemAlarm,
    );

    return {
      'execution': 'client',
      'target': 'client_device',
      'alarmId': id,
      'label': body,
      'fireAtLocal': fireAt.toIso8601String(),
      'fireAtUtc': fireAt.toUtc().toIso8601String(),
      'secondsUntilFire': max(0, duration.inSeconds),
      'localReminder': {
        'scheduled': true,
        'note':
            'This in-app reminder is kept in memory and may not survive if the app process is killed.',
      },
      'systemAlarm': systemAlarm,
    };
  }

  Future<Map<String, dynamic>> listAlarms() async {
    final now = DateTime.now();
    return {
      'execution': 'client',
      'target': 'client_device',
      'alarms': [
        for (final alarm in _alarms.values)
          {
            'alarmId': alarm.id,
            'label': alarm.label,
            'createdAtLocal': alarm.createdAt.toIso8601String(),
            'fireAtLocal': alarm.fireAt.toIso8601String(),
            'secondsUntilFire': max(0, alarm.fireAt.difference(now).inSeconds),
          },
      ],
    };
  }

  Future<Map<String, dynamic>> cancelAlarm(String alarmId) async {
    final alarm = _alarms.remove(alarmId);
    if (alarm == null) {
      return {
        'execution': 'client',
        'target': 'client_device',
        'alarmId': alarmId,
        'cancelled': false,
        'error': 'Client alarm not found or already fired.',
      };
    }
    alarm.timer.cancel();
    await _ensureNotificationsInitialized();
    await _notifications.cancel(id: alarm.notificationId);
    return {
      'execution': 'client',
      'target': 'client_device',
      'alarmId': alarmId,
      'cancelled': true,
      'note':
          'Only the in-app reminder was cancelled. If Android system Clock created a separate alarm, cancel it in the Clock app.',
    };
  }

  Future<void> _ensureNotificationsInitialized() {
    final existing = _initFuture;
    if (existing != null) return existing;
    final future = _initializeNotifications();
    _initFuture = future;
    return future;
  }

  Future<void> _initializeNotifications() async {
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      final status = await Permission.notification.status;
      if (status.isDenied || status.isRestricted || status.isLimited) {
        await Permission.notification.request();
      }
    }

    const initializationSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
      macOS: DarwinInitializationSettings(),
    );
    await _notifications.initialize(settings: initializationSettings);

    const channel = AndroidNotificationChannel(
      _channelId,
      'Client tools',
      description: 'Notifications created by AI client-side tools.',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    );
    await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  Future<void> _showNotification(
    int notificationId,
    String title,
    String body,
  ) {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        'Client tools',
        channelDescription: 'Notifications created by AI client-side tools.',
        importance: Importance.max,
        priority: Priority.high,
        category: AndroidNotificationCategory.alarm,
        playSound: true,
        enableVibration: true,
      ),
      iOS: DarwinNotificationDetails(),
      macOS: DarwinNotificationDetails(),
    );
    return _notifications.show(
      id: notificationId,
      title: title,
      body: body,
      notificationDetails: details,
    );
  }

  DateTime _resolveFireTime({
    required DateTime now,
    String? triggerAt,
    int? delaySeconds,
    int? delayMinutes,
  }) {
    final trimmedTrigger = triggerAt?.trim();
    if (trimmedTrigger != null && trimmedTrigger.isNotEmpty) {
      final parsed = _parseDateTimeOrClock(trimmedTrigger, now);
      if (parsed == null) {
        throw StateError(
          'Invalid triggerAt. Use ISO-8601 such as 2026-05-16T08:30:00 or a 24-hour clock such as 08:30.',
        );
      }
      if (parsed.isAfter(now)) return parsed;
      return parsed.add(const Duration(days: 1));
    }

    final seconds = delaySeconds ?? ((delayMinutes ?? 0) * 60);
    if (seconds <= 0) {
      throw StateError(
        'Set triggerAt, delaySeconds, or delayMinutes for the client alarm.',
      );
    }
    return now.add(
      Duration(seconds: seconds.clamp(1, 366 * 24 * 60 * 60).toInt()),
    );
  }

  DateTime? _parseDateTimeOrClock(String value, DateTime now) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed.toLocal();

    final match = RegExp(r'^(\d{1,2}):(\d{2})(?::(\d{2}))?$').firstMatch(
      value,
    );
    if (match == null) return null;
    final hour = int.tryParse(match.group(1)!);
    final minute = int.tryParse(match.group(2)!);
    final second = int.tryParse(match.group(3) ?? '0');
    if (hour == null ||
        minute == null ||
        second == null ||
        hour < 0 ||
        hour > 23 ||
        minute < 0 ||
        minute > 59 ||
        second < 0 ||
        second > 59) {
      return null;
    }
    return DateTime(now.year, now.month, now.day, hour, minute, second);
  }

  Future<Map<String, dynamic>> _trySetSystemAlarm({
    required DateTime fireAt,
    required String label,
    required bool enabled,
  }) async {
    if (!enabled) {
      return {
        'requested': false,
        'scheduled': false,
        'note': 'System alarm was disabled by the tool arguments.',
      };
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return {
        'requested': true,
        'supported': false,
        'scheduled': false,
        'note': 'System Clock alarm integration is currently Android-only.',
      };
    }
    if (fireAt.difference(DateTime.now()) > const Duration(hours: 24)) {
      return {
        'requested': true,
        'supported': true,
        'scheduled': false,
        'note':
            'Android Clock alarms are time-of-day alarms. For alarms more than 24 hours away, only the in-app reminder was scheduled.',
      };
    }
    try {
      final scheduled = await _systemChannel.invokeMethod<bool>(
            'setSystemAlarm',
            {
              'hour': fireAt.hour,
              'minute': fireAt.minute,
              'message': label,
              'skipUi': false,
            },
          ) ??
          false;
      return {
        'requested': true,
        'supported': true,
        'scheduled': scheduled,
        'note': scheduled
            ? 'Android Clock received the alarm request. Some devices may still show a confirmation UI.'
            : 'No compatible Android Clock app accepted the alarm request.',
      };
    } catch (e) {
      return {
        'requested': true,
        'supported': true,
        'scheduled': false,
        'error': e.toString(),
      };
    }
  }

  String _formatOffset(Duration offset) {
    final sign = offset.isNegative ? '-' : '+';
    final minutes = offset.inMinutes.abs();
    final hours = minutes ~/ 60;
    final remainingMinutes = minutes % 60;
    return '$sign${hours.toString().padLeft(2, '0')}:'
        '${remainingMinutes.toString().padLeft(2, '0')}';
  }
}

class _ClientAlarm {
  final String id;
  final int notificationId;
  final String label;
  final DateTime fireAt;
  final DateTime createdAt;
  final Timer timer;

  const _ClientAlarm({
    required this.id,
    required this.notificationId,
    required this.label,
    required this.fireAt,
    required this.createdAt,
    required this.timer,
  });
}
