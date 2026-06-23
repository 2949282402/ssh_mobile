import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/app_log_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SshService Log Bridge', () {
    late StorageService storageService;
    late SshService sshService;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      storageService = StorageService();
      sshService = SshService(storageService);
      AppLogService.instance.clear();
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      AppLogService.instance.clear();
    });

    test(
        'bridges background service logs and preserves details and normalizedLevel',
        () {
      sshService.handleBackgroundLog({
        'level': 'service',
        'message': 'TMUX session initialized',
        'details': 'sessionId=123 tmux=true host=example.com',
      });

      expect(AppLogService.instance.entries.length, 1);
      final entry = AppLogService.instance.entries.first;
      expect(entry.message, '[Background] TMUX session initialized');
      expect(entry.normalizedLevel, AppLogLevel.service);
      expect(entry.details, 'sessionId=123 tmux=true host=example.com');
    });

    test('defaults to info level if none specified', () {
      sshService.handleBackgroundLog({
        'message': 'A background message without level',
      });

      expect(AppLogService.instance.entries.length, 1);
      final entry = AppLogService.instance.entries.first;
      expect(entry.message, '[Background] A background message without level');
      expect(entry.normalizedLevel, AppLogLevel.info);
      expect(entry.details, isNull);
    });
  });
}
