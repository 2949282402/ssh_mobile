import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ssh_mobile/features/ai_skills/viewmodels/ai_skills_viewmodel.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storageService;
  late AppSettings appSettings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storageService = StorageService();
    await storageService.init();

    appSettings = AppSettings();
    await appSettings.init();
  });

  tearDown(() {
    storageService.dispose();
  });

  group('AiSkillsViewModel Tests', () {
    test('Initialization checks', () {
      final viewModel = AiSkillsViewModel(
        storageService: storageService,
        appSettings: appSettings,
      );

      expect(viewModel.skills, isEmpty);
      expect(viewModel.loading, isTrue);
      expect(viewModel.selectedId, isNull);
      expect(viewModel.dirty, isFalse);
    });

    test('Creating a new custom skill template', () async {
      final viewModel = AiSkillsViewModel(
        storageService: storageService,
        appSettings: appSettings,
      );

      viewModel.newSkill('My Skill', 'Markdown Content');

      expect(viewModel.selectedId, isNull);
      expect(viewModel.nameController.text, equals('My Skill'));
      expect(viewModel.contentController.text, equals('Markdown Content'));
      expect(viewModel.dirty, isTrue);
      expect(viewModel.enabled, isTrue);
    });

    test('Saving a skill updates custom skills collection and selection',
        () async {
      final viewModel = AiSkillsViewModel(
        storageService: storageService,
        appSettings: appSettings,
      );

      viewModel.newSkill('Test Skill', 'Description and workflow');
      await viewModel.saveSkill('Test Skill');

      expect(viewModel.skills, hasLength(1));
      expect(viewModel.selectedId, isNotNull);
      expect(viewModel.dirty, isFalse);
      expect(viewModel.skills.first.name, equals('Test Skill'));
    });

    test('Marking dirty updates states', () {
      final viewModel = AiSkillsViewModel(
        storageService: storageService,
        appSettings: appSettings,
      );

      expect(viewModel.dirty, isFalse);
      viewModel.markDirty();
      expect(viewModel.dirty, isTrue);
    });
  });
}
