part of '../playbook_screen.dart';

extension _PlaybookScreenPlaybooksList on _PlaybookScreenState {
  Widget _buildPlaybooksList(
    PlaybookViewModel viewModel,
    _PlaybookStrings strings,
    ColorScheme colorScheme,
  ) {
    final playbooks = viewModel.playbooks;

    if (playbooks.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              Icons.auto_awesome_motion_outlined,
              size: 64,
              color: colorScheme.primary.withValues(alpha: 0.5),
            ),
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
                height: 1.35,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () {
                viewModel.startNewPlaybook();
                if (_isCompactLayout) {
                  _mobileTabs.animateTo(1);
                }
              },
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
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final playbook = playbooks[index];
        final isSelected = viewModel.activePlaybook?.id == playbook.id;

        return Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: isSelected
                  ? colorScheme.primary
                  : colorScheme.outlineVariant,
              width: isSelected ? 1.5 : 1,
            ),
          ),
          color: isSelected
              ? colorScheme.primaryContainer.withValues(alpha: 0.1)
              : colorScheme.surface,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () {
              if (viewModel.isEditing) {
                viewModel.cancelEditing();
              }
              viewModel.selectPlaybook(playbook.id);
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
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
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
                      if (!viewModel.isRunning && !viewModel.isPaused) ...[
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            GestureDetector(
                              onTap:
                                  () {}, // Prevent tap bubble to parent InkWell
                              child: IconButton(
                                icon: const Icon(
                                  Icons.edit_note_outlined,
                                  size: 18,
                                ),
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                onPressed: () {
                                  viewModel.startEditing(playbook);
                                  if (_isCompactLayout) {
                                    _mobileTabs.animateTo(1);
                                  }
                                },
                              ),
                            ),
                            GestureDetector(
                              onTap:
                                  () {}, // Prevent tap bubble to parent InkWell
                              child: IconButton(
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                  size: 18,
                                  color: Colors.red,
                                ),
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                onPressed: () => _confirmDeletePlaybook(
                                  viewModel,
                                  playbook,
                                  strings,
                                ),
                              ),
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

  Future<void> _confirmDeletePlaybook(
    PlaybookViewModel viewModel,
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
      await viewModel.deletePlaybook(playbook.id);
    }
  }
}
