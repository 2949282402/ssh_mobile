import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/app_settings.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';

class TerminalHistoryScreen extends StatelessWidget {
  const TerminalHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: SafeArea(child: TerminalHistoryPage()));
  }
}

class TerminalHistoryPage extends StatefulWidget {
  const TerminalHistoryPage({super.key});

  @override
  State<TerminalHistoryPage> createState() => _TerminalHistoryPageState();
}

class _TerminalHistoryPageState extends State<TerminalHistoryPage> {
  late Future<List<TerminalHistoryRecord>> _recordsFuture;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _recordsFuture = context.read<SshService>().loadTerminalHistoryRecords();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final strings = AppStrings(context.watch<AppSettings>().language);
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            border: Border(
              bottom: BorderSide(color: colorScheme.outlineVariant),
            ),
          ),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () => Navigator.maybePop(context),
              ),
              Expanded(
                child: Text(
                  strings.connectionHistory,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh_rounded),
                onPressed: () => setState(_reload),
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<TerminalHistoryRecord>>(
            future: _recordsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }

              final records = snapshot.data ?? const [];
              if (records.isEmpty) {
                return Center(child: Text(strings.noConnectionHistory));
              }

              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                itemCount: records.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) => _HistoryItem(
                  record: records[index],
                  strings: strings,
                  onDeleted: () => setState(_reload),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _HistoryItem extends StatelessWidget {
  final TerminalHistoryRecord record;
  final AppStrings strings;
  final VoidCallback onDeleted;

  const _HistoryItem({
    required this.record,
    required this.strings,
    required this.onDeleted,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final command = record.tmuxKillCommand;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  record.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colorScheme.onSurface,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded),
                tooltip: strings.deleteHistoryRecord,
                onPressed: () => _deleteRecord(context),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${record.connectionName} · ${record.state}',
            style: TextStyle(
              color: colorScheme.onSurface.withValues(alpha: 0.62),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _formatTime(record.updatedAt),
            style: TextStyle(
              color: colorScheme.onSurface.withValues(alpha: 0.52),
              fontSize: 12,
            ),
          ),
          if (record.errorMessage?.isNotEmpty == true) ...[
            const SizedBox(height: 8),
            Text(
              record.errorMessage!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colorScheme.error, fontSize: 12),
            ),
          ],
          if (command != null) ...[
            const SizedBox(height: 10),
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => _copyCommand(context, command),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: colorScheme.outlineVariant),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.content_copy_rounded,
                      size: 14,
                      color: colorScheme.onSurface.withValues(alpha: 0.62),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        command,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: colorScheme.onSurface.withValues(alpha: 0.78),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _copyCommand(BuildContext context, String command) async {
    await Clipboard.setData(ClipboardData(text: command));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(strings.copiedCleanupCommand)),
    );
  }

  Future<void> _deleteRecord(BuildContext context) async {
    await context.read<SshService>().removeTerminalHistoryRecord(
          record.sessionId,
        );
    onDeleted();
  }

  String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}
