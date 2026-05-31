import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/playbook.dart';
import 'storage_service.dart';
import 'ssh_service.dart';
import 'app_log_service.dart';

class PlaybookService extends ChangeNotifier {
  final StorageService _storageService;
  final SshService _sshService;

  List<Playbook> _playbooks = [];
  Playbook? _activePlaybook;
  int _currentStepIndex = -1;
  bool _isRunning = false;
  bool _isPaused = false;
  String? _activeConnectionId;

  String? _pendingDiagnosticPrompt;

  PlaybookService({
    required StorageService storageService,
    required SshService sshService,
  })  : _storageService = storageService,
        _sshService = sshService {
    _loadPlaybooksFromStorage();
  }

  String? get pendingDiagnosticPrompt => _pendingDiagnosticPrompt;

  set pendingDiagnosticPrompt(String? value) {
    _pendingDiagnosticPrompt = value;
    notifyListeners();
  }

  List<Playbook> get playbooks => List.unmodifiable(_playbooks);
  Playbook? get activePlaybook => _activePlaybook;
  int get currentStepIndex => _currentStepIndex;
  bool get isRunning => _isRunning;
  bool get isPaused => _isPaused;
  String? get activeConnectionId => _activeConnectionId;

  Future<void> _loadPlaybooksFromStorage() async {
    _playbooks = await _storageService.loadPlaybooks();
    notifyListeners();
  }

  Future<void> createPlaybook(Playbook playbook) async {
    await _storageService.savePlaybook(playbook);
    await _loadPlaybooksFromStorage();
  }

  Future<void> updatePlaybook(Playbook playbook) async {
    if (_activePlaybook?.id == playbook.id) {
      _activePlaybook = playbook;
    }
    await _storageService.savePlaybook(playbook);
    await _loadPlaybooksFromStorage();
  }

  Future<void> deletePlaybook(String id) async {
    if (_activePlaybook?.id == id) {
      _activePlaybook = null;
      _currentStepIndex = -1;
      _isRunning = false;
      _isPaused = false;
    }
    await _storageService.deletePlaybook(id);
    await _loadPlaybooksFromStorage();
  }

  void selectPlaybook(String playbookId) {
    try {
      _activePlaybook = _playbooks.firstWhere((p) => p.id == playbookId);
      _currentStepIndex = -1;
      _isRunning = false;
      _isPaused = false;
      notifyListeners();
    } catch (e) {
      AppLogService.instance.error('Playbook not found: $playbookId');
    }
  }

  void resetPlaybook(String playbookId) {
    final index = _playbooks.indexWhere((p) => p.id == playbookId);
    if (index == -1) return;

    final original = _playbooks[index];
    final resetSteps = original.steps
        .map((s) => s.copyWith(
              status: StepStatus.pending,
              stdout: null,
              stderr: null,
              exitCode: null,
            ))
        .toList();

    final resetPlaybook = original.copyWith(
      steps: resetSteps,
      updatedAt: DateTime.now(),
    );

    if (_activePlaybook?.id == playbookId) {
      _activePlaybook = resetPlaybook;
      _currentStepIndex = -1;
      _isRunning = false;
      _isPaused = false;
    }

    updatePlaybook(resetPlaybook);
  }

  Future<void> startExecution(String playbookId, String connectionId) async {
    selectPlaybook(playbookId);
    if (_activePlaybook == null) return;

    _isRunning = true;
    _isPaused = false;
    _currentStepIndex = 0;
    _activeConnectionId = connectionId;
    notifyListeners();

    // Reset status of all steps to pending before starting
    final cleanSteps = _activePlaybook!.steps
        .map((s) => s.copyWith(
              status: StepStatus.pending,
              stdout: null,
              stderr: null,
              exitCode: null,
            ))
        .toList();
    _activePlaybook = _activePlaybook!.copyWith(
      steps: cleanSteps,
      lastConnectionId: connectionId,
    );
    await updatePlaybook(_activePlaybook!);

    unawaited(_executeLoop());
  }

  Future<void> resumeExecution(String connectionId) async {
    if (_activePlaybook == null || !_isPaused) return;

    _isRunning = true;
    _isPaused = false;
    _activeConnectionId = connectionId;
    notifyListeners();

    unawaited(_executeLoop());
  }

  void pauseExecution() {
    if (!_isRunning) return;
    _isRunning = false;
    _isPaused = true;
    notifyListeners();
  }

  Future<void> skipCurrentStep(String connectionId) async {
    if (_activePlaybook == null ||
        _currentStepIndex < 0 ||
        _currentStepIndex >= _activePlaybook!.steps.length) {
      return;
    }

    final steps = [..._activePlaybook!.steps];
    steps[_currentStepIndex] = steps[_currentStepIndex].copyWith(
      status: StepStatus.skipped,
    );
    _activePlaybook = _activePlaybook!.copyWith(steps: steps);
    await updatePlaybook(_activePlaybook!);

    if (_currentStepIndex < steps.length - 1) {
      _currentStepIndex++;
      if (_isPaused) {
        _isRunning = true;
        _isPaused = false;
        notifyListeners();
        unawaited(_executeLoop());
      } else {
        notifyListeners();
      }
    } else {
      _isRunning = false;
      _isPaused = false;
      notifyListeners();
    }
  }

  Future<void> _executeLoop() async {
    if (_activePlaybook == null || _activeConnectionId == null) return;

    final playbookId = _activePlaybook!.id;
    final connId = _activeConnectionId!;

    while (_currentStepIndex < _activePlaybook!.steps.length && _isRunning) {
      final step = _activePlaybook!.steps[_currentStepIndex];

      // Update step status to running
      final stepsBefore = [..._activePlaybook!.steps];
      stepsBefore[_currentStepIndex] =
          step.copyWith(status: StepStatus.running);
      _activePlaybook = _activePlaybook!.copyWith(steps: stepsBefore);
      await updatePlaybook(_activePlaybook!);
      notifyListeners();

      AppLogService.instance.info(
        'Executing Playbook Step',
        details: 'playbook=$playbookId step=${step.id} name=${step.name}',
      );

      try {
        final result = await _sshService.runOneShotCommand(
          connectionId: connId,
          command: step.command,
        );

        final stdout = result.stdout;
        final stderr = result.stderr;
        final exitCode = result.exitCode;

        StepStatus finalStatus = StepStatus.success;
        if (exitCode != 0) {
          finalStatus = StepStatus.failed;
        } else if (step.expectedOutcomeRegex != null &&
            step.expectedOutcomeRegex!.isNotEmpty) {
          try {
            final reg = RegExp(step.expectedOutcomeRegex!);
            if (!reg.hasMatch(stdout)) {
              finalStatus = StepStatus.failed;
            }
          } catch (_) {
            finalStatus = StepStatus.failed;
          }
        }

        final stepsAfter = [..._activePlaybook!.steps];
        stepsAfter[_currentStepIndex] = step.copyWith(
          status: finalStatus,
          stdout: stdout,
          stderr: stderr,
          exitCode: exitCode,
        );
        _activePlaybook = _activePlaybook!.copyWith(steps: stepsAfter);
        await updatePlaybook(_activePlaybook!);

        if (finalStatus == StepStatus.failed) {
          _isRunning = false;
          _isPaused = true;
          AppLogService.instance.warning(
            'Playbook Step Failed',
            details:
                'playbook=$playbookId step=${step.id} name=${step.name} exitCode=$exitCode',
          );
          notifyListeners();
          break;
        }

        _currentStepIndex++;
        notifyListeners();
      } catch (e) {
        final stepsAfter = [..._activePlaybook!.steps];
        stepsAfter[_currentStepIndex] = step.copyWith(
          status: StepStatus.failed,
          stderr: e.toString(),
          exitCode: -1,
        );
        _activePlaybook = _activePlaybook!.copyWith(steps: stepsAfter);
        await updatePlaybook(_activePlaybook!);

        _isRunning = false;
        _isPaused = true;
        AppLogService.instance.error(
          'Playbook Step Exception',
          error: e,
          details: 'playbook=$playbookId step=${step.id} name=${step.name}',
        );
        notifyListeners();
        break;
      }
    }

    if (_currentStepIndex >= _activePlaybook!.steps.length) {
      _isRunning = false;
      _isPaused = false;
      AppLogService.instance.info(
        'Playbook Completed Successfully',
        details: 'playbook=$playbookId',
      );
      notifyListeners();
    }
  }
}
