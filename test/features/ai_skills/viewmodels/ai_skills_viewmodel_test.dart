import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ssh_mobile/features/ai_skills/viewmodels/ai_skills_viewmodel.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/utils/skill_frontmatter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SkillFrontmatter Utility Tests', () {
    test('parses name and description with quotes correctly', () {
      final text = '''---
name: "Nginx Setup"
description: 'Set up nginx service'
---
body content here''';
      final fm = SkillFrontmatter.parse(text);
      expect(fm, isNotNull);
      expect(fm!.name, equals('Nginx Setup'));
      expect(fm.description, equals('Set up nginx service'));
      expect(fm.body, equals('body content here'));
    });

    test('parses and unescapes double quotes in frontmatter correctly', () {
      final text = r'''---
name: "A \"quoted\" path"
description: "contains \\ backslash"
---
body''';
      final fm = SkillFrontmatter.parse(text);
      expect(fm, isNotNull);
      expect(fm!.name, equals('A "quoted" path'));
      expect(fm.description, equals('contains \\ backslash'));
    });

    test('parses empty description quotes as empty string', () {
      final text = '''---
name: "Nginx Setup"
description: ""
---
body''';
      final fm = SkillFrontmatter.parse(text);
      expect(fm, isNotNull);
      expect(fm!.description, equals(''));
    });

    test('parses multi-line description using YAML syntax', () {
      final text = '''---
name: Nginx Setup
description: >
  Line 1 of description
  Line 2 of description
---
body''';
      final fm = SkillFrontmatter.parse(text);
      expect(fm, isNotNull);
      expect(fm!.description,
          equals('Line 1 of description\nLine 2 of description'));
    });

    test('formats name and description with correct YAML syntax', () {
      final formatted = SkillFrontmatter.format(
        name: 'My Skill',
        description: 'Line 1\nLine 2',
        body: '\nBody content\n',
      );
      expect(formatted, contains('name: "My Skill"'));
      expect(formatted, contains('description: >\n  Line 1\n  Line 2'));
      expect(formatted,
          endsWith('\nBody content\n')); // Body format must preserve space
    });
  });

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

    test('Saving a skill synchronizes frontmatter name and description',
        () async {
      final viewModel = AiSkillsViewModel(
        storageService: storageService,
        appSettings: appSettings,
      );

      viewModel.newSkill();
      viewModel.nameController.text = 'My Updated Skill';
      viewModel.descriptionController.text = 'My Custom Desc';
      await viewModel.saveSkill();

      final saved = viewModel.skills.first;
      expect(saved.name, equals('My Updated Skill'));
      expect(saved.description, equals('My Custom Desc'));
      expect(saved.content, contains('name: "My Updated Skill"'));
      expect(saved.content, contains('description: "My Custom Desc"'));
    });

    test('Saving a skill without frontmatter does not inject frontmatter head',
        () async {
      final viewModel = AiSkillsViewModel(
        storageService: storageService,
        appSettings: appSettings,
      );

      viewModel.newSkill();
      viewModel.nameController.text = 'Plain Skill';
      viewModel.descriptionController.text = 'Plain Desc';
      viewModel.contentController.text = '# Plain Body\nNo frontmatter here.';

      await viewModel.saveSkill();

      final saved = viewModel.skills.first;
      expect(saved.name, equals('Plain Skill'));
      expect(saved.description, equals('Plain Desc'));
      expect(saved.content, equals('# Plain Body\nNo frontmatter here.'));
    });

    test('selectSkill fallbacks name and description from frontmatter',
        () async {
      final now = DateTime.now();
      final skill = AiSkillRecord(
        id: 'skill-fm-viewmodel',
        name: '',
        description: '',
        content: '''---
name: YAML Skill Name
description: YAML Skill Description
---
Some body text.''',
        enabled: true,
        createdAt: now,
        updatedAt: now,
      );
      await storageService.saveAiSkill(skill);

      final viewModel = AiSkillsViewModel(
        storageService: storageService,
        appSettings: appSettings,
      );
      await viewModel.loadSkills();

      viewModel.selectSkill(skill);

      expect(viewModel.nameController.text, equals('YAML Skill Name'));
      expect(viewModel.descriptionController.text,
          equals('YAML Skill Description'));
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
      expect(viewModel.references.first.title,
          equals('Example reference document'));

      viewModel.addReference(
          'My config rule', 'Configurations detailed command info');
      expect(
          viewModel.references,
          contains(const SkillReferenceItem(
              title: 'My config rule',
              content: 'Configurations detailed command info')));
      expect(viewModel.dirty, isTrue);

      viewModel.removeReference(0); // Removes example document
      expect(
          viewModel.references,
          equals([
            const SkillReferenceItem(
                title: 'My config rule',
                content: 'Configurations detailed command info')
          ]));

      viewModel.toggleReferences(false);
      expect(viewModel.hasReferences, isFalse);
    });
  });
}
