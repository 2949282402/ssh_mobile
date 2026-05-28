import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/app_log_service.dart';
import '../services/app_settings.dart';
import '../widgets/overflow_scroll_text.dart';

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
  AppLogLevel _selectedLevel = AppLogLevel.all;
  final Set<int> _selectedIds = {};

  bool get _selectionMode => _selectedIds.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AppStrings(language);

    return Column(
      children: [
        if (_selectionMode)
          _SelectedLogPruner(
            selectedIds: _selectedIds,
            onPruned: () {
              if (mounted) setState(() {});
            },
          ),
        _DeveloperLogToolbar(
          strings: strings,
          selectedLevel: _selectedLevel,
          selectedIds: _selectedIds,
          onLevelChanged: (level) => setState(() => _selectedLevel = level),
          onClearSelection: () => setState(_selectedIds.clear),
          onCopyEntries: (entries) => _copyEntries(context, entries, strings),
          onDeleteSelected: () => _deleteSelectedLogs(
            context,
            context.read<AppLogService>(),
            strings,
          ),
          onClearLogs: () => _clearLogs(
            context,
            context.read<AppLogService>(),
            strings,
          ),
        ),
        Expanded(
          child: _DeveloperLogList(
            strings: strings,
            selectedLevel: _selectedLevel,
            selectedIds: _selectedIds,
            selectionMode: _selectionMode,
            onEntryTap: _handleEntryTap,
            onEntryLongPress: _selectEntry,
          ),
        ),
      ],
    );
  }

  void _handleEntryTap(AppLogEntry entry) {
    if (!_selectionMode) return;
    setState(() {
      if (!_selectedIds.add(entry.id)) {
        _selectedIds.remove(entry.id);
      }
    });
  }

  void _selectEntry(AppLogEntry entry) {
    setState(() => _selectedIds.add(entry.id));
  }

  Future<void> _copyEntries(
    BuildContext context,
    List<AppLogEntry> entries,
    AppStrings strings,
  ) async {
    await Clipboard.setData(
      ClipboardData(text: entries.reversed.map((e) => e.text).join('\n\n')),
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(strings.copiedFilteredLogs)),
    );
  }

  void _deleteSelectedLogs(
    BuildContext context,
    AppLogService logService,
    AppStrings strings,
  ) {
    final count = _selectedIds.length;
    logService.deleteEntriesById(_selectedIds);
    setState(_selectedIds.clear);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(strings.selectedLogsDeleted(count))),
    );
  }

  void _clearLogs(
    BuildContext context,
    AppLogService logService,
    AppStrings strings,
  ) {
    FocusManager.instance.primaryFocus?.unfocus();
    logService.clear();
    setState(() {
      _selectedLevel = AppLogLevel.all;
      _selectedIds.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(strings.logsCleared)),
    );
  }
}

class _SelectedLogPruner extends StatelessWidget {
  final Set<int> selectedIds;
  final VoidCallback onPruned;

  const _SelectedLogPruner({
    required this.selectedIds,
    required this.onPruned,
  });

  @override
  Widget build(BuildContext context) {
    final entryIds = context.select<AppLogService, Set<int>>(
      (service) => service.entryIds,
    );
    final staleIds = [
      for (final id in selectedIds)
        if (!entryIds.contains(id)) id,
    ];
    if (staleIds.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        selectedIds.removeAll(staleIds);
        onPruned();
      });
    }
    return const SizedBox.shrink();
  }
}

class _DeveloperLogToolbar extends StatelessWidget {
  final AppStrings strings;
  final AppLogLevel selectedLevel;
  final Set<int> selectedIds;
  final ValueChanged<AppLogLevel> onLevelChanged;
  final VoidCallback onClearSelection;
  final ValueChanged<List<AppLogEntry>> onCopyEntries;
  final VoidCallback onDeleteSelected;
  final VoidCallback onClearLogs;

  const _DeveloperLogToolbar({
    required this.strings,
    required this.selectedLevel,
    required this.selectedIds,
    required this.onLevelChanged,
    required this.onClearSelection,
    required this.onCopyEntries,
    required this.onDeleteSelected,
    required this.onClearLogs,
  });

  bool get _selectionMode => selectedIds.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final snapshot =
        context.select<AppLogService, _DeveloperLogToolbarSnapshot>(
      (service) => _DeveloperLogToolbarSnapshot.from(
        service,
        selectedLevel,
        selectedIds,
      ),
    );
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 10),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          bottom: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _selectionMode
                      ? strings.selectedLogs(selectedIds.length)
                      : strings.developerLogs,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (_selectionMode)
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: strings.cancel,
                  onPressed: onClearSelection,
                ),
              IconButton(
                icon: Icon(
                  _selectionMode ? Icons.copy_rounded : Icons.copy_all_rounded,
                ),
                tooltip: _selectionMode
                    ? strings.copySelectedLogs
                    : strings.copyFilteredLogs,
                onPressed: _selectionMode
                    ? snapshot.selectedEntries.isEmpty
                        ? null
                        : () => onCopyEntries(snapshot.selectedEntries)
                    : snapshot.filteredEntries.isEmpty
                        ? null
                        : () => onCopyEntries(snapshot.filteredEntries),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded),
                tooltip: _selectionMode
                    ? strings.deleteSelectedLogs
                    : strings.clearLogs,
                onPressed: _selectionMode
                    ? snapshot.selectedEntries.isEmpty
                        ? null
                        : onDeleteSelected
                    : snapshot.hasEntries
                        ? onClearLogs
                        : null,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Builder(
            builder: (context) {
              final textScale = MediaQuery.textScalerOf(context)
                  .scale(1)
                  .clamp(1.0, 1.6)
                  .toDouble();
              return SizedBox(
                height: 36 + (textScale - 1.0) * 18,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: AppLogLevel.values.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final level = AppLogLevel.values[index];
                    final count = snapshot.levelCounts[level] ?? 0;
                    return FilterChip(
                      label: Text('${level.labelFor(strings.language)} $count'),
                      selected: selectedLevel == level,
                      onSelected: (_) => onLevelChanged(level),
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
  final AppLogLevel selectedLevel;
  final Set<int> selectedIds;
  final bool selectionMode;
  final ValueChanged<AppLogEntry> onEntryTap;
  final ValueChanged<AppLogEntry> onEntryLongPress;

  const _DeveloperLogList({
    required this.strings,
    required this.selectedLevel,
    required this.selectedIds,
    required this.selectionMode,
    required this.onEntryTap,
    required this.onEntryLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final snapshot = context.select<AppLogService, _DeveloperLogListSnapshot>(
      (service) => _DeveloperLogListSnapshot.from(service, selectedLevel),
    );
    if (!snapshot.hasEntries) {
      return Center(child: Text(strings.noLogs));
    }
    final entries = snapshot.filteredEntries;
    if (entries.isEmpty) {
      return Center(child: Text(strings.noLogsForLevel));
    }
    return ListView.separated(
      cacheExtent: 900,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final entry = entries[index];
        return RepaintBoundary(
          key: ValueKey(
            '${entry.time.microsecondsSinceEpoch}-${entry.level}',
          ),
          child: _LogEntryTile(
            entry: entry,
            strings: strings,
            selected: selectedIds.contains(entry.id),
            selectionMode: selectionMode,
            onTap: () => onEntryTap(entry),
            onLongPress: () => onEntryLongPress(entry),
          ),
        );
      },
    );
  }
}

class _DeveloperLogToolbarSnapshot {
  final Map<AppLogLevel, int> levelCounts;
  final List<AppLogEntry> filteredEntries;
  final List<AppLogEntry> selectedEntries;
  final bool hasEntries;

  const _DeveloperLogToolbarSnapshot({
    required this.levelCounts,
    required this.filteredEntries,
    required this.selectedEntries,
    required this.hasEntries,
  });

  factory _DeveloperLogToolbarSnapshot.from(
    AppLogService service,
    AppLogLevel selectedLevel,
    Set<int> selectedIds,
  ) {
    final allEntries = service.entries;
    return _DeveloperLogToolbarSnapshot(
      levelCounts: service.levelCounts,
      filteredEntries: service.entriesForLevel(selectedLevel),
      selectedEntries: selectedIds.isEmpty
          ? const <AppLogEntry>[]
          : [
              for (final entry in allEntries)
                if (selectedIds.contains(entry.id)) entry,
            ],
      hasEntries: allEntries.isNotEmpty,
    );
  }
}

class _DeveloperLogListSnapshot {
  final List<AppLogEntry> filteredEntries;
  final bool hasEntries;

  const _DeveloperLogListSnapshot({
    required this.filteredEntries,
    required this.hasEntries,
  });

  factory _DeveloperLogListSnapshot.from(
    AppLogService service,
    AppLogLevel selectedLevel,
  ) {
    return _DeveloperLogListSnapshot(
      filteredEntries: service.entriesForLevel(selectedLevel),
      hasEntries: service.entries.isNotEmpty,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _DeveloperLogListSnapshot &&
        identical(other.filteredEntries, filteredEntries) &&
        other.hasEntries == hasEntries;
  }

  @override
  int get hashCode =>
      Object.hash(identityHashCode(filteredEntries), hasEntries);
}

class _LogEntryTile extends StatefulWidget {
  final AppLogEntry entry;
  final AppStrings strings;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _LogEntryTile({
    required this.entry,
    required this.strings,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
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
      borderRadius: BorderRadius.circular(8),
      onTap: widget.selectionMode
          ? widget.onTap
          : isLong
              ? () => setState(() => _expanded = !_expanded)
              : null,
      onLongPress: widget.onLongPress,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: widget.selected
                ? colorScheme.primary
                : colorScheme.outlineVariant,
          ),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: levelColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                    border:
                        Border.all(color: levelColor.withValues(alpha: 0.35)),
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
                    onPressed: () => _copySingle(context, entry.text, strings),
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

  Future<void> _copySingle(
    BuildContext context,
    String text,
    AppStrings strings,
  ) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(strings.copiedSingleLog)),
    );
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
