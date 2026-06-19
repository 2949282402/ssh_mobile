part of '../system_admin_screen.dart';

class _MetricChart extends StatelessWidget {
  static const int _maxChartPointsPerSeries = 140;

  final String metricKey;
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
    required this.metricKey,
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
      final cachedSeries = _MetricChartSeriesCache.getOrCreate(
        connectionId: connection.id,
        metricKey: metricKey,
        visibleSamples: rawSamples,
        valueFor: valueFor,
        latestTextFor: latestTextFor,
        startTime: start,
      );
      if (cachedSeries.spots.isEmpty) continue;
      final color = _serverColor(i);
      if (cachedSeries.dynamicMax > dynamicMax) dynamicMax = cachedSeries.dynamicMax;
      if (cachedSeries.maxX > maxX) maxX = cachedSeries.maxX;

      series.add(
        LineChartBarData(
          spots: cachedSeries.spots,
          isCurved: false,
          barWidth: 2,
          color: color,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(show: false),
        ),
      );
      latestLabels.add(
        _LegendLabel(
          color: color,
          text: '${connection.name} ${cachedSeries.latestText}',
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

  Color _serverColor(int index) => _monitorSeriesColor(index);
}

class _ChartSeriesCacheKey {
  final String connectionId;
  final int sampleLength;
  final DateTime? firstTime;
  final DateTime? lastTime;
  final String metricKey;
  final DateTime startTime;

  _ChartSeriesCacheKey({
    required this.connectionId,
    required this.sampleLength,
    required this.firstTime,
    required this.lastTime,
    required this.metricKey,
    required this.startTime,
  });

  @override
  bool operator ==(Object other) {
    return other is _ChartSeriesCacheKey &&
        other.connectionId == connectionId &&
        other.sampleLength == sampleLength &&
        other.firstTime == firstTime &&
        other.lastTime == lastTime &&
        other.metricKey == metricKey &&
        other.startTime == startTime;
  }

  @override
  int get hashCode => Object.hash(
        connectionId,
        sampleLength,
        firstTime,
        lastTime,
        metricKey,
        startTime,
      );
}

class _CachedChartSeries {
  final List<FlSpot> spots;
  final double maxX;
  final double dynamicMax;
  final String latestText;

  const _CachedChartSeries({
    required this.spots,
    required this.maxX,
    required this.dynamicMax,
    required this.latestText,
  });
}

class _MetricChartSeriesCache {
  static final Map<_ChartSeriesCacheKey, _CachedChartSeries> _cache = {};

  static _CachedChartSeries getOrCreate({
    required String connectionId,
    required String metricKey,
    required List<PerformanceSample> visibleSamples,
    required double Function(PerformanceSample) valueFor,
    required String Function(PerformanceSample) latestTextFor,
    required DateTime startTime,
  }) {
    final key = _ChartSeriesCacheKey(
      connectionId: connectionId,
      sampleLength: visibleSamples.length,
      firstTime: visibleSamples.isEmpty ? null : visibleSamples.first.time,
      lastTime: visibleSamples.isEmpty ? null : visibleSamples.last.time,
      metricKey: metricKey,
      startTime: startTime,
    );

    if (_cache.containsKey(key)) {
      return _cache[key]!;
    }

    if (visibleSamples.isEmpty) {
      const emptySeries = _CachedChartSeries(
        spots: [],
        maxX: 10.0,
        dynamicMax: 1.0,
        latestText: '',
      );
      _cache[key] = emptySeries;
      return emptySeries;
    }

    final thinned = _thinSamples(visibleSamples);
    final spots = List<FlSpot>.unmodifiable([
      for (final sample in thinned)
        FlSpot(
          sample.time.difference(startTime).inMilliseconds / 1000,
          valueFor(sample),
        ),
    ]);

    var dynamicMax = 1.0;
    var maxX = 10.0;
    for (final spot in spots) {
      if (spot.y > dynamicMax) dynamicMax = spot.y;
      if (spot.x > maxX) maxX = spot.x;
    }

    final latest = visibleSamples.last;
    final latestText = latestTextFor(latest);

    final cached = _CachedChartSeries(
      spots: spots,
      maxX: maxX,
      dynamicMax: dynamicMax,
      latestText: latestText,
    );

    _cache[key] = cached;
    if (_cache.length > 256) {
      _cache.remove(_cache.keys.first);
    }
    return cached;
  }

  static List<PerformanceSample> _thinSamples(List<PerformanceSample> samples) {
    if (samples.length <= _MetricChart._maxChartPointsPerSeries) return samples;
    final step = (samples.length / (_MetricChart._maxChartPointsPerSeries - 1)).ceil();
    final thinned = <PerformanceSample>[];
    for (var index = 0; index < samples.length; index += step) {
      thinned.add(samples[index]);
    }
    final last = samples.last;
    if (thinned.isEmpty || !identical(thinned.last, last)) thinned.add(last);
    return thinned;
  }
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
