import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/app/app_runtime_factory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });

  tearDownAll(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'AppRuntimeFactory creates one app scope and disposes idempotently',
    () async {
      SharedPreferences.setMockInitialValues({});

      final runtime = await AppRuntimeFactory.create();

      expect(runtime.isDisposed, isFalse);
      expect(runtime.appLogService, isNotNull);
      expect(runtime.storageService, isNotNull);
      expect(runtime.sshService, isNotNull);
      expect(runtime.lanReceiverCoordinator, isNotNull);

      final firstDispose = runtime.dispose();
      final secondDispose = runtime.dispose();

      expect(identical(firstDispose, secondDispose), isTrue);
      await firstDispose;
      expect(runtime.isDisposed, isTrue);
    },
  );
}
