import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ssh_mobile/features/developer_log/viewmodels/developer_log_viewmodel.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLogService logService;
  late AppSettings appSettings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    logService = AppLogService.instance;
    logService.clear();

    appSettings = AppSettings();
    await appSettings.init();
  });

  group('DeveloperLogViewModel Tests', () {
    test('Initialization checks', () {
      final viewModel = DeveloperLogViewModel(
        logService: logService,
        appSettings: appSettings,
      );

      expect(viewModel.selectedLevel, equals(AppLogLevel.all));
      expect(viewModel.selectedIds, isEmpty);
      expect(viewModel.selectionMode, isFalse);
    });

    test('Filtering logs by level updates filteredEntries list', () {
      final viewModel = DeveloperLogViewModel(
        logService: logService,
        appSettings: appSettings,
      );

      logService.info('This is info log');
      logService.error('This is error log');

      viewModel.setSelectedLevel(AppLogLevel.error);
      expect(viewModel.filteredEntries, hasLength(1));
      expect(viewModel.filteredEntries.first.level, equals('error'));
    });

    test('Selecting entries changes selectionMode and selection sets', () {
      final viewModel = DeveloperLogViewModel(
        logService: logService,
        appSettings: appSettings,
      );

      logService.info('Test log entry');
      final entry = logService.entries.first;

      viewModel.selectEntry(entry);
      expect(viewModel.selectionMode, isTrue);
      expect(viewModel.selectedIds, contains(entry.id));

      viewModel.toggleEntrySelection(entry);
      expect(viewModel.selectionMode, isFalse);
      expect(viewModel.selectedIds, isEmpty);
    });
  });
}
