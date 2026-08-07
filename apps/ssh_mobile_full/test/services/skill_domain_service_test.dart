import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/skill/skill_domain_service.dart';

void main() {
  group('SkillDomainService Tests', () {
    late SkillDomainService domainService;

    setUp(() {
      domainService = const SkillDomainService();
    });

    test('cleanReferences discards empty and duplicates', () {
      final input = [
        const SkillReferenceItem(title: 'Ref 1', content: 'Content 1'),
        const SkillReferenceItem(title: '  ', content: 'Content 2'),
        const SkillReferenceItem(title: 'Ref 2', content: ''),
        const SkillReferenceItem(
          title: 'Ref 1',
          content: 'Duplicate Title Content',
        ),
        const SkillReferenceItem(title: 'Ref 3', content: 'Content 3'),
      ];

      final cleaned = domainService.cleanReferences(input);

      expect(cleaned.length, 2);
      expect(cleaned[0].title, 'Ref 1');
      expect(cleaned[0].content, 'Content 1');
      expect(cleaned[1].title, 'Ref 3');
      expect(cleaned[1].content, 'Content 3');
    });

    test(
      'syncFrontmatterContent does not inject if no frontmatter in rawContent',
      () {
        const rawContent = 'Some content without frontmatter';
        final result = domainService.syncFrontmatterContent(
          rawContent: rawContent,
          finalName: 'New Name',
          finalDesc: 'New Desc',
        );
        expect(result, rawContent);
      },
    );

    test('syncFrontmatterContent replaces header when values change', () {
      const rawContent = '''---
name: "Old Name"
description: "Old Desc"
---
# Main Content
Body here.''';

      final result = domainService.syncFrontmatterContent(
        rawContent: rawContent,
        finalName: 'New Name',
        finalDesc: 'New Desc',
      );

      expect(result.contains('name: "New Name"'), isTrue);
      expect(result.contains('description: "New Desc"'), isTrue);
      expect(result.contains('# Main Content'), isTrue);
    });

    test(
      'syncFrontmatterContent keeps content intact if header values match',
      () {
        const rawContent = '''---
name: "Same Name"
description: "Same Desc"
---
# Main Content''';

        final result = domainService.syncFrontmatterContent(
          rawContent: rawContent,
          finalName: 'Same Name',
          finalDesc: 'Same Desc',
        );

        expect(result, rawContent);
      },
    );

    test('buildCreateSkill constructs canonical record fields', () {
      const content = '''---
name: "FM Name"
description: "FM Desc"
---
Body content.''';

      final result = domainService.buildCreateSkill(
        title: 'Input Title',
        summary: 'Input Summary',
        content: content,
        references: [
          const SkillReferenceItem(title: 'Ref A', content: 'Content A'),
        ],
      );

      expect(result.name, 'Input Title');
      expect(result.description, 'Input Summary');
      expect(result.content.contains('name: "Input Title"'), isTrue);
      expect(result.content.contains('description: "Input Summary"'), isTrue);
      expect(result.references.length, 1);
    });

    test('buildCreateSkill uses frontmatter defaults if inputs are empty', () {
      const content = '''---
name: "FM Name"
description: "FM Desc"
---
Body content.''';

      final result = domainService.buildCreateSkill(
        title: '',
        summary: '',
        content: content,
        references: [],
      );

      expect(result.name, 'FM Name');
      expect(result.description, 'FM Desc');
      expect(result.content, content);
    });

    test('buildUpdateSkill performs partial update', () {
      final current = AiSkillRecord(
        id: 'skill-1',
        name: 'Name A',
        description: 'Desc A',
        content: '''---
name: "Name A"
description: "Desc A"
---
Body text.''',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      // Only update name
      final result1 = domainService.buildUpdateSkill(current, name: 'Name B');
      expect(result1.name, 'Name B');
      expect(result1.description, 'Desc A');
      expect(result1.content.contains('name: "Name B"'), isTrue);

      // Only update references
      final result2 = domainService.buildUpdateSkill(
        current,
        references: [
          const SkillReferenceItem(title: 'New Ref', content: 'New Content'),
        ],
      );
      expect(result2.name, 'Name A');
      expect(result2.references.length, 1);
      expect(result2.references[0].title, 'New Ref');
    });

    test('generatePreview detects created changes', () {
      final after = AiSkillRecord(
        id: 'skill-1',
        name: 'New Skill',
        description: 'New Description',
        content: 'Content text here.',
        references: [
          const SkillReferenceItem(title: 'Ref 1', content: 'Content 1'),
          const SkillReferenceItem(title: 'Ref 2', content: 'Content 2'),
        ],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final preview = domainService.generatePreview(null, after);

      expect(preview.action, 'CREATE');
      expect(preview.afterName, 'New Skill');
      expect(preview.addedReferencesCount, 2);
      expect(preview.removedReferencesCount, 0);
      expect(preview.modifiedReferencesCount, 0);
    });

    test('generatePreview detects modified changes', () {
      final before = AiSkillRecord(
        id: 'skill-1',
        name: 'Old Skill',
        description: 'Old Description',
        content: 'Old Content',
        references: [
          const SkillReferenceItem(title: 'Ref 1', content: 'Content 1'),
          const SkillReferenceItem(title: 'Ref 2', content: 'Content 2'),
        ],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final after = AiSkillRecord(
        id: 'skill-1',
        name: 'Updated Skill',
        description: 'Updated Description',
        content: 'Updated Content',
        references: [
          const SkillReferenceItem(
            title: 'Ref 1',
            content: 'Content 1 Changed',
          ),
          const SkillReferenceItem(title: 'Ref 3', content: 'Content 3'),
        ],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final preview = domainService.generatePreview(before, after);

      expect(preview.action, 'UPDATE');
      expect(preview.beforeName, 'Old Skill');
      expect(preview.afterName, 'Updated Skill');
      expect(preview.addedReferencesCount, 1); // Ref 3 added
      expect(preview.removedReferencesCount, 1); // Ref 2 removed
      expect(preview.modifiedReferencesCount, 1); // Ref 1 content changed
    });

    test(
      'buildUpdateSkill with empty or whitespace values fallbacks to existing or frontmatter',
      () {
        final current = AiSkillRecord(
          id: 'skill-1',
          name: 'Name A',
          description: 'Desc A',
          content: '''---
name: "Name A"
description: "Desc A"
---
Body text.''',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final result = domainService.buildUpdateSkill(
          current,
          name: '  ',
          description: '',
        );

        // Should fallback to frontmatter/current values instead of resetting to empty strings
        expect(result.name, equals('Name A'));
        expect(result.description, equals('Desc A'));
        expect(result.content, equals(current.content));
      },
    );
  });
}
