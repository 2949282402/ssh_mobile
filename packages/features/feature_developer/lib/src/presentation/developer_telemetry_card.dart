import 'package:flutter/material.dart';

import '../domain/developer_diagnostics_models.dart';
import 'developer_panel_viewmodel.dart';

/// Card showing Telemetry local database stats, policy, and manual replay actions.
final class DeveloperTelemetryCard extends StatefulWidget {
  const DeveloperTelemetryCard({
    super.key,
    required this.telemetry,
    required this.vm,
  });

  final DeveloperTelemetrySnapshot? telemetry;
  final DeveloperPanelViewModel vm;

  @override
  State<DeveloperTelemetryCard> createState() => _DeveloperTelemetryCardState();
}

class _DeveloperTelemetryCardState extends State<DeveloperTelemetryCard> {
  bool _isProcessing = false;
  String? _actionFeedback;

  Future<void> _handleReplay() async {
    setState(() {
      _isProcessing = true;
      _actionFeedback = 'Replaying...';
    });
    try {
      final count = await widget.vm.replayTelemetry();
      if (mounted) {
        setState(() {
          _actionFeedback = 'Replayed $count records';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _actionFeedback = 'Error: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  Future<void> _handleFlush() async {
    setState(() {
      _isProcessing = true;
      _actionFeedback = 'Uploading...';
    });
    try {
      await widget.vm.flushTelemetry();
      if (mounted) {
        setState(() {
          _actionFeedback = 'Upload triggered';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _actionFeedback = 'Error: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  Future<void> _handleRefreshPolicy() async {
    setState(() {
      _isProcessing = true;
      _actionFeedback = 'Refreshing policy...';
    });
    try {
      final res = await widget.vm.refreshTelemetryPolicy();
      if (mounted) {
        setState(() {
          _actionFeedback = res ? 'Policy updated' : 'Policy fetch failed';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _actionFeedback = 'Error: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.telemetry;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.analytics_outlined, size: 20),
                SizedBox(width: 8),
                Text(
                  'Telemetry Diagnostics',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Local storage, upload policy and data replay.',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            if (t == null)
              Text(
                'Telemetry runtime not initialized.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              )
            else ...[
              if (t.cacheOverflow) ...[
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: scheme.onErrorContainer,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Cache Overflow: Non-loss invariant active. Backlog requires upload.',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: scheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
              _metricRow(context, 'Pending Records', '${t.localPendingCount}'),
              _metricRow(context, 'Synced Records', '${t.localSyncedCount}'),
              _metricRow(
                context,
                'Rejected Records',
                '${t.localRejectedCount}',
              ),
              _metricRow(context, 'Total Database Rows', '${t.totalCount}'),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Divider(height: 1),
              ),
              _metricRow(
                context,
                'Upload Policy',
                '${t.uploadEnabled ? "Enabled" : "Disabled"} (v${t.policyVersion})',
              ),
              _metricRow(
                context,
                'Batch / Interval',
                '${t.batchSizeThreshold} items / ${t.timeIntervalSeconds}s',
              ),
              _metricRow(
                context,
                'Status',
                t.isUploading ? 'Uploading...' : 'Idle',
              ),
              if (t.lastSyncError != null)
                _metricRow(
                  context,
                  'Last Error',
                  t.lastSyncError!,
                  isError: true,
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _isProcessing ? null : _handleReplay,
                    icon: const Icon(Icons.replay_rounded, size: 14),
                    label: const Text(
                      'Replay All Data',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _isProcessing ? null : _handleFlush,
                    icon: const Icon(Icons.cloud_upload_outlined, size: 14),
                    label: const Text(
                      'Upload Now',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _isProcessing ? null : _handleRefreshPolicy,
                    icon: const Icon(Icons.refresh_rounded, size: 14),
                    label: const Text(
                      'Refresh Policy',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
              if (_actionFeedback != null) ...[
                const SizedBox(height: 8),
                Text(
                  _actionFeedback!,
                  style: TextStyle(
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    color: scheme.primary,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _metricRow(
    BuildContext context,
    String label,
    String value, {
    bool isError = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
          Flexible(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: isError ? scheme.error : scheme.onSurface,
                fontWeight: isError ? FontWeight.w600 : FontWeight.normal,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }
}
