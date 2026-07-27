import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/app_log_service.dart';
import '../../../services/mcp/mcp_server_controller.dart';
import '../../../services/native_memory_service.dart';
import '../../../services/performance_monitor_service.dart';
import '../../../services/rag_service.dart';
import '../../../services/ssh_service.dart';
import '../viewmodels/developer_panel_viewmodel.dart';

class DeveloperPanelScreen extends StatefulWidget {
  const DeveloperPanelScreen({super.key});

  @override
  State<DeveloperPanelScreen> createState() => _DeveloperPanelScreenState();
}

class _DeveloperPanelScreenState extends State<DeveloperPanelScreen> {
  late final DeveloperPanelViewModel _vm;

  @override
  void initState() {
    super.initState();
    _vm = DeveloperPanelViewModel()..start();
  }

  @override
  void dispose() {
    _vm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<DeveloperPanelViewModel>.value(
      value: _vm,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Developer Panel'),
          centerTitle: false,
        ),
        body: DeveloperPanelContent(vm: _vm),
      ),
    );
  }
}

/// Reusable developer panel body (FPS / memory / frame stats / build info).
///
/// Used by both the full-screen [DeveloperPanelScreen] and the floating
/// developer panel overlay so the same diagnostics are shown in both places.
class DeveloperPanelContent extends StatelessWidget {
  final DeveloperPanelViewModel vm;

  const DeveloperPanelContent({super.key, required this.vm});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: vm,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildFpsCard(context),
            const SizedBox(height: 12),
            _buildMemoryCard(context),
            const SizedBox(height: 12),
            _buildFrameCard(context),
            const SizedBox(height: 12),
            _buildComponentCard(context),
            const SizedBox(height: 12),
            _buildInfoCard(context),
          ],
        );
      },
    );
  }

  /// Reads a service from the widget tree without throwing if it is not
  /// provided (e.g. in the isolated floating-panel test). Returns null so the
  /// component card can render "n/a" gracefully.
  T? _safeRead<T>(BuildContext context) {
    try {
      return Provider.of<T>(context, listen: false);
    } on Object {
      return null;
    }
  }

  // ── FPS Card ──

  Widget _buildFpsCard(BuildContext context) {
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
                _metricColumn(context, 'Uptime', uptimeText),
                const SizedBox(width: 24),
                _metricColumn(context, 'Jank Frames', '${vm.jankCount}'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Memory Card ──

  Widget _buildMemoryCard(BuildContext context) {
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

  Widget _buildMemoryBreakdown(BuildContext context, NativeMemorySnapshot m) {
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

  // ── Frame Stats Card ──

  Widget _buildFrameCard(BuildContext context) {
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
                  child: _metricColumn(
                    context,
                    'Total Frames',
                    '${vm.frameCount}',
                  ),
                ),
                Flexible(
                  flex: 1,
                  child: _metricColumn(context, 'Jank Rate', '$jankRatio%'),
                ),
                Flexible(
                  flex: 1,
                  child: _metricColumn(
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
                  child: _metricColumn(
                    context,
                    'UI Build',
                    '${vm.avgBuildMs.toStringAsFixed(1)} ms',
                  ),
                ),
                Flexible(
                  flex: 1,
                  child: _metricColumn(
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

  // ── Component Activity Card ──

  Widget _buildComponentCard(BuildContext context) {
    final ssh = _safeRead<SshService>(context);
    final rag = _safeRead<RagService>(context);
    final mcp = _safeRead<McpServerController>(context);
    final perf = _safeRead<PerformanceMonitorService>(context);
    final logs = _safeRead<AppLogService>(context);

    final List<(String, String)> rows = [
      (
        'SSH',
        ssh == null
            ? 'n/a'
            : '${ssh.sessions.length} session'
                  '${ssh.sessions.length == 1 ? '' : 's'}'
                  '${ssh.isConnected ? ' · connected' : ''}',
      ),
      (
        'RAG',
        rag == null
            ? 'n/a'
            : rag.isLoading
            ? 'indexing…'
            : rag.isInitialized
            ? 'index loaded'
            : 'idle',
      ),
      (
        'MCP Server',
        mcp == null
            ? 'n/a'
            : mcp.running
            ? 'running'
            : 'stopped',
      ),
      (
        'Perf Monitor',
        perf == null
            ? 'n/a'
            : perf.isSampling
            ? 'sampling'
            : perf.isRunning
            ? 'running'
            : 'idle',
      ),
      ('Log Buffer', logs == null ? 'n/a' : '${logs.entries.length} entries'),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.layers_rounded, size: 20),
                SizedBox(width: 8),
                Text(
                  'Component Activity',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Live module state (activity proxy, not exact bytes). '
              'Use to spot which module is holding memory.',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 96,
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        value,
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── Info Card ──

  Widget _buildInfoCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 20),
                SizedBox(width: 8),
                Text(
                  'Build & Platform',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _infoRow(context, 'Build Mode', vm.buildMode),
            _infoRow(context, 'Platform', vm.platformName),
            _infoRow(context, 'Dart', vm.dartVersion),
            if (vm.flutterVersion != '—')
              _infoRow(context, 'Flutter', vm.flutterVersion),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricColumn(BuildContext context, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }
}
