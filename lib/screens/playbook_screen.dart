import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/connection.dart';
import '../models/playbook.dart';
import '../services/app_settings.dart';
import '../services/playbook_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/overflow_scroll_text.dart';

part 'playbook/playbook_strings.dart';
part 'playbook/playbooks_list.dart';
part 'playbook/playbook_editor.dart';
part 'playbook/execution_dashboard.dart';

class PlaybookScreen extends StatefulWidget {
  const PlaybookScreen({super.key});

  @override
  State<PlaybookScreen> createState() => _PlaybookScreenState();
}

class _PlaybookScreenState extends State<PlaybookScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _mobileTabs;

  void _updateState(VoidCallback fn) => setState(fn);

  // Edit state
  bool _isEditing = false;
  Playbook? _editingPlaybook;
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final List<Map<String, TextEditingController>> _stepControllers = [];

  // Active Connection selection
  String? _selectedConnectionId;

  // Expanded step indices for output display
  final Set<int> _expandedSteps = {};

  @override
  void initState() {
    super.initState();
    _mobileTabs = TabController(length: 2, vsync: this);

    // Select default connection on load if available
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final connections = context.read<StorageService>().connections;
      if (connections.isNotEmpty) {
        setState(() {
          _selectedConnectionId = connections.first.id;
        });
      }
    });
  }

  @override
  void dispose() {
    _mobileTabs.dispose();
    _nameController.dispose();
    _descriptionController.dispose();
    _clearStepControllers();
    super.dispose();
  }

  void _clearStepControllers() {
    for (final step in _stepControllers) {
      step['name']?.dispose();
      step['command']?.dispose();
      step['description']?.dispose();
      step['expectedOutcomeRegex']?.dispose();
    }
    _stepControllers.clear();
  }

  void _initStepControllers(Playbook playbook) {
    _clearStepControllers();
    for (final step in playbook.steps) {
      _stepControllers.add({
        'name': TextEditingController(text: step.name),
        'command': TextEditingController(text: step.command),
        'description': TextEditingController(text: step.description),
        'expectedOutcomeRegex':
            TextEditingController(text: step.expectedOutcomeRegex ?? ''),
      });
    }
  }

  void _startEditing(Playbook playbook) {
    setState(() {
      _isEditing = true;
      _editingPlaybook = playbook;
      _nameController.text = playbook.name;
      _descriptionController.text = playbook.description;
      _initStepControllers(playbook);
    });
    if (_isCompactLayout) {
      _mobileTabs.animateTo(1);
    }
  }

  void _startNewPlaybook() {
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
    _startEditing(newP);
  }

  void _addStepToEditing() {
    setState(() {
      _stepControllers.add({
        'name': TextEditingController(),
        'command': TextEditingController(),
        'description': TextEditingController(),
        'expectedOutcomeRegex': TextEditingController(),
      });
    });
  }

  void _removeStepFromEditing(int index) {
    setState(() {
      final controllers = _stepControllers.removeAt(index);
      controllers['name']?.dispose();
      controllers['command']?.dispose();
      controllers['description']?.dispose();
      controllers['expectedOutcomeRegex']?.dispose();
    });
  }

  Future<void> _savePlaybook(
      PlaybookService service, _PlaybookStrings strings) async {
    if (!_formKey.currentState!.validate() || _editingPlaybook == null) return;

    final steps = <PlaybookStep>[];
    for (int i = 0; i < _stepControllers.length; i++) {
      final name = _stepControllers[i]['name']!.text.trim();
      final command = _stepControllers[i]['command']!.text.trim();
      final description = _stepControllers[i]['description']!.text.trim();
      final regex = _stepControllers[i]['expectedOutcomeRegex']!.text.trim();

      steps.add(PlaybookStep(
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
      ));
    }

    final updated = _editingPlaybook!.copyWith(
      name: _nameController.text.trim(),
      description: _descriptionController.text.trim(),
      steps: steps,
      updatedAt: DateTime.now(),
    );

    final isNew = !service.playbooks.any((p) => p.id == updated.id);

    if (isNew) {
      await service.createPlaybook(updated);
    } else {
      await service.updatePlaybook(updated);
    }

    setState(() {
      _isEditing = false;
      _editingPlaybook = null;
      _clearStepControllers();
    });

    service.selectPlaybook(updated.id);
  }

  void _cancelEditing(PlaybookService service) {
    setState(() {
      _isEditing = false;
      _editingPlaybook = null;
      _clearStepControllers();
    });
    if (service.activePlaybook != null) {
      service.selectPlaybook(service.activePlaybook!.id);
    }
  }

  bool get _isCompactLayout {
    final width = MediaQuery.maybeSizeOf(context)?.width;
    return width != null && width < 760;
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = _PlaybookStrings(language);
    final colorScheme = Theme.of(context).colorScheme;
    final playbookService = context.watch<PlaybookService>();
    final connections = context.select<StorageService, List<ConnectionConfig>>(
      (s) => s.connections,
    );

    // Resolve active selection
    final activePlaybook = playbookService.activePlaybook;
    if (_selectedConnectionId == null && connections.isNotEmpty) {
      _selectedConnectionId =
          activePlaybook?.lastConnectionId ?? connections.first.id;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.title),
        actions: [
          if (!_isEditing) ...[
            IconButton(
              tooltip: strings.newPlaybook,
              icon: const Icon(Icons.add_rounded),
              onPressed: _startNewPlaybook,
            ),
          ] else ...[
            IconButton(
              tooltip: strings.save,
              icon: const Icon(Icons.save_outlined),
              onPressed: () => _savePlaybook(playbookService, strings),
            ),
            IconButton(
              tooltip: strings.cancel,
              icon: const Icon(Icons.close_rounded),
              onPressed: () => _cancelEditing(playbookService),
            ),
          ]
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 760;
          final listWidget =
              _buildPlaybooksList(playbookService, strings, colorScheme);
          final rightWidget = _isEditing
              ? _buildPlaybookEditor(playbookService, strings, colorScheme)
              : _buildExecutionDashboard(
                  playbookService, connections, strings, colorScheme);

          if (wide) {
            return Row(
              children: [
                SizedBox(width: 320, child: listWidget),
                VerticalDivider(width: 1, color: colorScheme.outlineVariant),
                Expanded(child: rightWidget),
              ],
            );
          }

          return Column(
            children: [
              Material(
                color: colorScheme.surface,
                child: TabBar(
                  controller: _mobileTabs,
                  tabs: [
                    Tab(text: strings.playbooksList),
                    Tab(
                        text: _isEditing
                            ? strings.editPlaybook
                            : strings.execution),
                  ],
                ),
              ),
              Divider(height: 1, color: colorScheme.outlineVariant),
              Expanded(
                child: TabBarView(
                  controller: _mobileTabs,
                  children: [listWidget, rightWidget],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
