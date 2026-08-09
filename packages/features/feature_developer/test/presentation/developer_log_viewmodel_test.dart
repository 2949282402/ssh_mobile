import 'package:flutter_test/flutter_test.dart';

import 'package:feature_developer/feature_developer.dart';
import '../support/developer_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeDeveloperLogPort logService;
  late FakeDeveloperSettings settings;

  setUp(() async {
    logService = FakeDeveloperLogPort();
    settings = FakeDeveloperSettings();
  });

  group('DeveloperLogViewModel Tests', () {
    test('Initialization checks', () {
      final viewModel = DeveloperLogViewModel(
        logService: logService,
        settings: settings,
      );
      addTearDown(viewModel.dispose);

      expect(viewModel.selectedLevel, equals(DeveloperLogLevel.all));
      expect(viewModel.selectedIds, isEmpty);
      expect(viewModel.selectionMode, isFalse);
    });

    test('Filtering logs by level updates filteredEntries list', () {
      final viewModel = DeveloperLogViewModel(
        logService: logService,
        settings: settings,
      );
      addTearDown(viewModel.dispose);

      logService.add(
        DeveloperLogEntry(
          id: 1,
          time: DateTime(2026, 8, 8),
          level: DeveloperLogLevel.info,
          text: 'This is info log',
        ),
      );
      logService.add(
        DeveloperLogEntry(
          id: 2,
          time: DateTime(2026, 8, 8),
          level: DeveloperLogLevel.error,
          text: 'This is error log',
        ),
      );

      viewModel.setSelectedLevel(DeveloperLogLevel.error);
      expect(viewModel.filteredEntries, hasLength(1));
      expect(
        viewModel.filteredEntries.first.level,
        equals(DeveloperLogLevel.error),
      );
    });

    test('Selecting entries changes selectionMode and selection sets', () {
      final viewModel = DeveloperLogViewModel(
        logService: logService,
        settings: settings,
      );
      addTearDown(viewModel.dispose);

      logService.add(
        DeveloperLogEntry(
          id: 1,
          time: DateTime(2026, 8, 8),
          level: DeveloperLogLevel.info,
          text: 'Test log entry',
        ),
      );
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
