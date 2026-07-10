import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import 'package:ssh_mobile/features/developer_log/viewmodels/developer_log_viewmodel.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/theme/app_theme.dart';
import 'package:ssh_mobile/widgets/app_surface.dart';
import 'package:ssh_mobile/widgets/overflow_scroll_text.dart';

extension _DeveloperLogStrings on AppStrings {
  String get copySelectedLogs =>
      language == AppLanguage.en ? 'Copy selected logs' : '复制选中日志';
  String get deleteSelectedLogs =>
      language == AppLanguage.en ? 'Delete selected logs' : '删除选中日志';
  String selectedLogs(int count) =>
      language == AppLanguage.en ? '$count logs selected' : '已选择 $count 条日志';
  String selectedLogsDeleted(int count) =>
      language == AppLanguage.en ? '$count logs deleted' : '已删除 $count 条日志';
}

class DeveloperLogPage extends StatefulWidget {
  const DeveloperLogPage({super.key});

  @override
  State<DeveloperLogPage> createState() => _DeveloperLogPageState();
}

class _DeveloperLogPageState extends State<DeveloperLogPage> {
  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<DeveloperLogViewModel>();
    final strings = AppStrings(viewModel.language);

    return Column(
      children: [
        _DeveloperLogToolbar(
          strings: strings,
          viewModel: viewModel,
          onCopySuccess: () {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(strings.copiedFilteredLogs)));
          },
          onDeleteSuccess: (count) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(strings.selectedLogsDeleted(count))),
            );
          },
          onClearSuccess: () {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(strings.logsCleared)));
          },
        ),
        Expanded(
          child: _DeveloperLogList(
            strings: strings,
            viewModel: viewModel,
            onCopySingleSuccess: () {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(strings.copiedSingleLog)));
            },
          ),
        ),
      ],
    );
  }
}

class _DeveloperLogToolbar extends StatelessWidget {
  final AppStrings strings;
  final DeveloperLogViewModel viewModel;
  final VoidCallback onCopySuccess;
  final ValueChanged<int> onDeleteSuccess;
  final VoidCallback onClearSuccess;

  const _DeveloperLogToolbar({
    required this.strings,
    required this.viewModel,
    required this.onCopySuccess,
    required this.onDeleteSuccess,
    required this.onClearSuccess,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.88),
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outline.withValues(alpha: 0.72),
          ),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  viewModel.selectionMode
                      ? strings.selectedLogs(viewModel.selectedIds.length)
                      : strings.developerLogs,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
              if (viewModel.selectionMode)
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: strings.cancel,
                  onPressed: viewModel.clearSelection,
                ),
              IconButton(
                icon: Icon(
                  viewModel.selectionMode
                      ? Icons.copy_rounded
                      : Icons.copy_all_rounded,
                ),
                tooltip: viewModel.selectionMode
                    ? strings.copySelectedLogs
                    : strings.copyFilteredLogs,
                onPressed: () async {
                  final success = await viewModel.copySelectedOrFilteredLogs();
                  if (success) onCopySuccess();
                },
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded),
                tooltip: viewModel.selectionMode
                    ? strings.deleteSelectedLogs
                    : strings.clearLogs,
                onPressed: () {
                  if (viewModel.selectionMode) {
                    final count = viewModel.deleteSelectedLogs();
                    onDeleteSuccess(count);
                  } else {
                    viewModel.clearLogs();
                    onClearSuccess();
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          Builder(
            builder: (context) {
              final textScale = MediaQuery.textScalerOf(
                context,
              ).scale(1).clamp(1.0, 1.6).toDouble();
              return SizedBox(
                height: 36 + (textScale - 1.0) * 18,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: AppLogLevel.values.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final level = AppLogLevel.values[index];
                    final count = viewModel.levelCounts[level] ?? 0;
                    return FilterChip(
                      label: Text('${level.labelFor(strings.language)} $count'),
                      selected: viewModel.selectedLevel == level,
                      onSelected: (_) => viewModel.setSelectedLevel(level),
                    );
                  },
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _DeveloperLogList extends StatelessWidget {
  final AppStrings strings;
  final DeveloperLogViewModel viewModel;
  final VoidCallback onCopySingleSuccess;

  const _DeveloperLogList({
    required this.strings,
    required this.viewModel,
    required this.onCopySingleSuccess,
  });

  @override
  Widget build(BuildContext context) {
    if (!viewModel.hasEntries) {
      return AppEmptyState(
        icon: Icons.article_outlined,
        title: strings.developerLogs,
        message: strings.noLogs,
      );
    }
    final entries = viewModel.filteredEntries;
    if (entries.isEmpty) {
      return AppEmptyState(
        icon: Icons.filter_alt_off_outlined,
        title: strings.developerLogs,
        message: strings.noLogsForLevel,
      );
    }
    return ListView.separated(
      scrollCacheExtent: const ScrollCacheExtent.pixels(900.0),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final entry = entries[index];
        return RepaintBoundary(
          key: ValueKey('${entry.time.microsecondsSinceEpoch}-${entry.level}'),
          child: _LogEntryTile(
            entry: entry,
            strings: strings,
            selected: viewModel.selectedIds.contains(entry.id),
            selectionMode: viewModel.selectionMode,
            onTap: () => viewModel.toggleEntrySelection(entry),
            onLongPress: () => viewModel.selectEntry(entry),
            viewModel: viewModel,
            onCopySingleSuccess: onCopySingleSuccess,
          ),
        );
      },
    );
  }
}

class _LogEntryTile extends StatefulWidget {
  final AppLogEntry entry;
  final AppStrings strings;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final DeveloperLogViewModel viewModel;
  final VoidCallback onCopySingleSuccess;

  const _LogEntryTile({
    required this.entry,
    required this.strings,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
    required this.viewModel,
    required this.onCopySingleSuccess,
  });

  @override
  State<_LogEntryTile> createState() => _LogEntryTileState();
}

class _LogEntryTileState extends State<_LogEntryTile> {
  static const int _collapsedLines = 5;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final strings = widget.strings;
    final colorScheme = Theme.of(context).colorScheme;
    final level = entry.normalizedLevel;
    final levelColor = _levelColor(context, level);
    final isLong = _isLong(entry.text);

    return InkWell(
      borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
      onTap: widget.selectionMode
          ? widget.onTap
          : isLong
          ? () => setState(() => _expanded = !_expanded)
          : null,
      onLongPress: widget.onLongPress,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colorScheme.surface.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          border: Border.all(
            color: widget.selected
                ? colorScheme.primary
                : colorScheme.outline.withValues(alpha: 0.76),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.025),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (widget.selectionMode) ...[
                  Icon(
                    widget.selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: widget.selected
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                ],
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: levelColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: levelColor.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Text(
                    level.labelFor(strings.language),
                    style: TextStyle(
                      color: levelColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const Spacer(),
                if (!widget.selectionMode)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    tooltip: strings.copySingleLog,
                    onPressed: () async {
                      await widget.viewModel.copySingleLog(entry.text);
                      widget.onCopySingleSuccess();
                    },
                    icon: const Icon(Icons.copy_rounded),
                  ),
                if (isLong)
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 22,
                    color: colorScheme.onSurface.withValues(alpha: 0.58),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            OverflowScrollText(
              entry.text,
              maxLines: _expanded ? null : _collapsedLines,
              style: TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: [
                  'Consolas',
                  'Microsoft YaHei',
                  'PingFang SC',
                  'sans-serif',
                ],
                fontSize: 11,
                height: 1.35,
                color: colorScheme.onSurface,
              ),
            ),
            if (isLong && !_expanded) ...[
              const SizedBox(height: 6),
              Text(
                strings.expandFullLog,
                style: TextStyle(
                  color: colorScheme.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  bool _isLong(String text) {
    return text.length > 360 || '\n'.allMatches(text).length >= _collapsedLines;
  }

  Color _levelColor(BuildContext context, AppLogLevel level) {
    final colorScheme = Theme.of(context).colorScheme;
    switch (level) {
      case AppLogLevel.error:
      case AppLogLevel.flutter:
      case AppLogLevel.platform:
        return colorScheme.error;
      case AppLogLevel.warning:
        return Colors.orange;
      case AppLogLevel.service:
        return colorScheme.secondary;
      case AppLogLevel.debug:
        return Colors.blueGrey;
      case AppLogLevel.app:
        return colorScheme.primary;
      case AppLogLevel.info:
      case AppLogLevel.all:
        return Colors.blue;
    }
  }
}
