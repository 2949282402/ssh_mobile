import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/connection.dart';
import '../models/playbook.dart';
import '../services/app_settings.dart';
import '../services/playbook_service.dart';
import '../services/storage_service.dart';

class PlaybookScreen extends StatefulWidget {
  const PlaybookScreen({super.key});

  @override
  State<PlaybookScreen> createState() => _PlaybookScreenState();
}

class _PlaybookScreenState extends State<PlaybookScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _mobileTabs;

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
    final connections = context.watch<StorageService>().connections;

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

  Widget _buildPlaybooksList(
    PlaybookService service,
    _PlaybookStrings strings,
    ColorScheme colorScheme,
  ) {
    final playbooks = service.playbooks;

    if (playbooks.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.auto_awesome_motion_outlined,
                size: 64, color: colorScheme.primary.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            Text(
              strings.emptyTitle,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              strings.emptyHint,
              style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 13,
                  height: 1.35),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _startNewPlaybook,
              icon: const Icon(Icons.add_rounded),
              label: Text(strings.newPlaybook),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: playbooks.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final playbook = playbooks[index];
        final isSelected = service.activePlaybook?.id == playbook.id;

        return Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color:
                  isSelected ? colorScheme.primary : colorScheme.outlineVariant,
              width: isSelected ? 1.5 : 1,
            ),
          ),
          color: isSelected
              ? colorScheme.primaryContainer.withValues(alpha: 0.1)
              : colorScheme.surface,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () {
              if (_isEditing) {
                // If editing, cancel first
                setState(() {
                  _isEditing = false;
                  _editingPlaybook = null;
                  _clearStepControllers();
                });
              }
              service.selectPlaybook(playbook.id);
              if (_isCompactLayout) {
                _mobileTabs.animateTo(1);
              }
            },
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.rocket_launch_outlined,
                        color: isSelected
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          playbook.name,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: isSelected
                                ? colorScheme.primary
                                : colorScheme.onSurface,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  if (playbook.description.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      playbook.description,
                      style: TextStyle(
                          fontSize: 12, color: colorScheme.onSurfaceVariant),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${playbook.steps.length} ${strings.stepsCount}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (!service.isRunning && !service.isPaused) ...[
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_note_outlined,
                                  size: 18),
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              onPressed: () => _startEditing(playbook),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline_rounded,
                                  size: 18, color: Colors.red),
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              onPressed: () => _confirmDeletePlaybook(
                                  service, playbook, strings),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlaybookEditor(
    PlaybookService service,
    _PlaybookStrings strings,
    ColorScheme colorScheme,
  ) {
    return Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _editingPlaybook?.name.isEmpty == true
                    ? strings.newPlaybook
                    : strings.editPlaybook,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: strings.name,
                  hintText: 'e.g. Deploy Web Service',
                  border: const OutlineInputBorder(),
                ),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Name is required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _descriptionController,
                decoration: InputDecoration(
                  labelText: strings.description,
                  hintText: 'Describe what this playbook does...',
                  border: const OutlineInputBorder(),
                ),
                minLines: 2,
                maxLines: 4,
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    strings.steps,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  OutlinedButton.icon(
                    onPressed: _addStepToEditing,
                    icon: const Icon(Icons.add_rounded, size: 16),
                    label: Text(strings.addStep),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_stepControllers.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    'Please add at least one step.',
                    style: TextStyle(
                        color: colorScheme.error, fontStyle: FontStyle.italic),
                    textAlign: TextAlign.center,
                  ),
                ),
              ...List.generate(_stepControllers.length, (index) {
                final controllers = _stepControllers[index];
                return Card(
                  key: ValueKey(controllers.hashCode),
                  margin: const EdgeInsets.only(bottom: 16),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: colorScheme.outlineVariant),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            CircleAvatar(
                              radius: 12,
                              backgroundColor: colorScheme.primary,
                              child: Text(
                                '${index + 1}',
                                style: TextStyle(
                                    color: colorScheme.onPrimary,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${strings.step} ${index + 1}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const Spacer(),
                            if (_stepControllers.length > 1)
                              IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    color: Colors.red, size: 20),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () => _removeStepFromEditing(index),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: controllers['name'],
                          decoration: InputDecoration(
                            labelText: strings.stepName,
                            hintText: 'e.g. Check system status',
                            isDense: true,
                          ),
                          validator: (v) => v == null || v.trim().isEmpty
                              ? 'Step name is required'
                              : null,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: controllers['command'],
                          decoration: InputDecoration(
                            labelText: strings.stepCommand,
                            hintText: 'e.g. systemctl status nginx',
                            isDense: true,
                          ),
                          validator: (v) => v == null || v.trim().isEmpty
                              ? 'Command is required'
                              : null,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 13),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: controllers['description'],
                          decoration: InputDecoration(
                            labelText: strings.stepDesc,
                            hintText: 'What does this step do?',
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: controllers['expectedOutcomeRegex'],
                          decoration: InputDecoration(
                            labelText: strings.expectedRegex,
                            hintText: 'e.g. active \\(running\\)',
                            isDense: true,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => _cancelEditing(service),
                    child: Text(strings.cancel),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: () => _savePlaybook(service, strings),
                    child: Text(strings.save),
                  ),
                ],
              ),
              const SizedBox(height: 48),
            ],
          ),
        ));
  }

  Widget _buildExecutionDashboard(
    PlaybookService service,
    List<ConnectionConfig> connections,
    _PlaybookStrings strings,
    ColorScheme colorScheme,
  ) {
    final playbook = service.activePlaybook;
    if (playbook == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.rocket_launch_outlined,
                size: 64,
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            Text(
              strings.selectPlaybookPrompt,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    final hasConnectedServer =
        connections.any((c) => c.id == _selectedConnectionId);

    return Column(
      children: [
        // Server Connection Selector Card
        Card(
          margin: const EdgeInsets.all(12),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: colorScheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(Icons.dns_outlined, color: colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        strings.selectServer,
                        style: const TextStyle(
                            fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: connections
                                  .any((c) => c.id == _selectedConnectionId)
                              ? _selectedConnectionId
                              : null,
                          hint: Text(strings.selectServerHint),
                          isExpanded: true,
                          isDense: true,
                          items: connections.map((conn) {
                            return DropdownMenuItem<String>(
                              value: conn.id,
                              child: Text(
                                conn.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }).toList(),
                          onChanged: service.isRunning
                              ? null
                              : (v) {
                                  setState(() {
                                    _selectedConnectionId = v;
                                  });
                                },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // Playbook General Info Card
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      playbook.name,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    if (playbook.description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        playbook.description,
                        style: TextStyle(
                            fontSize: 13, color: colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 8),
        Divider(height: 1, color: colorScheme.outlineVariant),

        // Steps display list
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
            itemCount: playbook.steps.length,
            itemBuilder: (context, index) {
              final step = playbook.steps[index];
              final isCurrent = service.currentStepIndex == index;
              return _buildStepCard(index, step, isCurrent, playbook, service,
                  strings, colorScheme);
            },
          ),
        ),

        // Execution Floating Control Bar
        _buildControlBar(service, hasConnectedServer, strings, colorScheme),
      ],
    );
  }

  Widget _buildStepCard(
    int index,
    PlaybookStep step,
    bool isCurrent,
    Playbook playbook,
    PlaybookService service,
    _PlaybookStrings strings,
    ColorScheme colorScheme,
  ) {
    final isExpanded = _expandedSteps.contains(index);
    final hasOutput = (step.stdout != null && step.stdout!.isNotEmpty) ||
        (step.stderr != null && step.stderr!.isNotEmpty);

    Color statusColor;
    IconData statusIcon;
    Widget? trailingWidget;

    switch (step.status) {
      case StepStatus.success:
        statusColor = Colors.green;
        statusIcon = Icons.check_circle_rounded;
        break;
      case StepStatus.failed:
        statusColor = colorScheme.error;
        statusIcon = Icons.error_rounded;
        break;
      case StepStatus.running:
        statusColor = colorScheme.primary;
        statusIcon = Icons.sync_rounded;
        trailingWidget = const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
        break;
      case StepStatus.skipped:
        statusColor = colorScheme.onSurfaceVariant.withValues(alpha: 0.5);
        statusIcon = Icons.double_arrow_rounded;
        break;
      case StepStatus.pending:
        statusColor = colorScheme.onSurfaceVariant.withValues(alpha: 0.35);
        statusIcon = Icons.radio_button_unchecked_rounded;
        break;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: isCurrent
              ? colorScheme.primary
              : (step.status == StepStatus.failed
                  ? colorScheme.error
                  : colorScheme.outlineVariant),
          width: isCurrent ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: hasOutput
                ? () {
                    setState(() {
                      if (isExpanded) {
                        _expandedSteps.remove(index);
                      } else {
                        _expandedSteps.add(index);
                      }
                    });
                  }
                : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Status Icon
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: step.status == StepStatus.running
                        ? (trailingWidget ??
                            Icon(statusIcon, color: statusColor, size: 20))
                        : Icon(statusIcon, color: statusColor, size: 20),
                  ),
                  const SizedBox(width: 12),

                  // Content
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              '${strings.step} ${index + 1}: ',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: isCurrent
                                    ? colorScheme.primary
                                    : colorScheme.onSurface,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                step.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          step.command,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            backgroundColor: colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.5),
                            color: colorScheme.onSurface,
                          ),
                        ),
                        if (step.description.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            step.description,
                            style: TextStyle(
                                fontSize: 12,
                                color: colorScheme.onSurfaceVariant),
                          ),
                        ],
                        if (step.expectedOutcomeRegex != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            '${strings.regex}: ${step.expectedOutcomeRegex}',
                            style: TextStyle(
                              fontSize: 11,
                              fontStyle: FontStyle.italic,
                              color: colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.8),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  // Collapse / Expand toggle icon
                  if (hasOutput) ...[
                    const SizedBox(width: 8),
                    Icon(
                      isExpanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ],
                ],
              ),
            ),
          ),

          // AI Diagnostic Slot & Monospace Output Console
          if (step.status == StepStatus.failed) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(44, 0, 12, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    foregroundColor: colorScheme.primary,
                    backgroundColor:
                        colorScheme.primaryContainer.withValues(alpha: 0.3),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  icon: const Icon(Icons.smart_toy_outlined, size: 16),
                  label: Text(strings.aiDiagnostic),
                  onPressed: () =>
                      _requestAiDiagnostic(playbook, step, strings),
                ),
              ),
            ),
          ],

          if (hasOutput && isExpanded) ...[
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (step.exitCode != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '${strings.exitCode}: ${step.exitCode}',
                        style: const TextStyle(
                            color: Colors.yellowAccent,
                            fontFamily: 'monospace',
                            fontSize: 11),
                      ),
                    ),
                  if (step.stdout != null && step.stdout!.isNotEmpty) ...[
                    const Text(
                      'STDOUT:',
                      style: TextStyle(
                          color: Colors.greenAccent,
                          fontFamily: 'monospace',
                          fontSize: 10,
                          fontWeight: FontWeight.bold),
                    ),
                    Text(
                      step.stdout!,
                      style: const TextStyle(
                          color: Colors.white70,
                          fontFamily: 'monospace',
                          fontSize: 11),
                    ),
                    const SizedBox(height: 6),
                  ],
                  if (step.stderr != null && step.stderr!.isNotEmpty) ...[
                    const Text(
                      'STDERR:',
                      style: TextStyle(
                          color: Colors.redAccent,
                          fontFamily: 'monospace',
                          fontSize: 10,
                          fontWeight: FontWeight.bold),
                    ),
                    Text(
                      step.stderr!,
                      style: const TextStyle(
                          color: Colors.red,
                          fontFamily: 'monospace',
                          fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildControlBar(
    PlaybookService service,
    bool hasConnectedServer,
    _PlaybookStrings strings,
    ColorScheme colorScheme,
  ) {
    final activePlaybook = service.activePlaybook;
    if (activePlaybook == null) return const SizedBox.shrink();

    final isRunning = service.isRunning;
    final isPaused = service.isPaused;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        border: Border(top: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            // Start / Pause / Resume
            Expanded(
              child: () {
                if (isRunning) {
                  return FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.orangeAccent.shade700,
                    ),
                    icon: const Icon(Icons.pause_rounded),
                    label: Text(strings.pause),
                    onPressed: () {
                      service.pauseExecution();
                    },
                  );
                } else if (isPaused) {
                  return FilledButton.icon(
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(strings.resume),
                    onPressed: _selectedConnectionId == null
                        ? null
                        : () => service.resumeExecution(_selectedConnectionId!),
                  );
                } else {
                  return FilledButton.icon(
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(strings.start),
                    onPressed: _selectedConnectionId == null
                        ? null
                        : () {
                            service.startExecution(
                                activePlaybook.id, _selectedConnectionId!);
                          },
                  );
                }
              }(),
            ),

            const SizedBox(width: 8),

            // Skip Step
            if (isRunning || isPaused) ...[
              OutlinedButton.icon(
                icon: const Icon(Icons.skip_next_rounded),
                label: Text(strings.skip),
                onPressed: _selectedConnectionId == null
                    ? null
                    : () => service.skipCurrentStep(_selectedConnectionId!),
              ),
              const SizedBox(width: 8),
            ],

            // Reset
            OutlinedButton.icon(
              icon: const Icon(Icons.replay_rounded),
              label: Text(strings.reset),
              onPressed: () {
                service.resetPlaybook(activePlaybook.id);
                setState(() {
                  _expandedSteps.clear();
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  void _requestAiDiagnostic(
      Playbook playbook, PlaybookStep step, _PlaybookStrings strings) {
    final prompt =
        """My playbook step failed. Please diagnose and help me fix it!

Playbook: ${playbook.name}
Step Index: ${playbook.steps.indexOf(step) + 1}
Step Name: ${step.name}
Description: ${step.description}
Command executed: `${step.command}`
Exit code: ${step.exitCode}

Stdout:
${step.stdout ?? "(empty)"}

Stderr:
${step.stderr ?? "(empty)"}

Please analyze what went wrong and provide:
1. An explanation of why the command failed.
2. A corrected command or setup steps to fix this problem.""";

    // Set the prompt in the service
    context.read<PlaybookService>().pendingDiagnosticPrompt = prompt;

    // Pop current screen (if it was pushed on top of Home)
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    if (rootNavigator.canPop()) {
      rootNavigator.pop();
    }

    // Now trigger page index change to AI tab (index 0) in HomeScreen
    // Wait, how do we notify HomeScreen to switch to AI?
    // We can do it by finding the HomeScreen state or using a static method/callback,
    // or since HomeScreen uses PageController, let's see if we can trigger PageView jump.
    // Wait, let's look at what we have. In didChangeDependencies or build, the HomeScreen is a state.
    // Wait, is there a simple way to pop and set selected tab index?
    // Yes! If we navigate to home screen using pushing named `/` or `/home` or by simply popping back!
    // Since we popped back to HomeScreen, we can let HomeScreen look for active connection or just check if PlaybookService has a pending diagnostic prompt,
    // and if so, automatically jump to AI tab! Let's check this!
    // In `HomeScreen.initState` or `HomeScreen.build` or within a listener of `PlaybookService` in `HomeScreen`,
    // if `PlaybookService.pendingDiagnosticPrompt` is not null, `HomeScreen` can switch to tab index 0!
    // This is incredibly elegant and perfectly unified! Let's check if we can add a listener or check in `HomeScreen`!
  }

  Future<void> _confirmDeletePlaybook(
    PlaybookService service,
    Playbook playbook,
    _PlaybookStrings strings,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.deletePlaybook),
        content: Text(strings.deletePlaybookContent(playbook.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(strings.cancel),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(strings.delete),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await service.deletePlaybook(playbook.id);
    }
  }
}

class _PlaybookStrings {
  final AppLanguage language;

  const _PlaybookStrings(this.language);

  bool get _en => language == AppLanguage.en;

  String get title => _en ? 'Playbook Orchestrator' : '运维剧本与AI编排';
  String get newPlaybook => _en ? 'New Playbook' : '新建剧本';
  String get editPlaybook => _en ? 'Edit Playbook' : '编辑剧本';
  String get playbooksList => _en ? 'Playbooks' : '剧本列表';
  String get execution => _en ? 'Execution' : '执行控制';
  String get save => _en ? 'Save' : '保存';
  String get cancel => _en ? 'Cancel' : '取消';
  String get delete => _en ? 'Delete' : '删除';
  String get deletePlaybook => _en ? 'Delete Playbook' : '删除剧本';
  String deletePlaybookContent(String name) =>
      _en ? 'Are you sure you want to delete "$name"?' : '确定要删除剧本 "$name" 吗？';

  String get name => _en ? 'Playbook Name' : '剧本名称';
  String get description => _en ? 'Playbook Description' : '剧本描述';
  String get steps => _en ? 'Steps' : '执行步骤';
  String get stepsCount => _en ? 'steps' : '个步骤';
  String get step => _en ? 'Step' : '步骤';
  String get addStep => _en ? 'Add Step' : '添加步骤';

  String get stepName => _en ? 'Step Name' : '步骤名称';
  String get stepCommand => _en ? 'Execution Command' : '执行命令';
  String get stepDesc => _en ? 'Step Description' : '步骤描述';
  String get expectedRegex =>
      _en ? 'Expected Outcome Regex (Optional)' : '预期输出正则 (可选)';

  String get emptyTitle => _en ? 'No Playbooks Yet' : '暂无运维剧本';
  String get emptyHint => _en
      ? 'Create automated sequential task playbooks to run multiple SSH commands with step-by-step control, status tracking, and AI-assisted troubleshooting.'
      : '创建自动化的顺序执行剧本，一键运行多个服务器命令。支持分步追踪、执行失败自动暂停、一键拉起 AI 诊断及排障。';

  String get selectPlaybookPrompt =>
      _en ? 'Please select a playbook from the list' : '请先从左侧列表选择一个剧本';
  String get selectServer => _en ? 'Target Server' : '目标服务器';
  String get selectServerHint =>
      _en ? 'Please select a server connection' : '请选择执行该剧本的服务器';

  String get start => _en ? 'Start Execution' : '开始执行';
  String get pause => _en ? 'Pause' : '暂停';
  String get resume => _en ? 'Resume' : '继续执行';
  String get skip => _en ? 'Skip Step' : '跳过当前步';
  String get reset => _en ? 'Reset' : '重置状态';

  String get aiDiagnostic => _en ? 'Request AI Diagnostic' : '请求 AI 诊断';

  String get regex => _en ? 'Regex' : '预期正则';
  String get exitCode => _en ? 'Exit Code' : '退出状态码';
}
