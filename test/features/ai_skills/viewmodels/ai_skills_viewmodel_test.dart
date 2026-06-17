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

    test('Parsing references from markdown content text', () {
      final viewModel = AiSkillsViewModel(
        storageService: storageService,
        appSettings: appSettings,
      );

      viewModel.contentController.text =
          'Some content here\n\n## References\n- references/a.md # Desc A\n- [Desc B](references/b.md)\n- references/c.md: Desc C\n- references/d.md';
      viewModel.parseReferencesFromContent();

      expect(viewModel.hasReferences, isTrue);
      expect(viewModel.references, equals([
        const SkillReferenceItem(path: 'references/a.md', description: 'Desc A'),
        const SkillReferenceItem(path: 'references/b.md', description: 'Desc B'),
        const SkillReferenceItem(path: 'references/c.md', description: 'Desc C'),
        const SkillReferenceItem(path: 'references/d.md', description: ''),
      ]));
    });

    test('Adding and removing references updates content text', () {
      final viewModel = AiSkillsViewModel(
        storageService: storageService,
        appSettings: appSettings,
      );

      viewModel.contentController.text = 'Introductory text';
      viewModel.toggleReferences(true);

      expect(viewModel.hasReferences, isTrue);
      expect(viewModel.contentController.text, contains('## References'));
      expect(viewModel.contentController.text, contains('- references/example.md # Example reference document'));

      viewModel.addReference('references/my_config.md', 'Configurations info');
      expect(viewModel.references, contains(const SkillReferenceItem(path: 'references/my_config.md', description: 'Configurations info')));
      expect(viewModel.contentController.text, contains('- references/my_config.md # Configurations info'));

      viewModel.removeReference(0); // Removes example.md
      expect(viewModel.references, equals([const SkillReferenceItem(path: 'references/my_config.md', description: 'Configurations info')]));
      expect(viewModel.contentController.text, isNot(contains('- references/example.md')));

      viewModel.toggleReferences(false);
      expect(viewModel.hasReferences, isFalse);
      expect(viewModel.contentController.text, equals('Introductory text'));
    });
  });
}
