import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/ai_chat/services/llm_chat_service.dart';

void main() {
  group('PlanOutputValidator Tests', () {
    test('returns validTodoSteps when hasPersistedTodoSteps is true', () {
      final result = PlanOutputValidator.validate(
        assistantText: 'Some natural language plan.',
        hasPersistedTodoSteps: true,
      );
      expect(result.isValid, isTrue);
      expect(result.status, PlanOutputValidationStatus.validTodoSteps);
      expect(result.playbookJson, null);
    });

    test('returns missingStructuredPlan when no playbook block is found', () {
      final result = PlanOutputValidator.validate(
        assistantText: 'Some text listing steps but not in the required block.',
        hasPersistedTodoSteps: false,
      );
      expect(result.isValid, isFalse);
      expect(result.status, PlanOutputValidationStatus.missingStructuredPlan);
      expect(result.reason, contains('Missing structured plan block'));
    });

    test('returns invalidJson when block content is empty', () {
      final result = PlanOutputValidator.validate(
        assistantText: '```playbook\n```',
        hasPersistedTodoSteps: false,
      );
      expect(result.isValid, isFalse);
      expect(result.status, PlanOutputValidationStatus.invalidJson);
      expect(result.reason, contains('Empty playbook block content'));
    });

    test('returns invalidJson when JSON format is invalid', () {
      final result = PlanOutputValidator.validate(
        assistantText: '```playbook\n{"name": "Invalid JSON",\n```',
        hasPersistedTodoSteps: false,
      );
      expect(result.isValid, isFalse);
      expect(result.status, PlanOutputValidationStatus.invalidJson);
      expect(result.reason, contains('Invalid JSON format'));
    });

    test('returns invalidJson when JSON is not a map', () {
      final result = PlanOutputValidator.validate(
        assistantText: '```playbook\n[1, 2, 3]\n```',
        hasPersistedTodoSteps: false,
      );
      expect(result.isValid, isFalse);
      expect(result.status, PlanOutputValidationStatus.invalidJson);
      expect(result.reason, contains('Playbook JSON must be a map structure'));
    });

    test('returns missingSteps when steps field is missing', () {
      final result = PlanOutputValidator.validate(
        assistantText: '```playbook\n{"name": "My Playbook"}\n```',
        hasPersistedTodoSteps: false,
      );
      expect(result.isValid, isFalse);
      expect(result.status, PlanOutputValidationStatus.missingSteps);
      expect(result.reason, contains('missing the required "steps" field'));
    });

    test('returns missingSteps when steps field is not a list', () {
      final result = PlanOutputValidator.validate(
        assistantText:
            '```playbook\n{"name": "My Playbook", "steps": "not-a-list"}\n```',
        hasPersistedTodoSteps: false,
      );
      expect(result.isValid, isFalse);
      expect(result.status, PlanOutputValidationStatus.missingSteps);
      expect(result.reason, contains('must be a list'));
    });

    test('returns emptySteps when steps list is empty', () {
      final result = PlanOutputValidator.validate(
        assistantText: '```playbook\n{"name": "My Playbook", "steps": []}\n```',
        hasPersistedTodoSteps: false,
      );
      expect(result.isValid, isFalse);
      expect(result.status, PlanOutputValidationStatus.emptySteps);
      expect(result.reason, contains('cannot be empty'));
    });

    test('returns missingStepName when step lacks a name', () {
      final result = PlanOutputValidator.validate(
        assistantText:
            '```playbook\n{"name": "My Playbook", "steps": [{"command": "ls"}]}\n```',
        hasPersistedTodoSteps: false,
      );
      expect(result.isValid, isFalse);
      expect(result.status, PlanOutputValidationStatus.missingStepName);
      expect(result.reason, contains('missing a non-empty "name" field'));
    });

    test('returns missingStepName when step is not a map', () {
      final result = PlanOutputValidator.validate(
        assistantText:
            '```playbook\n{"name": "My Playbook", "steps": ["step-name-but-not-map"]}\n```',
        hasPersistedTodoSteps: false,
      );
      expect(result.isValid, isFalse);
      expect(result.status, PlanOutputValidationStatus.missingStepName);
      expect(result.reason, contains('not a valid JSON object/map'));
    });

    test('returns validPlaybook and extracts JSON for a valid playbook', () {
      const validPlaybook = '''
```playbook
{
  "name": "Restart Service",
  "description": "Restarts a target service",
  "steps": [
    {
      "name": "Check Status",
      "command": "systemctl status nginx",
      "description": "Check if nginx is running"
    },
    {
      "name": "Restart",
      "command": "systemctl restart nginx",
      "description": "Restart nginx service"
    }
  ]
}
```
''';
      final result = PlanOutputValidator.validate(
        assistantText: validPlaybook,
        hasPersistedTodoSteps: false,
      );
      expect(result.isValid, isTrue);
      expect(result.status, PlanOutputValidationStatus.validPlaybook);
      expect(result.playbookJson, isNotNull);
      expect(result.playbookJson!['name'], 'Restart Service');
      expect(result.playbookJson!['steps'], hasLength(2));
      expect(result.playbookJson!['steps'][0]['name'], 'Check Status');
    });

    test('retains long and multiline commands correctly', () {
      const multilinePlaybook = '''
```playbook
{
  "name": "Complex Commands",
  "steps": [
    {
      "name": "Long Script",
      "command": "if ! grep -q 'test' file.txt; then\\n  echo 'missing'\\n  exit 1\\nfi",
      "description": "Verify file contents"
    }
  ]
}
```
''';
      final result = PlanOutputValidator.validate(
        assistantText: multilinePlaybook,
        hasPersistedTodoSteps: false,
      );
      expect(result.isValid, isTrue);
      expect(result.playbookJson!['steps'][0]['command'], contains('\n'));
    });

    test('skips invalid first block and matches second valid block', () {
      const mixedPlaybooks = '''
Some description.
```playbook
{
  "name": "First Invalid Block",
  "steps": []
}
```
Middle description.
```playbook
{
  "name": "Second Valid Block",
  "steps": [
    {"name": "Valid Step", "command": "echo 1"}
  ]
}
```
''';
      final result = PlanOutputValidator.validate(
        assistantText: mixedPlaybooks,
        hasPersistedTodoSteps: false,
      );
      expect(result.isValid, isTrue);
      expect(result.status, PlanOutputValidationStatus.validPlaybook);
      expect(result.playbookJson!['name'], 'Second Valid Block');
    });

    test('returns first error if all blocks are invalid', () {
      const allInvalid = '''
```playbook
{
  "name": "First Invalid Block",
  "steps": []
}
```
```playbook
{
  "name": "Second Invalid Block",
  "steps": [
    {"command": "missing-name"}
  ]
}
```
''';
      final result = PlanOutputValidator.validate(
        assistantText: allInvalid,
        hasPersistedTodoSteps: false,
      );
      expect(result.isValid, isFalse);
      expect(result.status, PlanOutputValidationStatus.emptySteps);
    });
  });
}
