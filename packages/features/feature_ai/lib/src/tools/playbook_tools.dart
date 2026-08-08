part of 'ai_tool_service.dart';

class PlaybookToolsProvider implements AiToolProvider {
  final StorageService storageService;
  final AppSettings? appSettings;
  final PlaybookAutomationPort? playbookService;

  const PlaybookToolsProvider({
    required this.storageService,
    this.appSettings,
    this.playbookService,
  });

  @override
  Future<List<AiTool>> getTools(AiToolService service) async {
    return _getPlaybookTools(service);
  }

  @override
  Future<String?> execute(
    AiToolService service,
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async {
    switch (name) {
      case 'list_playbooks':
        return _listPlaybooksTool(service, arguments);
      case 'create_playbook':
        return _createPlaybookTool(
          service,
          arguments,
          approvedWrite: approvedWrite,
        );
      case 'run_playbook':
        return _runPlaybookTool(
          service,
          arguments,
          approvedWrite: approvedWrite,
        );
      case 'get_playbook_status':
        return _getPlaybookStatusTool(service, arguments);
      default:
        return null;
    }
  }

  Future<String> _listPlaybooksTool(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    final list = await storageService.loadPlaybooks();
    return jsonEncode({
      'playbooks': list
          .map(
            (p) => {
              'id': p.id,
              'name': p.name,
              'description': p.description,
              'stepsCount': p.steps.length,
              'steps': p.steps
                  .map(
                    (s) => {
                      'name': s.name,
                      'command': s.command,
                      'description': s.description,
                    },
                  )
                  .toList(),
            },
          )
          .toList(),
    });
  }

  Future<String> _createPlaybookTool(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Creating a playbook requires user approval.',
      });
    }
    final name = service._arg(arguments, 'name');
    final description = service._arg(arguments, 'description');
    final rawSteps = arguments['steps'] as List? ?? [];

    final steps = <PlaybookStep>[];
    for (int i = 0; i < rawSteps.length; i++) {
      final s = rawSteps[i] as Map<String, dynamic>;
      steps.add(
        PlaybookStep(
          id: 'step_${DateTime.now().millisecondsSinceEpoch}_$i',
          name: s['name'] as String? ?? 'Step ${i + 1}',
          command: s['command'] as String? ?? '',
          description: s['description'] as String? ?? '',
          expectedOutcomeRegex: s['expectedOutcomeRegex'] as String?,
          status: StepStatus.pending,
        ),
      );
    }

    final playbook = Playbook(
      id: 'playbook_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      description: description,
      steps: steps,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await storageService.savePlaybook(playbook);
    return jsonEncode({
      'created': true,
      'playbookId': playbook.id,
      'name': playbook.name,
      'stepsCount': steps.length,
    });
  }

  Future<String> _runPlaybookTool(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (playbookService == null) {
      return jsonEncode({
        'error': 'Playbook Service is unavailable in this context.',
      });
    }
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Running a playbook requires user approval.',
      });
    }
    final playbookId = service._arg(arguments, 'playbookId');
    final connectionId = service._arg(arguments, 'connectionId');

    final approvalSnapshot =
        service.activeApprovalExecutionBinding?.resourceSnapshot;
    if (approvalSnapshot is _ApprovedPlaybookRun) {
      final target = service
          .activeApprovalExecutionBinding
          ?.connectionTargets[connectionId];
      if (target == null) {
        return jsonEncode({
          'error':
              'The approved server target is unavailable. Review and approve the playbook again.',
          'code': 'approval_target_changed',
        });
      }
      final started = await playbookService!.startApprovedExecutionForBinding(
        playbook: approvalSnapshot.playbook,
        actionFingerprint: approvalSnapshot.actionFingerprint,
        connectionTarget: ssh_core.SshTargetBinding.fromConfig(target.config),
      );
      if (!started) {
        return jsonEncode({
          'error':
              'The playbook changed while approval was open. Review the latest steps and approve again.',
          'code': 'approval_target_changed',
          'playbookId': approvalSnapshot.playbook.id,
        });
      }
      return jsonEncode({
        'started': true,
        'playbookId': approvalSnapshot.playbook.id,
        'connectionId': connectionId,
        'message':
            'The approved playbook snapshot has started sequential execution.',
      });
    }

    final config = storageService.getConnection(connectionId);
    if (config == null) {
      return jsonEncode({
        'error': 'SSH Connection not found for ID: $connectionId',
      });
    }

    // Trigger execution asynchronously in service
    await playbookService!.startExecution(playbookId, connectionId);

    return jsonEncode({
      'started': true,
      'playbookId': playbookId,
      'connectionId': connectionId,
      'message':
          'Playbook execution has started sequentially. Query status via get_playbook_status.',
    });
  }

  Future<String> _getPlaybookStatusTool(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    if (playbookService == null) {
      final list = await storageService.loadPlaybooks();
      final playbookId = service._arg(arguments, 'playbookId');
      try {
        final p = list.firstWhere((item) => item.id == playbookId);
        return jsonEncode({
          'playbookId': p.id,
          'name': p.name,
          'isRunning': false,
          'isPaused': false,
          'currentStepIndex': -1,
          'steps': p.steps
              .map(
                (s) => {
                  'id': s.id,
                  'name': s.name,
                  'status': s.status.name,
                  'exitCode': s.exitCode,
                  'stdout': s.stdout,
                  'stderr': s.stderr,
                },
              )
              .toList(),
        });
      } catch (_) {
        return jsonEncode({'error': 'Playbook not found: $playbookId'});
      }
    }

    // Use live memory states from playbookService
    final playbookId = service._arg(arguments, 'playbookId');
    final active = playbookService!.activePlaybook;
    if (active == null || active.id != playbookId) {
      final list = playbookService!.playbooks;
      try {
        final p = list.firstWhere((item) => item.id == playbookId);
        return jsonEncode({
          'playbookId': p.id,
          'name': p.name,
          'isRunning': false,
          'isPaused': false,
          'currentStepIndex': -1,
          'steps': p.steps
              .map(
                (s) => {
                  'id': s.id,
                  'name': s.name,
                  'status': s.status.name,
                  'exitCode': s.exitCode,
                  'stdout': s.stdout,
                  'stderr': s.stderr,
                },
              )
              .toList(),
        });
      } catch (_) {
        return jsonEncode({'error': 'Playbook not found: $playbookId'});
      }
    }

    return jsonEncode({
      'playbookId': active.id,
      'name': active.name,
      'isRunning': playbookService!.isRunning,
      'isPaused': playbookService!.isPaused,
      'currentStepIndex': playbookService!.currentStepIndex,
      'steps': active.steps
          .map(
            (s) => {
              'id': s.id,
              'name': s.name,
              'status': s.status.name,
              'exitCode': s.exitCode,
              'stdout': s.stdout,
              'stderr': s.stderr,
            },
          )
          .toList(),
    });
  }

  List<AiTool> _getPlaybookTools(AiToolService service) {
    return [
      AiTool(
        name: 'list_playbooks',
        description:
            'CLIENT tool. List all saved reusable playbooks/scripts, including step names and commands. These are distinct from chat-bound todoSteps plans.',
        properties: const {},
        handler: (args) => _listPlaybooksTool(service, args),
      ),
      AiTool(
        name: 'create_playbook',
        description:
            'CLIENT tool. Create a new saved reusable playbook in local storage. Use this only when the user explicitly asks to save, persist, or reuse the script/workflow beyond the current chat plan. This updates local client data and requires user approval.',
        properties: {
          'name': _string('The display name for the playbook.'),
          'description': _string(
            'A short description of what this playbook does.',
          ),
          'steps': {
            'type': 'array',
            'description': 'The ordered list of steps to execute.',
            'items': {
              'type': 'object',
              'properties': {
                'name': _string('The step display name.'),
                'description': _string('What this step accomplishes.'),
                'command': _string(
                  'The multiline shell command/script to run via SSH exec.',
                ),
                'expectedOutcomeRegex': _string(
                  'Optional regex pattern that the stdout must match to succeed.',
                ),
              },
              'required': const ['name', 'description', 'command'],
            },
          },
        },
        required: const ['name', 'description', 'steps'],
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (arguments) =>
            _createPlaybookTool(service, arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'run_playbook',
        description:
            'CLIENT tool. Trigger the async sequential execution of a previously saved reusable playbook on a remote SSH server connection. Do not use this for the ordinary current-chat execution plan; use it only when the user explicitly wants to run a saved playbook. This changes server state and requires user approval.',
        properties: {
          'playbookId': _string('The saved playbook ID.'),
          'connectionId': _string('The remote SSH server connection ID.'),
        },
        required: const ['playbookId', 'connectionId'],
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (arguments) =>
            _runPlaybookTool(service, arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'get_playbook_status',
        description:
            'CLIENT tool. Query the active or latest execution status of a saved playbook run, including live step results, exit codes, and stdout/stderr.',
        properties: {'playbookId': _string('The playbook ID to query.')},
        required: const ['playbookId'],
        handler: (args) => _getPlaybookStatusTool(service, args),
      ),
    ];
  }
}
