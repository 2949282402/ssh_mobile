part of '../ai_tool_service.dart';

extension _PlaybookTools on AiToolService {
  Future<String> _appGetOperationalSettings(
      Map<String, dynamic> arguments) async {
    return jsonEncode(await _readOperationalSettings());
  }

  Future<String> _appUpdateOperationalSettings(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Changing app operational settings requires user approval.',
      });
    }
    final current = await storageService.loadAiConnectionSettings();
    final nextDownloadLimit = _optionalInt(arguments, 'sftpDownloadLimitBytes');
    final nextEditLimit = _optionalInt(arguments, 'sftpTextEditLimitBytes');
    if (nextDownloadLimit != null && appSettings != null) {
      await appSettings!.setSftpDownloadLimitBytes(nextDownloadLimit);
    }
    if (nextEditLimit != null && appSettings != null) {
      await appSettings!.setSftpTextEditLimitBytes(nextEditLimit);
    }
    final secretCacheEnabled = _optionalBool(arguments, 'secretCacheEnabled');
    if (secretCacheEnabled != null) {
      await storageService.setSecretCacheEnabled(secretCacheEnabled);
    }
    final secretCacheTtlMinutes =
        _optionalInt(arguments, 'secretCacheTtlMinutes');
    if (secretCacheTtlMinutes != null) {
      await storageService.setSecretCacheTtl(
        Duration(minutes: secretCacheTtlMinutes),
      );
    }
    final nextTimeout = _optionalInt(arguments, 'aiRequestTimeoutSeconds');
    final nextWebSearchEnabled = _optionalBool(arguments, 'webSearchEnabled');
    final nextWebSearchMaxResults =
        _optionalInt(arguments, 'webSearchMaxResults');
    final nextMultiAgentEnabled = _optionalBool(arguments, 'multiAgentEnabled');
    final nextMultiAgentMaxAgents =
        _optionalInt(arguments, 'multiAgentMaxAgents');
    if (nextTimeout != null ||
        nextWebSearchEnabled != null ||
        nextWebSearchMaxResults != null ||
        nextMultiAgentEnabled != null ||
        nextMultiAgentMaxAgents != null) {
      await storageService.saveAiConnectionSettings(
        baseUrl: current.baseUrl,
        model: current.model,
        contextWindowTokens: current.contextWindowTokens,
        timeoutSeconds: nextTimeout ?? current.timeoutSeconds,
        deepSeekThinkingEnabled: current.deepSeekThinkingEnabled,
        deepSeekReasoningEffort: current.deepSeekReasoningEffort,
        openAiReasoningEffort: current.openAiReasoningEffort,
        webSearchEnabled: nextWebSearchEnabled ?? current.webSearchEnabled,
        webSearchMaxResults:
            nextWebSearchMaxResults ?? current.webSearchMaxResults,
        multiAgentEnabled: nextMultiAgentEnabled ?? current.multiAgentEnabled,
        multiAgentMaxAgents:
            nextMultiAgentMaxAgents ?? current.multiAgentMaxAgents,
      );
    }
    return jsonEncode(await _readOperationalSettings());
  }

  Future<String> _appClearSecretCache(Map<String, dynamic> arguments) async {
    storageService.clearSecretCache();
    return jsonEncode({
      'cleared': true,
      'scope': 'memory_secret_cache',
    });
  }

  Future<Map<String, dynamic>> _readOperationalSettings() async {
    final ai = await storageService.loadAiConnectionSettings();
    return {
      'sftpDownloadLimitBytes': appSettings?.sftpDownloadLimitBytes ??
          AppSettings.defaultSftpDownloadLimitBytes,
      'sftpTextEditLimitBytes': appSettings?.sftpTextEditLimitBytes ??
          AppSettings.defaultSftpTextEditLimitBytes,
      'secretCacheEnabled': storageService.isSecretCacheEnabled,
      'secretCacheTtlMinutes': storageService.secretCacheTtlMinutes,
      'aiRequestTimeoutSeconds': ai.timeoutSeconds,
      'webSearchEnabled': ai.webSearchEnabled,
      'webSearchMaxResults': ai.webSearchMaxResults,
      'multiAgentEnabled': ai.multiAgentEnabled,
      'multiAgentMaxAgents': ai.multiAgentMaxAgents,
      'hasApiKeyConfigured': ai.hasApiKey,
    };
  }

  Future<String> _listPlaybooksTool(Map<String, dynamic> arguments) async {
    final list = await storageService.loadPlaybooks();
    return jsonEncode({
      'playbooks': list
          .map((p) => {
                'id': p.id,
                'name': p.name,
                'description': p.description,
                'stepsCount': p.steps.length,
                'steps': p.steps
                    .map((s) => {
                          'name': s.name,
                          'command': s.command,
                          'description': s.description,
                        })
                    .toList(),
              })
          .toList(),
    });
  }

  Future<String> _createPlaybookTool(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Creating a playbook requires user approval.',
      });
    }
    final name = _arg(arguments, 'name');
    final description = _arg(arguments, 'description');
    final rawSteps = arguments['steps'] as List? ?? [];

    final steps = <PlaybookStep>[];
    for (int i = 0; i < rawSteps.length; i++) {
      final s = rawSteps[i] as Map<String, dynamic>;
      steps.add(PlaybookStep(
        id: 'step_${DateTime.now().millisecondsSinceEpoch}_$i',
        name: s['name'] as String? ?? 'Step ${i + 1}',
        command: s['command'] as String? ?? '',
        description: s['description'] as String? ?? '',
        expectedOutcomeRegex: s['expectedOutcomeRegex'] as String?,
        status: StepStatus.pending,
      ));
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
    final playbookId = _arg(arguments, 'playbookId');
    final connectionId = _arg(arguments, 'connectionId');

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

  Future<String> _getPlaybookStatusTool(Map<String, dynamic> arguments) async {
    if (playbookService == null) {
      final list = await storageService.loadPlaybooks();
      final playbookId = _arg(arguments, 'playbookId');
      try {
        final p = list.firstWhere((item) => item.id == playbookId);
        return jsonEncode({
          'playbookId': p.id,
          'name': p.name,
          'isRunning': false,
          'isPaused': false,
          'currentStepIndex': -1,
          'steps': p.steps
              .map((s) => {
                    'id': s.id,
                    'name': s.name,
                    'status': s.status.name,
                    'exitCode': s.exitCode,
                    'stdout': s.stdout,
                    'stderr': s.stderr,
                  })
              .toList(),
        });
      } catch (_) {
        return jsonEncode({
          'error': 'Playbook not found: $playbookId',
        });
      }
    }

    // Use live memory states from playbookService
    final playbookId = _arg(arguments, 'playbookId');
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
              .map((s) => {
                    'id': s.id,
                    'name': s.name,
                    'status': s.status.name,
                    'exitCode': s.exitCode,
                    'stdout': s.stdout,
                    'stderr': s.stderr,
                  })
              .toList(),
        });
      } catch (_) {
        return jsonEncode({
          'error': 'Playbook not found: $playbookId',
        });
      }
    }

    return jsonEncode({
      'playbookId': active.id,
      'name': active.name,
      'isRunning': playbookService!.isRunning,
      'isPaused': playbookService!.isPaused,
      'currentStepIndex': playbookService!.currentStepIndex,
      'steps': active.steps
          .map((s) => {
                'id': s.id,
                'name': s.name,
                'status': s.status.name,
                'exitCode': s.exitCode,
                'stdout': s.stdout,
                'stderr': s.stderr,
              })
          .toList(),
    });
  }

  List<AiTool> _getPlaybookTools() {
    return [
      AiTool(
        name: 'list_playbooks',
        description:
            'CLIENT tool. List all saved custom sequential task playbooks/scripts, including step names and commands.',
        properties: const {},
        handler: _listPlaybooksTool,
      ),
      AiTool(
        name: 'create_playbook',
        description:
            'CLIENT tool. Create a new visual sequential task playbook in storage. This updates local client data and requires user approval.',
        properties: {
          'name': _string('The display name for the playbook.'),
          'description':
              _string('A short description of what this playbook does.'),
          'steps': {
            'type': 'array',
            'description': 'The ordered list of steps to execute.',
            'items': {
              'type': 'object',
              'properties': {
                'name': _string('The step display name.'),
                'description': _string('What this step accomplishes.'),
                'command': _string(
                    'The multiline shell command/script to run via SSH exec.'),
                'expectedOutcomeRegex': _string(
                    'Optional regex pattern that the stdout must match to succeed.'),
              },
              'required': const ['name', 'description', 'command'],
            },
          },
        },
        required: const ['name', 'description', 'steps'],
        handler: (arguments) =>
            _createPlaybookTool(arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'run_playbook',
        description:
            'CLIENT tool. Trigger the async sequential execution of a saved playbook on a remote SSH server connection. This changes server state and requires user approval.',
        properties: {
          'playbookId': _string('The saved playbook ID.'),
          'connectionId': _string('The remote SSH server connection ID.'),
        },
        required: const ['playbookId', 'connectionId'],
        handler: (arguments) =>
            _runPlaybookTool(arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'get_playbook_status',
        description:
            'CLIENT tool. Query the active or latest execution status of a playbook, including live step results, exit codes, and stdout/stderr.',
        properties: {
          'playbookId': _string('The playbook ID to query.'),
        },
        required: const ['playbookId'],
        handler: _getPlaybookStatusTool,
      ),
    ];
  }
}
