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

      viewModel.newSkill();

      expect(viewModel.selectedId, isNull);
      expect(viewModel.nameController.text, equals(viewModel.defaultName));
      expect(viewModel.contentController.text, startsWith('---\nname:'));
      expect(viewModel.contentController.text, contains('##'));
      expect(viewModel.dirty, isTrue);
      expect(viewModel.enabled, isTrue);
    });

    test('Saving a skill updates custom skills collection and selection',
        () async {
      final viewModel = AiSkillsViewModel(
        storageService: storageService,
        appSettings: appSettings,
      );

      viewModel.newSkill();
      viewModel.nameController.text = 'Test Skill';
      await viewModel.saveSkill();

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

    test('Adding and removing references updates ViewModel state', () {
      final viewModel = AiSkillsViewModel(
        storageService: storageService,
        appSettings: appSettings,
      );

      expect(viewModel.hasReferences, isFalse);
      viewModel.toggleReferences(true);

      expect(viewModel.hasReferences, isTrue);
      expect(viewModel.references, hasLength(1));
      expect(viewModel.references.first.title, equals('Example reference document'));

      viewModel.addReference('My config rule', 'Configurations detailed command info');
      expect(viewModel.references, contains(const SkillReferenceItem(title: 'My config rule', content: 'Configurations detailed command info')));
      expect(viewModel.dirty, isTrue);

      viewModel.removeReference(0); // Removes example document
      expect(viewModel.references, equals([const SkillReferenceItem(title: 'My config rule', content: 'Configurations detailed command info')]));

      viewModel.toggleReferences(false);
      expect(viewModel.hasReferences, isFalse);
    });
  });
}
