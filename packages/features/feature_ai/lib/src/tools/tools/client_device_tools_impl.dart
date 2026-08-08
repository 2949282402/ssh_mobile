part of '../ai_tool_service.dart';

Future<String> _clientSetAlarm(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments,
) async {
  final result = await provider.clientSystemToolService.setAlarm(
    triggerAt: service._optionalString(arguments, 'triggerAt'),
    delaySeconds: service._optionalInt(arguments, 'delaySeconds'),
    delayMinutes: service._optionalInt(arguments, 'delayMinutes'),
    label: service._optionalString(arguments, 'label'),
    useSystemAlarm: service._optionalBool(arguments, 'useSystemAlarm') ?? true,
  );
  return jsonEncode(result);
}

Future<String> _clientCancelAlarm(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments,
) async {
  return jsonEncode(
    await provider.clientSystemToolService.cancelAlarm(
      service._arg(arguments, 'alarmId'),
    ),
  );
}

Future<String> _clientSetClipboard(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments,
) async {
  return jsonEncode(
    await provider.clientSystemToolService.setClipboard(
      service._arg(arguments, 'text'),
    ),
  );
}

Future<String> _clientCheckRuntimeHealth(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments,
) async {
  final profile = _clientHealthProfileFromRaw(
    service._optionalString(arguments, 'profile'),
  );
  final report = await provider.clientHealthAdvisor.check(profile: profile);
  return jsonEncode(report.toJson());
}

ClientHealthCheckProfile _clientHealthProfileFromRaw(String? value) {
  switch (value?.trim().toLowerCase()) {
    case 'general':
      return ClientHealthCheckProfile.general;
    case 'background':
      return ClientHealthCheckProfile.background;
    case 'agent_execution':
    case 'agentexecution':
    case null:
    case '':
      return ClientHealthCheckProfile.agentExecution;
    default:
      return ClientHealthCheckProfile.agentExecution;
  }
}

Future<String> _clientSaveExperienceSkill(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments, {
  required bool approvedWrite,
}) async {
  if (!approvedWrite) {
    return jsonEncode({
      'error': 'Saving a local skill requires user approval before execution.',
    });
  }

  final summary = service._arg(arguments, 'summary');
  final title = service._optionalString(arguments, 'title');
  final details = service._optionalString(arguments, 'content');

  final rawRefs = arguments['references'];
  final inputReferences = <SkillReferenceItem>[];
  if (rawRefs is List) {
    for (final item in rawRefs) {
      if (item is Map) {
        final t = (item['title'] as String?)?.trim() ?? '';
        final c = (item['content'] as String?)?.trim() ?? '';
        inputReferences.add(SkillReferenceItem(title: t, content: c));
      }
    }
  }

  final buildResult = provider.skillDomainService.buildCreateSkill(
    title: title,
    summary: summary,
    content: details == null || details.trim().isEmpty
        ? null
        : '$summary\n\n${details.trim()}',
    references: inputReferences,
  );

  final now = DateTime.now();
  final record = AiSkillRecord(
    id: 'skill-${now.microsecondsSinceEpoch}',
    name: buildResult.name,
    description: buildResult.description,
    content: buildResult.content,
    enabled: true,
    references: buildResult.references,
    createdAt: now,
    updatedAt: now,
  );
  await provider.storageService.saveAiSkill(record);
  AppLogService.instance.info(
    'AI experience skill saved',
    details:
        'skillId=${record.id} name=${provider.secretPolicy.previewText(record.name)}',
  );
  return jsonEncode({
    'execution': 'client',
    'target': 'local_skill',
    'saved': true,
    'skillId': record.id,
    'name': record.name,
    'description': record.description,
  });
}

Future<String> _clientListSkills(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments,
) async {
  final skills = await provider.storageService.loadAiSkills();
  return jsonEncode({
    'execution': 'client',
    'target': 'local_skill',
    'skills': skills.map((s) => s.toJson()).toList(),
  });
}

Future<String> _clientUpdateSkill(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments, {
  required bool approvedWrite,
}) async {
  if (!approvedWrite) {
    return jsonEncode({
      'error':
          'Updating a local skill requires user approval before execution.',
    });
  }
  final approvedSnapshot =
      service.activeApprovalExecutionBinding?.resourceSnapshot;
  if (approvedSnapshot is _ApprovedSkillUpdate) {
    final saved = await provider.storageService.saveAiSkillIfUnchanged(
      approvedSnapshot.expected,
      approvedSnapshot.updated,
    );
    if (!saved) {
      return jsonEncode({
        'error':
            'The skill changed while approval was open. Review the latest skill and approve the update again.',
        'code': 'approval_target_changed',
        'skillId': approvedSnapshot.expected.id,
      });
    }
    final updated = approvedSnapshot.updated;
    return jsonEncode({
      'execution': 'client',
      'target': 'local_skill',
      'updated': true,
      'skillId': updated.id,
      'name': updated.name,
      'description': updated.description,
      'enabled': updated.enabled,
    });
  }
  final skillId = service._arg(arguments, 'skillId');
  final name = service._optionalString(arguments, 'name');
  final description = service._optionalString(arguments, 'description');
  final content = service._optionalString(arguments, 'content');
  final enabled = service._optionalBool(arguments, 'enabled');
  final rawRefs = arguments['references'];

  final skills = await provider.storageService.loadAiSkills();
  final idx = skills.indexWhere((s) => s.id == skillId);
  if (idx == -1) {
    return jsonEncode({'error': 'Skill not found with id: $skillId'});
  }

  final current = skills[idx];
  List<SkillReferenceItem>? targetReferences;

  if (rawRefs is List) {
    targetReferences = [];
    for (final item in rawRefs) {
      if (item is Map) {
        final t = (item['title'] as String?)?.trim() ?? '';
        final c = (item['content'] as String?)?.trim() ?? '';
        targetReferences.add(SkillReferenceItem(title: t, content: c));
      }
    }
  }

  final buildResult = provider.skillDomainService.buildUpdateSkill(
    current,
    name: name,
    description: description,
    content: content,
    references: targetReferences,
  );

  final updated = current.copyWith(
    name: buildResult.name,
    description: buildResult.description,
    content: buildResult.content,
    enabled: enabled ?? current.enabled,
    references: buildResult.references,
    updatedAt: DateTime.now(),
  );

  await provider.storageService.saveAiSkill(updated);

  return jsonEncode({
    'execution': 'client',
    'target': 'local_skill',
    'updated': true,
    'skillId': updated.id,
    'name': updated.name,
    'description': updated.description,
    'enabled': updated.enabled,
  });
}
