part of 'developer_panel_screen.dart';

final class _DeveloperPanelFpsCard extends StatelessWidget {
  const _DeveloperPanelFpsCard({required this.vm});

  final DeveloperPanelViewModel vm;

  @override
  Widget build(BuildContext context) {
    final fps = vm.fps;
    final fpsText = fps > 0 ? '${fps.toStringAsFixed(1)} FPS' : '— FPS';
    final fpsColor = fps >= 55
        ? Colors.green
        : fps >= 30
        ? Colors.orange
        : Colors.red;

    final uptime = vm.uptime;
    final h = uptime.inHours;
    final m = uptime.inMinutes.remainder(60);
    final s = uptime.inSeconds.remainder(60);
    final uptimeText =
        '${h}h ${m.toString().padLeft(2, '0')}m ${s.toString().padLeft(2, '0')}s';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.speed_rounded, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Frame Rate',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: fpsColor.withAlpha(30),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: fpsColor.withAlpha(100)),
                  ),
                  child: Text(
                    fpsText,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: fpsColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _developerMetricColumn(context, 'Uptime', uptimeText),
                const SizedBox(width: 24),
                _developerMetricColumn(
                  context,
                  'Jank Frames',
                  '${vm.jankCount}',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
