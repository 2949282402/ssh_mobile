import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/data/database/app_database.dart';
import 'package:ssh_mobile/features/lan_share/services/lan_receiver_coordinator.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late AppSettings appSettings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    database = AppDatabase.forTesting();
    appSettings = AppSettings();
    await appSettings.ensureCoreLoaded();
  });

  tearDown(() async {
    appSettings.dispose();
    await database.close();
  });

  group('LanReceiverCoordinator Tests', () {
    test('initial state is not initialized', () {
      final coordinator = LanReceiverCoordinator(
        historyDao: database.lanHistoryDao,
        appSettings: appSettings,
      );
      expect(coordinator.initialized, isFalse);
      expect(coordinator.transferService, isNull);
    });

    test('ensureInitialized initializes services idempotently', () async {
      final coordinator = LanReceiverCoordinator(
        historyDao: database.lanHistoryDao,
        appSettings: appSettings,
        initializeNetwork: false,
      );

      final future1 = coordinator.ensureInitialized();
      final future2 = coordinator.ensureInitialized();

      expect(future1, equals(future2));

      await future1;

      expect(coordinator.initialized, isTrue);
      expect(coordinator.transferService, isNotNull);
      expect(coordinator.discoveryService, isNotNull);
      expect(coordinator.securityService, isNotNull);

      final viewModel1 = await coordinator.ensureViewModel();
      final viewModel2 = await coordinator.ensureViewModel();
      expect(identical(viewModel1, viewModel2), isTrue);
      expect(viewModel1.ownsRuntime, isFalse);
      expect(
        identical(viewModel1.transferService, coordinator.transferService),
        isTrue,
      );

      coordinator.dispose();
      await Future<void>.delayed(Duration.zero);
    });
  });
}
