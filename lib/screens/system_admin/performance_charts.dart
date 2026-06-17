part of '../system_admin_screen.dart';

class _MetricChart extends StatelessWidget {
  static const int _maxChartPointsPerSeries = 140;

  final String title;
  final String unit;
  final List<ConnectionConfig> connections;
  final Map<String, List<PerformanceSample>> samplesByConnection;
  final double Function(PerformanceSample sample) valueFor;
  final String Function(PerformanceSample sample) latestTextFor;
  final double chartHeight;
  final double? maxY;
  final bool expanded;
  final VoidCallback onToggle;

  const _MetricChart({
    required this.title,
    required this.unit,
    required this.connections,
    required this.samplesByConnection,
    required this.chartHeight,
    required this.valueFor,
    required this.latestTextFor,
    required this.expanded,
    required this.onToggle,
    this.maxY,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final start = _oldestVisibleSampleTime();
    final series = <LineChartBarData>[];
    final latestLabels = <Widget>[];
    var dynamicMax = 1.0;
    var maxX = 10.0;

    for (var i = 0; i < connections.length; i++) {
      final connection = connections[i];
      final rawSamples =
          samplesByConnection[connection.id] ?? const <PerformanceSample>[];
      final samples = _thinSamples(rawSamples);
      if (samples.isEmpty) continue;
      final color = _serverColor(i);
      final spots = [
        for (final sample in samples)
          FlSpot(
            sample.time.difference(start).inMilliseconds / 1000,
            valueFor(sample),
          ),
      ];
      for (final spot in spots) {
        dynamicMax = max(dynamicMax, spot.y);
        maxX = max(maxX, spot.x);
      }
      series.add(
        LineChartBarData(
          spots: spots,
          isCurved: false,
          barWidth: 2,
          color: color,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(show: false),
        ),
      );
      final latest = rawSamples.last;
      latestLabels.add(
        _LegendLabel(
          color: color,
          text: '${connection.name} ${latestTextFor(latest)}',
        ),
      );
    }

    final chartMaxY = maxY ?? max(1, dynamicMax * 1.2);
    final leftInterval = max(1.0, chartMaxY / 4);
    final bottomInterval = max(10.0, maxX / 4);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                Text(
                  unit,
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 20,
                ),
              ],
            ),
          ),
          if (expanded) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 26,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: latestLabels.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) => latestLabels[index],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: chartHeight,
              child: RepaintBoundary(
                child: LineChart(
                  LineChartData(
                    minX: 0,
                    maxX: maxX,
                    minY: 0,
                    maxY: chartMaxY,
                    clipData: const FlClipData.all(),
                    lineTouchData: const LineTouchData(enabled: false),
                    gridData: FlGridData(
                      show: true,
                      drawVerticalLine: false,
                      getDrawingHorizontalLine: (_) => FlLine(
                        color:
                            colorScheme.outlineVariant.withValues(alpha: 0.5),
                        strokeWidth: 1,
                      ),
                    ),
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 36,
                          interval: leftInterval,
                          getTitlesWidget: (value, meta) => Text(
                            value >= 100
                                ? value.toStringAsFixed(0)
                                : value.toStringAsFixed(1),
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 20,
                          interval: bottomInterval,
                          getTitlesWidget: (value, meta) => Text(
                            '${value.round()}s',
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ),
                    ),
                    borderData: FlBorderData(
                      show: true,
                      border: Border.all(color: colorScheme.outlineVariant),
                    ),
                    lineBarsData: series,
                  ),
                  duration: Duration.zero,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  DateTime _oldestVisibleSampleTime() {
    DateTime? oldest;
    for (final connection in connections) {
      final samples =
          samplesByConnection[connection.id] ?? const <PerformanceSample>[];
      if (samples.isEmpty) continue;
      final first = samples.first.time;
      if (oldest == null || first.isBefore(oldest)) oldest = first;
    }
    return oldest ?? DateTime.now();
  }

  List<PerformanceSample> _thinSamples(List<PerformanceSample> samples) {
    if (samples.length <= _maxChartPointsPerSeries) return samples;
    final step = (samples.length / (_maxChartPointsPerSeries - 1)).ceil();
    final thinned = <PerformanceSample>[];
    for (var index = 0; index < samples.length; index += step) {
      thinned.add(samples[index]);
    }
    final last = samples.last;
    if (!identical(thinned.last, last)) thinned.add(last);
    return thinned;
  }

  Color _serverColor(int index) => _monitorSeriesColor(index);
}

class _MetricChartItem {
  final String key;
  final String title;
  final _MetricSpec spec;
  final List<ConnectionConfig> connections;

  const _MetricChartItem({
    required this.key,
    required this.title,
    required this.spec,
    required this.connections,
  });
}

class _LegendLabel extends StatelessWidget {
  final Color color;
  final String text;

  const _LegendLabel({
    required this.color,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(99),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _MetricSpec {
  final String key;
  final String title;
  final String unit;
  final double Function(PerformanceSample sample) valueFor;
  final String Function(PerformanceSample sample) latestTextFor;
  final double? maxY;

  const _MetricSpec({
    required this.key,
    required this.title,
    required this.unit,
    required this.valueFor,
    required this.latestTextFor,
    this.maxY,
  });
}
