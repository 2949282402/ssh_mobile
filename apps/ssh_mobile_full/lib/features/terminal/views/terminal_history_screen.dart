import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:ssh_mobile/features/terminal/viewmodels/terminal_history_viewmodel.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/tool_secret_policy.dart';
import 'package:ssh_mobile/theme/app_theme.dart';
import 'package:ssh_mobile/widgets/app_surface.dart';
import 'package:ssh_mobile/widgets/overflow_scroll_text.dart';

const _historySecretPolicy = ToolSecretPolicy();

class TerminalHistoryScreen extends StatelessWidget {
  const TerminalHistoryScreen({super.key, this.viewModel});

  final TerminalHistoryViewModel? viewModel;

  @override
  Widget build(BuildContext context) {
    final page = const TerminalHistoryPage();
    final suppliedViewModel = viewModel;

    if (suppliedViewModel != null) {
      return ChangeNotifierProvider<TerminalHistoryViewModel>.value(
        value: suppliedViewModel,
        child: page,
      );
    }

    return ChangeNotifierProvider<TerminalHistoryViewModel>(
      create: (context) =>
          TerminalHistoryViewModel(sshService: context.read<SshService>()),
      child: page,
    );
  }
}

class TerminalHistoryPage extends StatelessWidget {
  const TerminalHistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AppStrings(language);
    final viewModel = context.watch<TerminalHistoryViewModel>();

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const ValueKey('terminal-history-back'),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Text(strings.connectionHistory),
        actions: [
          IconButton(
            key: const ValueKey('terminal-history-refresh'),
            tooltip: strings.refresh,
            icon: const Icon(Icons.refresh_rounded),
            onPressed: viewModel.reload,
          ),
        ],
      ),
      body: AppPageSurface(
        child: SafeArea(
          top: false,
          child: FutureBuilder<List<TerminalHistoryRecord>>(
            future: viewModel.recordsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return _HistoryLoading(strings: strings);
              }
              if (snapshot.hasError) {
                return _HistoryStateView(
                  key: const ValueKey('terminal-history-error'),
                  icon: Icons.cloud_off_rounded,
                  title: strings.connectionHistoryLoadFailed,
                  message: strings.connectionHistoryLoadFailedHint,
                  action: FilledButton.icon(
                    key: const ValueKey('terminal-history-retry'),
                    onPressed: viewModel.reload,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(strings.retry),
                  ),
                );
              }

              final records = snapshot.data ?? const [];
              if (records.isEmpty) {
                return _HistoryStateView(
                  key: const ValueKey('terminal-history-empty'),
                  icon: Icons.history_toggle_off_rounded,
                  title: strings.noConnectionHistory,
                  message: strings.noConnectionHistoryHint,
                  action: OutlinedButton.icon(
                    key: const ValueKey('terminal-history-empty-refresh'),
                    onPressed: viewModel.reload,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(strings.refresh),
                  ),
                );
              }

              return _HistoryList(
                records: records,
                strings: strings,
                viewModel: viewModel,
              );
            },
          ),
        ),
      ),
    );
  }
}

class _HistoryLoading extends StatelessWidget {
  const _HistoryLoading({required this.strings});

  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Semantics(
              key: const ValueKey('terminal-history-loading'),
              container: true,
              liveRegion: true,
              label: strings.loadingConnectionHistory,
              child: ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.all(AppTheme.pagePadding),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        strings.loadingConnectionHistory,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryStateView extends StatelessWidget {
  const _HistoryStateView({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    required this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: AppEmptyState(
            icon: icon,
            title: title,
            message: message,
            action: action,
          ),
        ),
      ),
    );
  }
}

class _HistoryList extends StatelessWidget {
  const _HistoryList({
    required this.records,
    required this.strings,
    required this.viewModel,
  });

  final List<TerminalHistoryRecord> records;
  final AppStrings strings;
  final TerminalHistoryViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth < 600 || constraints.maxHeight < 480;
        final horizontalPadding = compact
            ? AppTheme.compactPagePadding
            : AppTheme.pagePadding;

        return ListView.separated(
          key: const ValueKey('terminal-history-scroll'),
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            compact ? 12 : 20,
            horizontalPadding,
            28,
          ),
          itemCount: records.length + 1,
          separatorBuilder: (context, index) =>
              SizedBox(height: index == 0 ? 16 : 12),
          itemBuilder: (context, index) {
            final child = index == 0
                ? _HistoryOverview(
                    recordCount: records.length,
                    strings: strings,
                  )
                : _HistoryItem(
                    record: records[index - 1],
                    strings: strings,
                    viewModel: viewModel,
                  );

            return Center(
              child: ConstrainedBox(
                key: index == 0
                    ? const ValueKey('terminal-history-content')
                    : null,
                constraints: const BoxConstraints(maxWidth: 820),
                child: child,
              ),
            );
          },
        );
      },
    );
  }
}

class _HistoryOverview extends StatelessWidget {
  const _HistoryOverview({required this.recordCount, required this.strings});

  final int recordCount;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final title = strings.connectionHistoryCount(recordCount);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const ExcludeSemantics(
              child: AppIconBadge(
                icon: Icons.history_rounded,
                size: 46,
                iconSize: 23,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    key: const ValueKey('terminal-history-overview-title'),
                    header: true,
                    child: Text(title, style: theme.textTheme.titleLarge),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    strings.connectionHistoryHint,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                      height: 1.45,
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
}

class _HistoryItem extends StatelessWidget {
  const _HistoryItem({
    required this.record,
    required this.strings,
    required this.viewModel,
  });

  final TerminalHistoryRecord record;
  final AppStrings strings;
  final TerminalHistoryViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final statusColor = _statusColor(context);
    final statusLabel = _statusLabel();
    final command = record.tmuxKillCommand;
    final rawErrorMessage = record.errorMessage;
    final errorMessage = rawErrorMessage == null
        ? null
        : _historySecretPolicy.previewText(rawErrorMessage, maxChars: 480);
    final isDeleting = viewModel.isDeleting(record.sessionId);

    return Semantics(
      container: true,
      child: Card(
        key: ValueKey('terminal-history-record-${record.sessionId}'),
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(
                    child: AppIconBadge(
                      icon: Icons.terminal_rounded,
                      size: 44,
                      iconSize: 22,
                      color: statusColor,
                    ),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        record.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    key: ValueKey(
                      'terminal-history-delete-${record.sessionId}',
                    ),
                    tooltip: strings.deleteHistoryRecord,
                    color: colors.error,
                    icon: isDeleting
                        ? SizedBox(
                            key: ValueKey(
                              'terminal-history-delete-progress-${record.sessionId}',
                            ),
                            width: 20,
                            height: 20,
                            child: const CircularProgressIndicator(
                              strokeWidth: 2.2,
                            ),
                          )
                        : const Icon(Icons.delete_outline_rounded),
                    onPressed: isDeleting ? null : () => _deleteRecord(context),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: _StatusPill(
                  icon: _statusIcon(),
                  label: statusLabel,
                  color: statusColor,
                ),
              ),
              const SizedBox(height: 12),
              _HistoryMetadataRow(
                icon: Icons.dns_outlined,
                text: record.connectionName,
              ),
              const SizedBox(height: 8),
              _HistoryMetadataRow(
                icon: Icons.schedule_rounded,
                text: strings.historyUpdatedAt(_formatTime(record.updatedAt)),
              ),
              if (errorMessage != null && errorMessage.isNotEmpty) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colors.errorContainer.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                    border: Border.all(
                      color: colors.error.withValues(alpha: 0.24),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ExcludeSemantics(
                        child: Icon(
                          Icons.error_outline_rounded,
                          size: 19,
                          color: colors.onErrorContainer,
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: SelectableText(
                          errorMessage,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onErrorContainer,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (command != null) ...[
                const SizedBox(height: 14),
                Tooltip(
                  message: strings.copyCommand,
                  child: Semantics(
                    key: ValueKey('terminal-history-copy-${record.sessionId}'),
                    container: true,
                    button: true,
                    label: '${strings.copyCommand}: $command',
                    onTap: () => _copyCommand(context, command),
                    child: ExcludeSemantics(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(
                          AppTheme.radiusSmall,
                        ),
                        onTap: () => _copyCommand(context, command),
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 56),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerHighest.withValues(
                              alpha: 0.72,
                            ),
                            borderRadius: BorderRadius.circular(
                              AppTheme.radiusSmall,
                            ),
                            border: Border.all(color: colors.outlineVariant),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                strings.staleTmuxHint,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colors.onSurfaceVariant,
                                  height: 1.35,
                                ),
                              ),
                              const SizedBox(height: 7),
                              Row(
                                children: [
                                  Icon(
                                    Icons.content_copy_rounded,
                                    size: 17,
                                    color: colors.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: OverflowScrollText(
                                      command,
                                      selectable: false,
                                      maxLines: 1,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            fontFamily: 'monospace',
                                            fontFamilyFallback: const [
                                              'Consolas',
                                              'Microsoft YaHei',
                                              'PingFang SC',
                                              'sans-serif',
                                            ],
                                            color: colors.onSurface,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _statusLabel() {
    switch (record.state.toLowerCase()) {
      case 'connected':
        return strings.connected;
      case 'connecting':
        return strings.connecting;
      case 'error':
        return strings.connectionError;
      case 'disconnected':
      default:
        return strings.disconnected;
    }
  }

  IconData _statusIcon() {
    switch (record.state.toLowerCase()) {
      case 'connected':
        return Icons.check_circle_outline_rounded;
      case 'connecting':
        return Icons.sync_rounded;
      case 'error':
        return Icons.error_outline_rounded;
      case 'disconnected':
      default:
        return Icons.link_off_rounded;
    }
  }

  Color _statusColor(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final extended = theme.extension<ExtendedColors>();
    final state = record.state.toLowerCase();
    final base = switch (state) {
      'connected' => extended?.success ?? colors.primary,
      'connecting' => extended?.warning ?? AppTheme.terminalAmber,
      'error' => colors.error,
      _ => colors.onSurfaceVariant,
    };

    if (theme.brightness == Brightness.light &&
        (state == 'connected' || state == 'connecting')) {
      return Color.lerp(base, Colors.black, 0.24)!;
    }
    return base;
  }

  Future<void> _copyCommand(BuildContext context, String command) async {
    try {
      await viewModel.copyCleanupCommand(command);
      if (!context.mounted) return;
      _showSnackBar(context, strings.copiedCleanupCommand);
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        'Failed to copy a terminal history cleanup command',
        error: error,
        stackTrace: stackTrace,
      );
      if (!context.mounted) return;
      _showSnackBar(context, strings.copyCleanupCommandFailed);
    }
  }

  Future<void> _deleteRecord(BuildContext context) async {
    try {
      await viewModel.deleteRecord(record.sessionId);
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        'Failed to delete a terminal history record',
        error: error,
        stackTrace: stackTrace,
      );
      if (!context.mounted) return;
      _showSnackBar(context, strings.deleteHistoryRecordFailed);
    }
  }

  void _showSnackBar(BuildContext context, String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(child: Icon(icon, size: 16, color: color)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryMetadataRow extends StatelessWidget {
  const _HistoryMetadataRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(child: Icon(icon, size: 18, color: color)),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
