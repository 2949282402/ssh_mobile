import 'package:flutter/material.dart';
import 'package:connection_core/connection_core.dart';
import '../../../services/playbook_service.dart';
import '../models/playbook.dart';
import '../../connection/models/connection.dart';

class PlaybookViewModel extends ChangeNotifier {
  final PlaybookService _playbookService;
  final ConnectionRepository _connectionRepository;

  // Edit states
  bool _isEditing = false;
  Playbook? _editingPlaybook;
  final GlobalKey<FormState> formKey = GlobalKey<FormState>();
  final TextEditingController nameController = TextEditingController();
  final TextEditingController descriptionController = TextEditingController();
  final List<Map<String, TextEditingController>> stepControllers = [];

  // Expanded step indices for output display
  final Set<int> _expandedSteps = {};

  // Selected execution connection ID
  String? _selectedConnectionId;

  PlaybookViewModel({
    required PlaybookService playbookService,
    required ConnectionRepository connectionRepository,
  }) : _playbookService = playbookService,
       _connectionRepository = connectionRepository {
    _playbookService.addListener(_onServiceChanged);
    _initializeDefaultConnection();
  }

  @override
  void dispose() {
    _playbookService.removeListener(_onServiceChanged);
    nameController.dispose();
    descriptionController.dispose();
    _clearStepControllers();
    super.dispose();
  }

  void _onServiceChanged() {
    notifyListeners();
  }

  // Getters proxying PlaybookService
  List<Playbook> get playbooks => _playbookService.playbooks;
  Playbook? get activePlaybook => _playbookService.activePlaybook;
  int get currentStepIndex => _playbookService.currentStepIndex;
  bool get isRunning => _playbookService.isRunning;
  bool get isPaused => _playbookService.isPaused;
  String? get activeConnectionId => _playbookService.activeConnectionId;
  String? get pendingDiagnosticPrompt =>
      _playbookService.pendingDiagnosticPrompt;

  set pendingDiagnosticPrompt(String? value) {
    _playbookService.pendingDiagnosticPrompt = value;
  }

  // Local state getters
  bool get isEditing => _isEditing;
  Playbook? get editingPlaybook => _editingPlaybook;
  Set<int> get expandedSteps => _expandedSteps;
  String? get selectedConnectionId => _selectedConnectionId;

  List<ConnectionConfig> get connections => _connectionRepository.connections;

  void _initializeDefaultConnection() {
    if (connections.isNotEmpty) {
      _selectedConnectionId = connections.first.id;
    }
  }

  void setSelectedConnectionId(String? id) {
    _selectedConnectionId = id;
    notifyListeners();
  }

  void selectPlaybook(String id) {
    _playbookService.selectPlaybook(id);
    final active = _playbookService.activePlaybook;
    if (active != null && active.lastConnectionId != null) {
      _selectedConnectionId = active.lastConnectionId;
    }
    notifyListeners();
  }

  void resetPlaybook(String id) {
    _playbookService.resetPlaybook(id);
  }

  Future<void> runPlaybook(String connectionId) async {
    if (activePlaybook == null) return;
    await _playbookService.startExecution(activePlaybook!.id, connectionId);
  }

  Future<void> resumePlaybook(String connectionId) async {
    await _playbookService.resumeExecution(connectionId);
  }

  void pausePlaybook() {
    _playbookService.pauseExecution();
  }

  Future<void> skipCurrentStep(String connectionId) async {
    await _playbookService.skipCurrentStep(connectionId);
  }

  Future<void> deletePlaybook(String id) async {
    await _playbookService.deletePlaybook(id);
  }

  // Editor Actions
  void _clearStepControllers() {
    if (stepControllers.isEmpty) return;
    final controllersToDispose = List<Map<String, TextEditingController>>.from(
      stepControllers,
    );
    stepControllers.clear();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final step in controllersToDispose) {
        step['name']?.dispose();
        step['command']?.dispose();
        step['description']?.dispose();
        step['expectedOutcomeRegex']?.dispose();
      }
    });
  }

  void _initStepControllers(Playbook playbook) {
    _clearStepControllers();
    for (final step in playbook.steps) {
      stepControllers.add({
        'name': TextEditingController(text: step.name),
        'command': TextEditingController(text: step.command),
        'description': TextEditingController(text: step.description),
        'expectedOutcomeRegex': TextEditingController(
          text: step.expectedOutcomeRegex ?? '',
        ),
      });
    }
  }

  void startEditing(Playbook playbook) {
    _isEditing = true;
    _editingPlaybook = playbook;
    nameController.text = playbook.name;
    descriptionController.text = playbook.description;
    _initStepControllers(playbook);
    notifyListeners();
  }

  void startNewPlaybook() {
    final now = DateTime.now();
    final newP = Playbook(
      id: 'playbook_${now.millisecondsSinceEpoch}',
      name: '',
      description: '',
      steps: [
        PlaybookStep(
          id: 'step_${now.millisecondsSinceEpoch}_0',
          name: '',
          command: '',
          description: '',
        ),
      ],
      createdAt: now,
      updatedAt: now,
    );
    startEditing(newP);
  }

  void addStepToEditing() {
    stepControllers.add({
      'name': TextEditingController(),
      'command': TextEditingController(),
      'description': TextEditingController(),
      'expectedOutcomeRegex': TextEditingController(),
    });
    notifyListeners();
  }

  void removeStepFromEditing(int index) {
    if (index >= 0 && index < stepControllers.length) {
      final controllers = stepControllers.removeAt(index);
      controllers['name']?.dispose();
      controllers['command']?.dispose();
      controllers['description']?.dispose();
      controllers['expectedOutcomeRegex']?.dispose();
      notifyListeners();
    }
  }

  void toggleStepExpanded(int index) {
    if (_expandedSteps.contains(index)) {
      _expandedSteps.remove(index);
    } else {
      _expandedSteps.add(index);
    }
    notifyListeners();
  }

  Future<void> savePlaybook() async {
    if (!formKey.currentState!.validate() || _editingPlaybook == null) return;

    final steps = <PlaybookStep>[];
    for (int i = 0; i < stepControllers.length; i++) {
      final name = stepControllers[i]['name']!.text.trim();
      final command = stepControllers[i]['command']!.text.trim();
      final description = stepControllers[i]['description']!.text.trim();
      final regex = stepControllers[i]['expectedOutcomeRegex']!.text.trim();

      steps.add(
        PlaybookStep(
          id: i < _editingPlaybook!.steps.length
              ? _editingPlaybook!.steps[i].id
              : 'step_${DateTime.now().millisecondsSinceEpoch}_$i',
          name: name,
          command: command,
          description: description,
          expectedOutcomeRegex: regex.isEmpty ? null : regex,
          status: i < _editingPlaybook!.steps.length
              ? _editingPlaybook!.steps[i].status
              : StepStatus.pending,
          stdout: i < _editingPlaybook!.steps.length
              ? _editingPlaybook!.steps[i].stdout
              : null,
          stderr: i < _editingPlaybook!.steps.length
              ? _editingPlaybook!.steps[i].stderr
              : null,
          exitCode: i < _editingPlaybook!.steps.length
              ? _editingPlaybook!.steps[i].exitCode
              : null,
        ),
      );
    }

    final updated = _editingPlaybook!.copyWith(
      name: nameController.text.trim(),
      description: descriptionController.text.trim(),
      steps: steps,
      updatedAt: DateTime.now(),
    );

    final isNew = !_playbookService.playbooks.any((p) => p.id == updated.id);

    if (isNew) {
      await _playbookService.createPlaybook(updated);
    } else {
      await _playbookService.updatePlaybook(updated);
    }

    _isEditing = false;
    _editingPlaybook = null;
    _clearStepControllers();
    _playbookService.selectPlaybook(updated.id);
    notifyListeners();
  }

  void cancelEditing() {
    _isEditing = false;
    _editingPlaybook = null;
    _clearStepControllers();
    final active = _playbookService.activePlaybook;
    if (active != null) {
      _playbookService.selectPlaybook(active.id);
    }
    notifyListeners();
  }
}
