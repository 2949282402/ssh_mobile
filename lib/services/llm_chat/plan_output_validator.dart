part of '../llm_chat_service.dart';

enum PlanOutputValidationStatus {
  validPlaybook,
  validTodoSteps,
  missingStructuredPlan,
  invalidJson,
  missingSteps,
  emptySteps,
  missingStepName,
}

class PlanOutputValidationResult {
  final PlanOutputValidationStatus status;
  final bool isValid;
  final String? reason;
  final Map<String, dynamic>? playbookJson;

  const PlanOutputValidationResult({
    required this.status,
    required this.isValid,
    this.reason,
    this.playbookJson,
  });
}

class PlanOutputValidator {
  static PlanOutputValidationResult validate({
    required String assistantText,
    required bool hasPersistedTodoSteps,
  }) {
    if (hasPersistedTodoSteps) {
      return const PlanOutputValidationResult(
        status: PlanOutputValidationStatus.validTodoSteps,
        isValid: true,
      );
    }

    final reg = RegExp(r'```playbook\s*([\s\S]*?)\s*```');
    final match = reg.firstMatch(assistantText);
    if (match == null) {
      return const PlanOutputValidationResult(
        status: PlanOutputValidationStatus.missingStructuredPlan,
        isValid: false,
        reason: 'Missing structured plan block (```playbook ... ```)',
      );
    }

    final rawJson = match.group(1);
    if (rawJson == null || rawJson.trim().isEmpty) {
      return const PlanOutputValidationResult(
        status: PlanOutputValidationStatus.invalidJson,
        isValid: false,
        reason: 'Empty playbook block content',
      );
    }

    Map<String, dynamic> decoded;
    try {
      final parsed = jsonDecode(rawJson);
      if (parsed is! Map<String, dynamic>) {
        return const PlanOutputValidationResult(
          status: PlanOutputValidationStatus.invalidJson,
          isValid: false,
          reason: 'Playbook JSON must be a map structure',
        );
      }
      decoded = parsed;
    } catch (e) {
      return PlanOutputValidationResult(
        status: PlanOutputValidationStatus.invalidJson,
        isValid: false,
        reason: 'Invalid JSON format in playbook block: $e',
      );
    }

    if (!decoded.containsKey('steps')) {
      return const PlanOutputValidationResult(
        status: PlanOutputValidationStatus.missingSteps,
        isValid: false,
        reason: 'Playbook is missing the required "steps" field',
      );
    }

    final steps = decoded['steps'];
    if (steps is! List) {
      return const PlanOutputValidationResult(
        status: PlanOutputValidationStatus.missingSteps,
        isValid: false,
        reason: 'The "steps" field in playbook JSON must be a list',
      );
    }

    if (steps.isEmpty) {
      return const PlanOutputValidationResult(
        status: PlanOutputValidationStatus.emptySteps,
        isValid: false,
        reason: 'The "steps" list in playbook JSON cannot be empty',
      );
    }

    for (var idx = 0; idx < steps.length; idx++) {
      final step = steps[idx];
      if (step is! Map) {
        return PlanOutputValidationResult(
          status: PlanOutputValidationStatus.missingStepName,
          isValid: false,
          reason: 'Step at index $idx is not a valid JSON object/map',
        );
      }
      final name = step['name'];
      if (name == null || name.toString().trim().isEmpty) {
        return PlanOutputValidationResult(
          status: PlanOutputValidationStatus.missingStepName,
          isValid: false,
          reason: 'Step at index $idx is missing a non-empty "name" field',
        );
      }
    }

    return PlanOutputValidationResult(
      status: PlanOutputValidationStatus.validPlaybook,
      isValid: true,
      playbookJson: decoded,
    );
  }
}

String buildPlanOutputRepairPrompt({
  required AppLanguage language,
  required String invalidReason,
  required String previousOutput,
}) {
  final isEn = language == AppLanguage.en;
  if (isEn) {
    return 'Your previous output did not contain a structurally valid playbook plan.\n'
        'Reason for failure: $invalidReason\n\n'
        'Please repair only the output format to match the plan mode constraints, without altering the user\'s original goal.\n'
        'You MUST output a valid ```playbook JSON block formatted exactly like this:\n'
        '```playbook\n'
        '{\n'
        '  "name": "Plan Name",\n'
        '  "description": "Plan Description",\n'
        '  "steps": [\n'
        '    {\n'
        '      "name": "Step Title",\n'
        '      "description": "Step Description",\n'
        '      "command": "command to run (optional)",\n'
        '      "connectionId": "connection UUID (optional)"\n'
        '    }\n'
        '  ]\n'
        '}\n'
        '```\n'
        'Rules:\n'
        '1. The "steps" array must be non-empty.\n'
        '2. Every step must have a non-empty "name" field.\n'
        '3. DO NOT call any tools or execute any commands.\n'
        '4. DO NOT make any state-changing tool calls.';
  } else {
    return '你刚才的计划没有合法结构化 playbook。\n'
        '校验失败原因: $invalidReason\n\n'
        '请仅修正输出格式以符合规划模式的约束，不要改变用户的原始目标。\n'
        '你必须输出一个合法的 ```playbook JSON 代码块，格式如下：\n'
        '```playbook\n'
        '{\n'
        '  "name": "计划名称",\n'
        '  "description": "计划描述",\n'
        '  "steps": [\n'
        '    {\n'
        '      "name": "步骤标题",\n'
        '      "description": "步骤描述",\n'
        '      "command": "执行的命令(可选)",\n'
        '      "connectionId": "连接 ID(可选)"\n'
        '    }\n'
        '  ]\n'
        '}\n'
        '```\n'
        '规则：\n'
        '1. "steps" 数组必须非空。\n'
        '2. 每个步骤必须包含非空 "name" 属性。\n'
        '3. 绝对不要调用任何工具或执行命令。\n'
        '4. 绝对不要发起任何会改变服务器状态的工具调用。';
  }
}

