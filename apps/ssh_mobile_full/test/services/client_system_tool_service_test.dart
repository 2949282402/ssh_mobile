import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/client_system_tool_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = ClientSystemToolService.instance;

  tearDown(() {
    AppLogService.instance.clear();
    debugDefaultTargetPlatformOverride = null;
  });

  test('permission status returns graceful non-Android fallback', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    final result = await service.getPermissionStatus();

    expect(result['execution'], 'client');
    expect(result['supportsBatteryOptimizationExemption'], isFalse);
    expect(result['note'], contains('Android-only'));
  });

  test(
    'permission status marks Android battery optimization support',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      final result = await service.getPermissionStatus();

      expect(result['execution'], 'client');
      expect(result['supportsBatteryOptimizationExemption'], isTrue);
      expect(result.containsKey('ignoringBatteryOptimizations'), isTrue);
    },
  );

  test('reports client time and device information without server secrets', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    final time = service.getClientTime();
    final device = service.getClientDeviceInfo();

    expect(time['execution'], 'client');
    expect(time['target'], 'client_device');
    expect(time['nowLocal'], isA<String>());
    expect(time['nowUtc'], isA<String>());
    expect(time['timezoneOffset'], matches(RegExp(r'^[+-]\d{2}:\d{2}$')));
    expect(device['execution'], 'client');
    expect(device['target'], 'client_device');
    expect(device['dartOperatingSystem'], isA<String>());
    expect(device['numberOfProcessors'], greaterThanOrEqualTo(1));
    expect(device['supportsSystemAlarm'], isFalse);
  });

  test(
    'returns non-Android network, battery, and settings fallbacks',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      final network = await service.getNetworkInfo();
      final battery = await service.getBatteryStatus();
      final settings = await service.openAppSettings();

      expect(network['supported'], isFalse);
      expect(network['note'], contains('Android'));
      expect(battery['supported'], isFalse);
      expect(battery['note'], contains('Android'));
      expect(settings['supported'], isFalse);
      expect(settings['opened'], isFalse);
    },
  );

  test(
    'updates clipboard and exposes log counts and deletion results',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      AppLogService.instance.clear();
      AppLogService.instance.info('client tool info');
      AppLogService.instance.error('client tool error');

      final clipboard = await service.setClipboard('hello');
      final counts = await service.getLogCounts();
      final deleted = await service.deleteLogEntries(<int>[999999]);

      expect(clipboard['updated'], isTrue);
      expect(clipboard['textLength'], 5);
      expect(counts['counts'], containsPair('info', greaterThanOrEqualTo(1)));
      expect(deleted['deleted'], 0);

      final cleared = await service.clearLogs();
      expect(cleared['cleared'], greaterThanOrEqualTo(2));
      expect(cleared['remaining'], 0);
    },
  );

  test('schedules, lists, and cancels an in-app alarm on desktop', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    final alarm = await service.setAlarm(
      delaySeconds: 90,
      label: '  check later  ',
      useSystemAlarm: false,
    );
    expect(alarm['alarmId'], startsWith('client_alarm_'));
    expect(alarm['label'], 'check later');
    expect(alarm['localReminder'], containsPair('scheduled', isTrue));
    expect(alarm['systemAlarm'], containsPair('requested', isFalse));

    final listed = await service.listAlarms();
    expect(
      (listed['alarms'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .single['alarmId'],
      alarm['alarmId'],
    );

    final cancelled = await service.cancelAlarm(alarm['alarmId']! as String);
    expect(cancelled['cancelled'], isTrue);
    expect((await service.listAlarms())['alarms'], isEmpty);
    final missing = await service.cancelAlarm('missing-alarm');
    expect(missing['cancelled'], isFalse);
  });

  test('validates alarm trigger formats and delay bounds', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    final clockAlarm = await service.setAlarm(
      triggerAt: '23:59:59',
      useSystemAlarm: false,
    );
    expect(clockAlarm['fireAtLocal'], isA<String>());
    await service.cancelAlarm(clockAlarm['alarmId']! as String);

    final isoAlarm = await service.setAlarm(
      triggerAt: DateTime.now()
          .add(const Duration(minutes: 2))
          .toIso8601String(),
      useSystemAlarm: false,
    );
    expect(isoAlarm['secondsUntilFire'], greaterThan(0));
    await service.cancelAlarm(isoAlarm['alarmId']! as String);

    await expectLater(
      service.setAlarm(triggerAt: 'not-a-time', useSystemAlarm: false),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      service.setAlarm(delaySeconds: 0, useSystemAlarm: false),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'file picker operations propagate the platform cancellation/error',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      await expectLater(
        service.saveBytesToFile(fileName: 'client.txt', bytes: <int>[1, 2, 3]),
        throwsA(anything),
      );
      await expectLater(
        service.pickFile(allowedExtensions: const <String>['txt']),
        throwsA(anything),
      );
    },
  );

  test(
    'uses Android channel results for device status and system alarms',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final systemChannel = const MethodChannel('ssh_mobile/client_system');
      final permissionChannel = const MethodChannel(
        'flutter.baseflow.com/permissions/methods',
      );
      final powerChannel = const MethodChannel('ssh_mobile/power');
      final notificationsChannel = const MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      addTearDown(() {
        systemChannel.setMockMethodCallHandler(null);
        permissionChannel.setMockMethodCallHandler(null);
        powerChannel.setMockMethodCallHandler(null);
        notificationsChannel.setMockMethodCallHandler(null);
      });

      systemChannel.setMockMethodCallHandler((call) async {
        switch (call.method) {
          case 'getNetworkInfo':
            return <String, dynamic>{'type': 'wifi', 'connected': true};
          case 'getBatteryStatus':
            return <String, dynamic>{'level': 88};
          case 'openAppSettings':
            return true;
          case 'setSystemAlarm':
            return true;
          default:
            return null;
        }
      });
      permissionChannel.setMockMethodCallHandler((call) async {
        switch (call.method) {
          case 'checkPermissionStatus':
            return 1;
          case 'requestPermissions':
            return <int, int>{17: 1};
          default:
            return null;
        }
      });
      powerChannel.setMockMethodCallHandler((call) async {
        if (call.method == 'isIgnoringBatteryOptimizations') return true;
        return null;
      });
      notificationsChannel.setMockMethodCallHandler((call) async {
        if (call.method == 'initialize') return true;
        return null;
      });
      AndroidFlutterLocalNotificationsPlugin.registerWith();

      final network = await service.getNetworkInfo();
      final battery = await service.getBatteryStatus();
      final settings = await service.openAppSettings();
      final permissions = await service.getPermissionStatus();
      final alarm = await service.setAlarm(
        delaySeconds: 30,
        label: 'android check',
      );

      expect(network['supported'], isTrue);
      expect(network['connected'], isTrue);
      expect(battery['level'], 88);
      expect(settings['opened'], isTrue);
      expect(permissions['notificationGranted'], isTrue);
      expect(permissions['ignoringBatteryOptimizations'], isTrue);
      expect(alarm['systemAlarm'], containsPair('scheduled', isTrue));
      await service.cancelAlarm(alarm['alarmId']! as String);
    },
  );

  test('returns stable error payloads when Android channels fail', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final systemChannel = const MethodChannel('ssh_mobile/client_system');
    final permissionChannel = const MethodChannel(
      'flutter.baseflow.com/permissions/methods',
    );
    final powerChannel = const MethodChannel('ssh_mobile/power');
    addTearDown(() {
      systemChannel.setMockMethodCallHandler(null);
      permissionChannel.setMockMethodCallHandler(null);
      powerChannel.setMockMethodCallHandler(null);
    });

    systemChannel.setMockMethodCallHandler((call) async {
      throw PlatformException(code: 'unavailable', message: call.method);
    });
    permissionChannel.setMockMethodCallHandler((call) async {
      throw PlatformException(code: 'denied', message: call.method);
    });
    powerChannel.setMockMethodCallHandler((call) async {
      throw PlatformException(code: 'denied', message: call.method);
    });

    final network = await service.getNetworkInfo();
    final battery = await service.getBatteryStatus();
    final settings = await service.openAppSettings();
    final permissions = await service.getPermissionStatus();

    expect(network['error'], contains('unavailable'));
    expect(battery['error'], contains('unavailable'));
    expect(settings['opened'], isFalse);
    expect(settings['error'], contains('unavailable'));
    expect(permissions['notificationPermission'], 'denied');
    expect(permissions['notificationGranted'], isFalse);
    expect(permissions['ignoringBatteryOptimizations'], isFalse);
  });

  test(
    'queryLogs filters, limits, truncates, and returns redacted entries',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      AppLogService.instance.clear();
      AppLogService.instance.warning('older warning');
      AppLogService.instance.warning('latest warning password=secret-token');
      AppLogService.instance.info('info entry password=ignore-me');

      final result = await service.queryLogs(
        level: 'warning',
        contains: 'warning',
        limit: 1,
      );
      final entries = result['entries'] as List<dynamic>;
      final first = entries.single as Map<String, dynamic>;

      expect(result['matched'], 2);
      expect(result['truncated'], isTrue);
      expect(first['message'], contains('latest warning'));
      expect(first['message'], contains('[REDACTED]'));
      expect(first['message'], isNot(contains('secret-token')));
      expect(result['note'], contains('redacted'));
    },
  );
}
