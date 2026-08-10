import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connection_core/connection_core.dart';
import 'package:feature_playbook/feature_playbook.dart';
import 'package:ssh_core/ssh_core.dart';
import '../../../test_utils/test_storage_adapter.dart';

final class _PlaybookCatalog extends ChangeNotifier
    implements PlaybookConnectionCatalogPort {
  _PlaybookCatalog(this._repository);

  final ConnectionRepository _repository;

  @override
  bool get isInitialized => true;

  @override
  List<ConnectionConfig> get connections => _repository.connections;

  @override
  ConnectionConfig? connectionById(String id) => _repository.getConnection(id);
}

final class _PlaybookLogger implements PlaybookLoggerPort {
  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {}

  @override
  void info(String message, {String? details}) {}

  @override
  void warning(String message, {String? details}) {}
}

final class _PlaybookSsh implements PlaybookSshPort {
  @override
  Future<RemoteCommandResult> runCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 15),
  }) async => const RemoteCommandResult(exitCode: 0, stdout: 'ok', stderr: '');

  @override
  Future<RemoteCommandResult> runCommandForBinding({
    required SshTargetBinding binding,
    required String command,
    Duration timeout = const Duration(seconds: 15),
  }) async => const RemoteCommandResult(exitCode: 0, stdout: 'ok', stderr: '');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStorageAdapter storageService;
  late PlaybookService playbookService;
  late _PlaybookCatalog catalog;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storageService = TestStorageAdapter();
    await storageService.init();

    catalog = _PlaybookCatalog(storageService.connectionRepository);
    playbookService = PlaybookService(
      repository: storageService.playbookRepository,
      sshPort: _PlaybookSsh(),
      logger: _PlaybookLogger(),
    );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    playbookService.dispose();
    catalog.dispose();
    storageService.dispose();
  });

  group('PlaybookViewModel Tests', () {
    test('Initialization status and default connection setup', () {
      final viewModel = PlaybookViewModel(
        playbookService: playbookService,
        connectionCatalog: catalog,
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
        connectionCatalog: catalog,
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
        connectionCatalog: catalog,
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
        connectionCatalog: catalog,
      );

      viewModel.setSelectedConnectionId('conn_123');
      expect(viewModel.selectedConnectionId, equals('conn_123'));
    });

    test('Toggling step expanded updates expandedSteps list', () {
      final viewModel = PlaybookViewModel(
        playbookService: playbookService,
        connectionCatalog: catalog,
      );

      viewModel.toggleStepExpanded(0);
      expect(viewModel.expandedSteps.contains(0), isTrue);

      viewModel.toggleStepExpanded(0);
      expect(viewModel.expandedSteps.contains(0), isFalse);
    });
  });
}
