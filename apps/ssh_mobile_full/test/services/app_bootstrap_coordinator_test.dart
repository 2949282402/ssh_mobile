import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/services/app_bootstrap_coordinator.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppBootstrapCoordinator Tests', () {
    late AppSettings appSettings;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      appSettings = AppSettings();
    });

    test('initial state is idle', () {
      final coordinator = AppBootstrapCoordinator(appSettings: appSettings);
      expect(coordinator.phase, equals(BootstrapPhase.idle));
      expect(coordinator.isReady, isFalse);
    });

    test('ensureBootstrap transitions to ready and is idempotent', () async {
      final coordinator = AppBootstrapCoordinator(appSettings: appSettings);

      final future1 = coordinator.ensureBootstrap();
      final future2 = coordinator.ensureBootstrap();

      expect(future1, equals(future2));

      await future1;

      expect(coordinator.phase, equals(BootstrapPhase.ready));
      expect(coordinator.isReady, isTrue);
      expect(appSettings.coreLoaded, isTrue);
    });
  });
}
