part of 'developer_panel_screen.dart';

final class _DeveloperPanelFrameCard extends StatelessWidget {
  const _DeveloperPanelFrameCard({required this.vm});

  final DeveloperPanelViewModel vm;

  @override
  Widget build(BuildContext context) {
    final jankRatio = vm.frameCount > 0
        ? (vm.jankCount / vm.frameCount * 100).toStringAsFixed(1)
        : '0.0';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.bar_chart_rounded, size: 20),
                SizedBox(width: 8),
                Text(
                  'Frame Stats',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(
                  flex: 1,
                  child: _developerMetricColumn(
                    context,
                    'Total Frames',
                    '${vm.frameCount}',
                  ),
                ),
                Flexible(
                  flex: 1,
                  child: _developerMetricColumn(
                    context,
                    'Jank Rate',
                    '$jankRatio%',
                  ),
                ),
                Flexible(
                  flex: 1,
                  child: _developerMetricColumn(
                    context,
                    'Threshold',
                    '${DeveloperPanelViewModel.jankThresholdMs.toStringAsFixed(0)}ms',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(
                  flex: 1,
                  child: _developerMetricColumn(
                    context,
                    'UI Build',
                    '${vm.avgBuildMs.toStringAsFixed(1)} ms',
                  ),
                ),
                Flexible(
                  flex: 1,
                  child: _developerMetricColumn(
                    context,
                    'GPU Raster',
                    '${vm.avgRasterMs.toStringAsFixed(1)} ms',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
