part of 'developer_panel_screen.dart';

final class _DeveloperPanelMemoryCard extends StatelessWidget {
  const _DeveloperPanelMemoryCard({required this.vm});

  final DeveloperPanelViewModel vm;

  @override
  Widget build(BuildContext context) {
    final memMB = vm.memoryMB;
    final memText = vm.memoryBytes >= 0
        ? '${memMB.toStringAsFixed(1)} MB'
        : 'N/A (Web)';
    final memRatio = memMB > 0 ? (memMB / 512).clamp(0.0, 1.0) : 0.0;
    final memColor = memMB > 256
        ? Colors.red
        : memMB > 128
        ? Colors.orange
        : Colors.green;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.memory_rounded, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Memory (RSS)',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                Flexible(
                  child: Text(
                    memText,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: memColor,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ],
            ),
            if (vm.memoryBytes >= 0) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: memRatio,
                  minHeight: 6,
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation(memColor),
                ),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  '~${memMB.toStringAsFixed(0)} / 512 MB',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            if (vm.nativeMemory != null) ...[
              const SizedBox(height: 12),
              _buildMemoryBreakdown(context, vm.nativeMemory!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMemoryBreakdown(
    BuildContext context,
    DeveloperNativeMemorySnapshot m,
  ) {
    final scheme = Theme.of(context).colorScheme;
    Widget cell(String label, double mb) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 2),
          Text(
            '${mb.toStringAsFixed(0)} MB',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'OS 分类 (Android)',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            cell('Java', m.javaHeapMB),
            const SizedBox(width: 12),
            cell('Native', m.nativeHeapMB),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            cell('Graphics', m.graphicsMB),
            const SizedBox(width: 12),
            cell('Code', m.codeMB),
          ],
        ),
      ],
    );
  }
}
