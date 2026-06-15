part of '../playbook_screen.dart';

extension _PlaybookScreenPlaybookEditor on _PlaybookScreenState {
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
}
