import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import '../data/repositories/playbook_repository.dart';
import '../domain/playbook_models.dart';
import '../domain/playbook_ports.dart';
import '../features/playbook/models/playbook.dart';

/// Playbook 的状态机、审批绑定和串行 SSH 执行器。
///
/// Service 不创建数据库、SSH 或日志单例；所有跨层能力由 Module 通过 Port
/// 注入。命令和目标在执行期间使用快照，避免异步编辑改变已审批动作。
class PlaybookService extends ChangeNotifier implements PlaybookAutomationPort {
  PlaybookService({
    required PlaybookRepository repository,
    required PlaybookSshPort sshPort,
    required PlaybookLoggerPort logger,
  }) : this._fromPorts(repository, sshPort, logger);

  PlaybookService._fromPorts(this._repository, this._sshPort, this._logger);

  final PlaybookRepository _repository;
  final PlaybookSshPort _sshPort;
  final PlaybookLoggerPort _logger;

  List<Playbook> _playbooks = [];
  Playbook? _activePlaybook;
  int _currentStepIndex = -1;
  bool _isRunning = false;
  bool _isPaused = false;
  String? _activeConnectionId;
  int _nextRunGeneration = 0;
  _PlaybookExecutionRun? _activeRun;
  Completer<void>? _runStateOperation;
  Completer<void>? _commandInFlight;
  bool _disposed = false;
  Future<void>? _initializeFuture;

  String? _pendingDiagnosticPrompt;

  /// Module 初始化时载入剧本；重复调用共享同一个 Future。
  Future<void> initialize() => _initializeFuture ??= _loadPlaybooks();

  /// 重新读取当前 Package 数据库。
  Future<void> reload() => _loadPlaybooks();

  @override
  String? get pendingDiagnosticPrompt => _pendingDiagnosticPrompt;

  @override
  set pendingDiagnosticPrompt(String? value) {
    _pendingDiagnosticPrompt = value;
    _notifyListeners();
  }

  @override
  List<Playbook> get playbooks => List.unmodifiable(_playbooks);
  @override
  Playbook? get activePlaybook => _activePlaybook;
  @override
  int get currentStepIndex => _currentStepIndex;
  @override
  bool get isRunning => _isRunning;
  @override
  bool get isPaused => _isPaused;
  String? get activeConnectionId => _activeConnectionId;

  Future<void> _loadPlaybooks() async {
    final playbooks = await _repository.loadPlaybooks();
    if (_disposed) return;
    _playbooks = playbooks;
    _notifyListeners();
  }

  Future<void> createPlaybook(Playbook playbook) async {
    await _repository.savePlaybook(playbook);
    await _loadPlaybooks();
  }

  Future<void> updatePlaybook(Playbook playbook) async {
    if (_activePlaybook?.id == playbook.id &&
        _activeRun?.approvedActionFingerprint == null) {
      _activePlaybook = playbook;
    }
    await _repository.savePlaybook(playbook);
    await _loadPlaybooks();
  }

  Future<void> deletePlaybook(String id) async {
    if (_activePlaybook?.id == id) {
      _activePlaybook = null;
      _currentStepIndex = -1;
      _isRunning = false;
      _isPaused = false;
      _invalidateActiveRun();
    }
    await _repository.deletePlaybook(id);
    await _loadPlaybooks();
  }

  void selectPlaybook(String playbookId) {
    try {
      _activePlaybook = _playbooks.firstWhere((p) => p.id == playbookId);
      _currentStepIndex = -1;
      _isRunning = false;
      _isPaused = false;
      _invalidateActiveRun();
      _notifyListeners();
    } catch (e) {
      _logger.error('Playbook not found: $playbookId');
    }
  }

  void resetPlaybook(String playbookId) {
    final index = _playbooks.indexWhere((p) => p.id == playbookId);
    if (index == -1) return;

    final original = _playbooks[index];
    final resetSteps = original.steps
        .map(
          (s) => s.copyWith(
            status: StepStatus.pending,
            stdout: null,
            stderr: null,
            exitCode: null,
          ),
        )
        .toList();

    final resetPlaybook = original.copyWith(
      steps: resetSteps,
      updatedAt: DateTime.now(),
    );

    if (_activePlaybook?.id == playbookId) {
      _invalidateActiveRun();
      _activePlaybook = resetPlaybook;
      _currentStepIndex = -1;
      _isRunning = false;
      _isPaused = false;
    }

    updatePlaybook(resetPlaybook);
  }

  @override
  Future<void> startExecution(String playbookId, String connectionId) async {
    selectPlaybook(playbookId);
    final selectedPlaybook = _activePlaybook;
    if (selectedPlaybook == null) return;

    final commandSteps = _snapshotSteps(selectedPlaybook.steps);
    final runningPlaybook = _copyPlaybook(selectedPlaybook).copyWith(
      steps: commandSteps.map(_cleanStep).toList(growable: false),
      lastConnectionId: connectionId,
    );
    final run = _createRun(
      playbookId: runningPlaybook.id,
      connectionId: connectionId,
      commandSteps: commandSteps,
    );
    _activatePendingRun(run, runningPlaybook);

    if (!await _persistRunState(run, runningPlaybook)) return;
    if (!_publishRunState(
      run,
      playbook: runningPlaybook,
      stepIndex: 0,
      isRunning: true,
      isPaused: false,
    )) {
      return;
    }
    unawaited(_executeLoop(run, runningPlaybook, 0));
  }

  /// Starts the exact playbook action and server target the user approved.
  /// Commands are always read from the deep-copied approval snapshot.
  Future<bool> startApprovedExecution({
    required Playbook playbook,
    required String actionFingerprint,
    required ssh_core.SshTargetBinding connectionTarget,
  }) async {
    final approvedPlaybook = Playbook.fromJson(playbook.toJson());
    final approvedSteps = _snapshotSteps(approvedPlaybook.steps);
    final cleanSteps = approvedSteps.map(_cleanStep).toList(growable: false);
    final runningPlaybook = approvedPlaybook.copyWith(
      steps: cleanSteps,
      updatedAt: DateTime.now(),
      lastConnectionId: connectionTarget.id,
    );
    final run = _createRun(
      playbookId: runningPlaybook.id,
      connectionId: connectionTarget.id,
      commandSteps: approvedSteps,
      connectionBinding: connectionTarget,
      approvedActionFingerprint: actionFingerprint,
    );
    _activatePendingRun(run, runningPlaybook);

    if (!await _persistRunState(
      run,
      runningPlaybook,
      pauseOnRejectedWrite: false,
    )) {
      return false;
    }
    if (!_publishRunState(
      run,
      playbook: runningPlaybook,
      stepIndex: 0,
      isRunning: true,
      isPaused: false,
    )) {
      return false;
    }
    unawaited(_executeLoop(run, runningPlaybook, 0));
    return true;
  }

  /// 以 AI 公共契约暴露审批后的绑定执行，避免调用方依赖 Service 实现。
  @override
  Future<bool> startApprovedExecutionForBinding({
    required Playbook playbook,
    required String actionFingerprint,
    required ssh_core.SshTargetBinding connectionTarget,
  }) {
    return startApprovedExecution(
      playbook: playbook,
      actionFingerprint: actionFingerprint,
      connectionTarget: connectionTarget,
    );
  }

  Future<void> resumeExecution(String connectionId) async {
    await _waitForCommandIdle();
    final playbook = _activePlaybook;
    final previousRun = _activeRun;
    if (playbook == null || previousRun == null || !_isPaused) return;

    final run = _createSuccessorRun(
      previousRun,
      connectionId: previousRun.connectionBinding == null
          ? connectionId
          : previousRun.connectionId,
    );
    _activeRun = run;
    _activeConnectionId = run.connectionId;
    _isRunning = true;
    _isPaused = false;
    _notifyListeners();

    unawaited(_executeLoop(run, _copyPlaybook(playbook), _currentStepIndex));
  }

  void pauseExecution() {
    if (!_isRunning) return;
    final previousRun = _activeRun;
    if (previousRun != null) {
      _activeRun = _createSuccessorRun(previousRun);
    }
    _isRunning = false;
    _isPaused = true;
    _notifyListeners();
  }

  Future<void> skipCurrentStep(String connectionId) async {
    if (_isRunning) return;
    await _waitForCommandIdle();
    final activePlaybook = _activePlaybook;
    final previousRun = _activeRun;
    if (activePlaybook == null ||
        previousRun == null ||
        _isRunning ||
        _currentStepIndex < 0 ||
        _currentStepIndex >= activePlaybook.steps.length) {
      return;
    }

    final wasPaused = _isPaused;
    final run = _createSuccessorRun(
      previousRun,
      connectionId: previousRun.connectionBinding == null
          ? connectionId
          : previousRun.connectionId,
    );
    _activeRun = run;
    _activeConnectionId = run.connectionId;

    final playbook = _copyPlaybook(activePlaybook);
    final steps = [...playbook.steps];
    steps[_currentStepIndex] = steps[_currentStepIndex].copyWith(
      status: StepStatus.skipped,
    );
    final skippedPlaybook = playbook.copyWith(steps: steps);
    if (!await _persistRunState(run, skippedPlaybook)) return;

    if (_currentStepIndex < steps.length - 1) {
      final nextStepIndex = _currentStepIndex + 1;
      final shouldContinue = wasPaused;
      if (!_publishRunState(
        run,
        playbook: skippedPlaybook,
        stepIndex: nextStepIndex,
        isRunning: shouldContinue,
        isPaused: !shouldContinue && wasPaused,
      )) {
        return;
      }
      if (shouldContinue) {
        unawaited(_executeLoop(run, skippedPlaybook, nextStepIndex));
      }
    } else {
      _publishRunState(
        run,
        playbook: skippedPlaybook,
        stepIndex: _currentStepIndex,
        isRunning: false,
        isPaused: false,
      );
    }
  }

  Future<void> _executeLoop(
    _PlaybookExecutionRun run,
    Playbook initialPlaybook,
    int initialStepIndex,
  ) async {
    var playbook = initialPlaybook;
    var stepIndex = initialStepIndex;

    while (stepIndex < run.commandSteps.length) {
      if (!_isCurrentRun(run) || !_isRunning) return;
      if (stepIndex < 0 || stepIndex >= playbook.steps.length) {
        _stopCurrentRun(run, paused: true);
        return;
      }

      final step = run.commandSteps[stepIndex];
      final stepsBefore = [...playbook.steps];
      stepsBefore[stepIndex] = _stepWithResult(
        step,
        status: StepStatus.running,
      );
      playbook = playbook.copyWith(steps: stepsBefore);
      if (!await _persistRunState(run, playbook)) return;
      if (!_publishRunState(
        run,
        playbook: playbook,
        stepIndex: stepIndex,
        isRunning: true,
        isPaused: false,
      )) {
        return;
      }
      if (!_isCurrentRun(run) || !_isRunning) return;

      _logger.info(
        'Executing Playbook Step',
        details:
            'playbook=${run.playbookId} generation=${run.generation} '
            'step=${step.id} name=${step.name}',
      );

      try {
        final connectionBinding = run.connectionBinding;
        final result = await _runCommandIfCurrent(
          run,
          () => connectionBinding == null
              ? _sshPort.runCommand(
                  connectionId: run.connectionId,
                  command: step.command,
                  timeout: const Duration(seconds: 15),
                )
              : _sshPort.runCommandForBinding(
                  binding: connectionBinding,
                  command: step.command,
                  timeout: const Duration(seconds: 15),
                ),
        );
        if (result == null) return;
        if (!_isCurrentRun(run)) return;

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

        final stepsAfter = [...playbook.steps];
        stepsAfter[stepIndex] = _stepWithResult(
          step,
          status: finalStatus,
          stdout: stdout,
          stderr: stderr,
          exitCode: exitCode,
        );
        playbook = playbook.copyWith(steps: stepsAfter);
        if (!await _persistRunState(run, playbook)) return;

        if (finalStatus == StepStatus.failed) {
          _logger.warning(
            'Playbook Step Failed',
            details:
                'playbook=${run.playbookId} generation=${run.generation} '
                'step=${step.id} name=${step.name} exitCode=$exitCode',
          );
          _publishRunState(
            run,
            playbook: playbook,
            stepIndex: stepIndex,
            isRunning: false,
            isPaused: true,
          );
          return;
        }

        stepIndex++;
        if (!_publishRunState(
          run,
          playbook: playbook,
          stepIndex: stepIndex,
          isRunning: true,
          isPaused: false,
        )) {
          return;
        }
      } catch (e) {
        if (!_isCurrentRun(run)) return;
        final stepsAfter = [...playbook.steps];
        stepsAfter[stepIndex] = _stepWithResult(
          step,
          status: StepStatus.failed,
          stderr: e.toString(),
          exitCode: -1,
        );
        playbook = playbook.copyWith(steps: stepsAfter);
        if (!await _persistRunState(run, playbook)) return;
        _logger.error(
          'Playbook Step Exception',
          error: e,
          details:
              'playbook=${run.playbookId} generation=${run.generation} '
              'step=${step.id} name=${step.name}',
        );
        _publishRunState(
          run,
          playbook: playbook,
          stepIndex: stepIndex,
          isRunning: false,
          isPaused: true,
        );
        return;
      }
    }

    if (_isCurrentRun(run) && stepIndex >= run.commandSteps.length) {
      _logger.info(
        'Playbook Completed Successfully',
        details: 'playbook=${run.playbookId} generation=${run.generation}',
      );
      _publishRunState(
        run,
        playbook: playbook,
        stepIndex: stepIndex,
        isRunning: false,
        isPaused: false,
      );
    }
  }

  Future<bool> _persistRunState(
    _PlaybookExecutionRun run,
    Playbook playbook, {
    bool pauseOnRejectedWrite = true,
  }) {
    return _runExclusiveStateOperation(() async {
      if (!_isCurrentRun(run) || playbook.id != run.playbookId) return false;

      final fingerprint = run.approvedActionFingerprint;
      final saved = fingerprint == null
          ? await _saveUnapprovedRunState(playbook)
          : await _repository.savePlaybookIfActionUnchanged(
              playbookId: run.playbookId,
              expectedActionFingerprint: fingerprint,
              playbook: playbook,
            );
      if (!saved) {
        if (_isCurrentRun(run)) {
          _logger.warning(
            'Approved playbook changed during execution',
            details: 'playbook=${run.playbookId} generation=${run.generation}',
          );
          if (pauseOnRejectedWrite) {
            _isRunning = false;
            _isPaused = true;
          } else {
            _activeRun = null;
            _isRunning = false;
            _isPaused = false;
          }
          _notifyListeners();
        }
        return false;
      }

      if (!_isCurrentRun(run)) return false;
      await _saveRunSnapshot(run, playbook);
      final playbooks = await _repository.loadPlaybooks();
      if (!_isCurrentRun(run)) return false;
      _playbooks = playbooks;
      return true;
    });
  }

  Future<bool> _saveUnapprovedRunState(Playbook playbook) async {
    await _repository.savePlaybook(playbook);
    return true;
  }

  /// 将当前执行状态写入独立历史表；命令和输出由 Repository 加密。
  Future<void> _saveRunSnapshot(
    _PlaybookExecutionRun run,
    Playbook playbook,
  ) async {
    final hasFailure = playbook.steps.any(
      (step) => step.status == StepStatus.failed,
    );
    final isFinished =
        playbook.steps.isNotEmpty &&
        playbook.steps.every(
          (step) =>
              step.status == StepStatus.success ||
              step.status == StepStatus.skipped,
        );
    final status = _isRunning
        ? 'running'
        : _isPaused
        ? 'paused'
        : isFinished
        ? 'success'
        : hasFailure
        ? 'failed'
        : 'pending';
    PlaybookStep? failedStep;
    for (final step in playbook.steps) {
      if (step.status == StepStatus.failed) {
        failedStep = step;
        break;
      }
    }
    await _repository.saveRunSnapshot(
      PlaybookRunSnapshot(
        id: run.id,
        playbookId: run.playbookId,
        connectionId: run.connectionId,
        status: status,
        startedAt: run.startedAt,
        finishedAt: isFinished || hasFailure ? DateTime.now() : null,
        summary: '',
        errorMessage: failedStep?.stderr,
        steps: [
          for (var index = 0; index < playbook.steps.length; index++)
            PlaybookRunStepSnapshot(
              id: '${run.id}-$index',
              stepIndex: index,
              step: playbook.steps[index],
            ),
        ],
      ),
    );
  }

  Future<T> _runExclusiveStateOperation<T>(
    Future<T> Function() operation,
  ) async {
    while (true) {
      final active = _runStateOperation;
      if (active != null) {
        await active.future;
        continue;
      }
      final ticket = Completer<void>();
      _runStateOperation = ticket;
      try {
        return await operation();
      } finally {
        if (identical(_runStateOperation, ticket)) {
          _runStateOperation = null;
        }
        ticket.complete();
      }
    }
  }

  Future<void> _waitForCommandIdle() async {
    while (true) {
      final active = _commandInFlight;
      if (active == null) return;
      await active.future;
    }
  }

  Future<T?> _runCommandIfCurrent<T>(
    _PlaybookExecutionRun run,
    Future<T> Function() command,
  ) async {
    while (true) {
      final active = _commandInFlight;
      if (active != null) {
        await active.future;
        continue;
      }
      if (!_isCurrentRun(run) || !_isRunning) return null;

      final ticket = Completer<void>();
      _commandInFlight = ticket;
      try {
        if (!_isCurrentRun(run) || !_isRunning) return null;
        return await command();
      } finally {
        if (identical(_commandInFlight, ticket)) {
          _commandInFlight = null;
        }
        if (!ticket.isCompleted) ticket.complete();
      }
    }
  }

  _PlaybookExecutionRun _createRun({
    required String playbookId,
    required String connectionId,
    required List<PlaybookStep> commandSteps,
    ssh_core.SshTargetBinding? connectionBinding,
    String? approvedActionFingerprint,
    DateTime? startedAt,
  }) {
    return _PlaybookExecutionRun(
      generation: ++_nextRunGeneration,
      playbookId: playbookId,
      connectionId: connectionId,
      commandSteps: _snapshotSteps(commandSteps),
      connectionBinding: connectionBinding,
      approvedActionFingerprint: approvedActionFingerprint,
      startedAt: startedAt ?? DateTime.now(),
    );
  }

  _PlaybookExecutionRun _createSuccessorRun(
    _PlaybookExecutionRun previous, {
    String? connectionId,
  }) {
    return _createRun(
      playbookId: previous.playbookId,
      connectionId: connectionId ?? previous.connectionId,
      commandSteps: previous.commandSteps,
      connectionBinding: previous.connectionBinding,
      approvedActionFingerprint: previous.approvedActionFingerprint,
      startedAt: previous.startedAt,
    );
  }

  void _activatePendingRun(_PlaybookExecutionRun run, Playbook playbook) {
    _activeRun = run;
    _activePlaybook = playbook;
    _activeConnectionId = run.connectionId;
    _currentStepIndex = 0;
    _isRunning = false;
    _isPaused = false;
  }

  bool _publishRunState(
    _PlaybookExecutionRun run, {
    required Playbook playbook,
    required int stepIndex,
    required bool isRunning,
    required bool isPaused,
  }) {
    if (!_isCurrentRun(run) || playbook.id != run.playbookId) return false;
    _activePlaybook = playbook;
    _activeConnectionId = run.connectionId;
    _currentStepIndex = stepIndex;
    _isRunning = isRunning;
    _isPaused = isPaused;
    _notifyListeners();
    return true;
  }

  void _stopCurrentRun(_PlaybookExecutionRun run, {required bool paused}) {
    if (!_isCurrentRun(run)) return;
    _isRunning = false;
    _isPaused = paused;
    _notifyListeners();
  }

  bool _isCurrentRun(_PlaybookExecutionRun run) => identical(_activeRun, run);

  void _invalidateActiveRun() {
    _activeRun = null;
  }

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _invalidateActiveRun();
    super.dispose();
  }

  static Playbook _copyPlaybook(Playbook playbook) =>
      Playbook.fromJson(playbook.toJson());

  static List<PlaybookStep> _snapshotSteps(Iterable<PlaybookStep> steps) =>
      List<PlaybookStep>.unmodifiable(
        steps.map((step) => PlaybookStep.fromJson(step.toJson())),
      );

  static PlaybookStep _cleanStep(PlaybookStep step) =>
      _stepWithResult(step, status: StepStatus.pending);

  static PlaybookStep _stepWithResult(
    PlaybookStep step, {
    required StepStatus status,
    String? stdout,
    String? stderr,
    int? exitCode,
  }) {
    return PlaybookStep(
      id: step.id,
      name: step.name,
      command: step.command,
      description: step.description,
      expectedOutcomeRegex: step.expectedOutcomeRegex,
      status: status,
      stdout: stdout,
      stderr: stderr,
      exitCode: exitCode,
    );
  }
}

@immutable
class _PlaybookExecutionRun {
  final int generation;
  final String playbookId;
  final String connectionId;
  final List<PlaybookStep> commandSteps;
  final ssh_core.SshTargetBinding? connectionBinding;
  final String? approvedActionFingerprint;
  final DateTime startedAt;

  const _PlaybookExecutionRun({
    required this.generation,
    required this.playbookId,
    required this.connectionId,
    required this.commandSteps,
    required this.connectionBinding,
    required this.approvedActionFingerprint,
    required this.startedAt,
  });

  /// Stable history row id for this execution generation.
  String get id => '$playbookId-$generation';
}
