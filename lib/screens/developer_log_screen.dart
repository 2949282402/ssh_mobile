import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/app_log_service.dart';
import '../services/app_settings.dart';

class DeveloperLogPage extends StatefulWidget {
  const DeveloperLogPage({super.key});

  @override
  State<DeveloperLogPage> createState() => _DeveloperLogPageState();
}

class _DeveloperLogPageState extends State<DeveloperLogPage> {
  AppLogLevel _selectedLevel = AppLogLevel.all;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings(context.watch<AppSettings>().language);
    final logService = context.watch<AppLogService>();
    final allEntries = logService.entries;
    final entries = _selectedLevel == AppLogLevel.all
        ? allEntries
        : allEntries
            .where((entry) => entry.normalizedLevel == _selectedLevel)
            .toList();
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        Container(
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
                      strings.developerLogs,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy_all_rounded),
                    tooltip: strings.copyFilteredLogs,
                    onPressed: entries.isEmpty
                        ? null
                        : () => _copyEntries(context, entries, strings),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline_rounded),
                    tooltip: strings.clearLogs,
                    onPressed: allEntries.isEmpty
                        ? null
                        : () => _clearLogs(context, logService, strings),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 36,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: AppLogLevel.values.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final level = AppLogLevel.values[index];
                    final count = level == AppLogLevel.all
                        ? allEntries.length
                        : allEntries
                            .where((entry) => entry.normalizedLevel == level)
                            .length;
                    return FilterChip(
                      label: Text('${level.labelFor(strings.language)} $count'),
                      selected: _selectedLevel == level,
                      onSelected: (_) => setState(() {
                        _selectedLevel = level;
                      }),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: allEntries.isEmpty
              ? Center(child: Text(strings.noLogs))
              : entries.isEmpty
                  ? Center(child: Text(strings.noLogsForLevel))
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                      itemCount: entries.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        return _LogEntryTile(
                          entry: entries[index],
                          strings: strings,
                        );
                      },
                    ),
        ),
      ],
    );
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

  void _clearLogs(
    BuildContext context,
    AppLogService logService,
    AppStrings strings,
  ) {
    FocusManager.instance.primaryFocus?.unfocus();
    logService.clear();
    setState(() => _selectedLevel = AppLogLevel.all);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(strings.logsCleared)),
    );
  }
}

class _LogEntryTile extends StatefulWidget {
  final AppLogEntry entry;
  final AppStrings strings;

  const _LogEntryTile({
    required this.entry,
    required this.strings,
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
      onTap: isLong ? () => setState(() => _expanded = !_expanded) : null,
      onLongPress: () => _copySingle(context, entry.text, strings),
      child: Container(
        padding: const EdgeInsets.all(10),
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
            SelectableText(
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
