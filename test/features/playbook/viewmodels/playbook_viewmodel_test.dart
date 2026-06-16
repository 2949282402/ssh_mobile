import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/features/playbook/models/playbook.dart';
import 'package:ssh_mobile/features/playbook/viewmodels/playbook_viewmodel.dart';
import 'package:ssh_mobile/services/playbook_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storageService;
  late SshService sshService;
  late PlaybookService playbookService;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storageService = StorageService();
    await storageService.init();

    sshService = SshService(storageService);
    playbookService =
        PlaybookService(storageService: storageService, sshService: sshService);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    storageService.dispose();
  });

  group('PlaybookViewModel Tests', () {
    test('Initialization status and default connection setup', () {
      final viewModel = PlaybookViewModel(
        playbookService: playbookService,
        storageService: storageService,
      );

      expect(viewModel.playbooks, isEmpty);
      expect(viewModel.activePlaybook, isNull);
      expect(viewModel.isEditing, isFalse);
      expect(viewModel.editingPlaybook, isNull);
      expect(viewModel.expandedSteps, isEmpty);
    });

    test('Creating a new playbook initializes edit controllers and models', () {
      final viewModel = PlaybookViewModel(
        playbookService: playbookService,
        storageService: storageService,
      );

      viewModel.startNewPlaybook();

      expect(viewModel.isEditing, isTrue);
      expect(viewModel.editingPlaybook, isNotNull);
      expect(viewModel.nameController.text, isEmpty);
      expect(viewModel.descriptionController.text, isEmpty);
      expect(viewModel.stepControllers, hasLength(1));
    });

    test('Steps manipulation during edit mode', () {
      final viewModel = PlaybookViewModel(
        playbookService: playbookService,
        storageService: storageService,
      );

      viewModel.startNewPlaybook();
      viewModel.addStepToEditing();
      expect(viewModel.stepControllers, hasLength(2));

      viewModel.removeStepFromEditing(0);
      expect(viewModel.stepControllers, hasLength(1));
    });

    test('Selecting connection ID updates ViewModel state', () {
      final viewModel = PlaybookViewModel(
        playbookService: playbookService,
        storageService: storageService,
      );

      viewModel.setSelectedConnectionId('conn_123');
      expect(viewModel.selectedConnectionId, equals('conn_123'));
    });

    test('Toggling step expanded updates expandedSteps list', () {
      final viewModel = PlaybookViewModel(
        playbookService: playbookService,
        storageService: storageService,
      );

      viewModel.toggleStepExpanded(0);
      expect(viewModel.expandedSteps.contains(0), isTrue);

      viewModel.toggleStepExpanded(0);
      expect(viewModel.expandedSteps.contains(0), isFalse);
    });
  });
}
