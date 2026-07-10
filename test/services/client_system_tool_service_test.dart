import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
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
