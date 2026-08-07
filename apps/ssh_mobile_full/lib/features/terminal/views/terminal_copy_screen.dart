import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:app_ui/app_ui.dart';

typedef TerminalClipboardWriter = Future<void> Function(String text);

class TerminalCopyScreen extends StatefulWidget {
  const TerminalCopyScreen({
    super.key,
    required this.title,
    required this.text,
    this.clipboardWriter,
    this.copyAllTooltip,
  });

  final String title;
  final String text;

  /// Overrides the platform clipboard in focused widget tests.
  final TerminalClipboardWriter? clipboardWriter;

  /// Kept for callers that previously supplied a localized tooltip.
  final String? copyAllTooltip;

  @override
  State<TerminalCopyScreen> createState() => _TerminalCopyScreenState();
}

class _TerminalCopyScreenState extends State<TerminalCopyScreen> {
  final ScrollController _scrollController = ScrollController();
  late final TextEditingController _textController;
  late final int _lineCount;
  late final int _characterCount;
  bool _copying = false;
  bool _closingAfterCopy = false;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.text);
    _lineCount = widget.text.isEmpty
        ? 0
        : '\n'.allMatches(widget.text).length + 1;
    _characterCount = widget.text.length;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (!mounted || !_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  Future<void> _copyAll(TerminalStrings strings) async {
    if (_copying || _closingAfterCopy) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    setState(() => _copying = true);

    try {
      final writer = widget.clipboardWriter;
      if (writer == null) {
        await Clipboard.setData(ClipboardData(text: widget.text));
      } else {
        await writer(widget.text);
      }
      if (!mounted) return;
      if (ModalRoute.of(context)?.isCurrent != true) {
        setState(() => _copying = false);
        return;
      }

      setState(() {
        _copying = false;
        _closingAfterCopy = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ModalRoute.of(context)?.isCurrent != true) {
          setState(() => _closingAfterCopy = false);
          return;
        }
        Navigator.of(context).pop(true);
      });
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        'Terminal output copy failed',
        stackTrace: stackTrace,
        details: 'Exception type: ${error.runtimeType}',
      );
      if (!mounted) return;

      setState(() => _copying = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(strings.copyTerminalOutputFailed),
            showCloseIcon: true,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = TerminalStrings(language);
    final copyAllLabel = widget.copyAllTooltip ?? strings.copyAll;
    final actionLocked = _copying || _closingAfterCopy;

    return PopScope(
      canPop: !_copying,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            key: const ValueKey('terminal-copy-close'),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            visualDensity: VisualDensity.standard,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: const Icon(Icons.close_rounded),
            onPressed: actionLocked ? null : () => Navigator.maybePop(context),
          ),
          title: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            Semantics(
              key: const ValueKey('terminal-copy-copy-all'),
              container: true,
              liveRegion: _copying,
              button: true,
              enabled: !actionLocked,
              label: actionLocked
                  ? strings.copyingTerminalOutput
                  : copyAllLabel,
              onTap: actionLocked ? null : () => _copyAll(strings),
              child: ExcludeSemantics(
                child: IconButton(
                  tooltip: actionLocked
                      ? strings.copyingTerminalOutput
                      : copyAllLabel,
                  visualDensity: VisualDensity.standard,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: actionLocked ? null : () => _copyAll(strings),
                  icon: actionLocked
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.2),
                        )
                      : const Icon(Icons.copy_all_rounded),
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: AppPageSurface(
          child: SafeArea(
            top: false,
            child: _TerminalCopyWorkspace(
              controller: _textController,
              scrollController: _scrollController,
              strings: strings,
              lineCount: _lineCount,
              characterCount: _characterCount,
            ),
          ),
        ),
      ),
    );
  }
}

class _TerminalCopyWorkspace extends StatelessWidget {
  const _TerminalCopyWorkspace({
    required this.controller,
    required this.scrollController,
    required this.strings,
    required this.lineCount,
    required this.characterCount,
  });

  final TextEditingController controller;
  final ScrollController scrollController;
  final TerminalStrings strings;
  final int lineCount;
  final int characterCount;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compactWidth = constraints.maxWidth < 600;
        final compactHeight = constraints.maxHeight < 600;
        final useCompactSummary =
            compactHeight && (compactWidth || constraints.maxHeight < 480);
        final horizontalPadding = compactWidth
            ? AppTheme.compactPagePadding
            : AppTheme.pagePadding;
        final verticalPadding = compactHeight ? 8.0 : 16.0;
        final gap = compactHeight ? 8.0 : 12.0;

        return Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            verticalPadding,
            horizontalPadding,
            compactHeight ? 8 : 20,
          ),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              key: const ValueKey('terminal-copy-content'),
              constraints: const BoxConstraints(maxWidth: 1200),
              child: SizedBox(
                width: double.infinity,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (useCompactSummary)
                      _CompactSnapshotSummary(
                        strings: strings,
                        lineCount: lineCount,
                        characterCount: characterCount,
                      )
                    else
                      _SnapshotSummaryCard(
                        strings: strings,
                        lineCount: lineCount,
                        characterCount: characterCount,
                      ),
                    SizedBox(height: gap),
                    Expanded(
                      child: _TerminalOutputSurface(
                        controller: controller,
                        scrollController: scrollController,
                        strings: strings,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SnapshotSummaryCard extends StatelessWidget {
  const _SnapshotSummaryCard({
    required this.strings,
    required this.lineCount,
    required this.characterCount,
  });

  final TerminalStrings strings;
  final int lineCount;
  final int characterCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Card(
      key: const ValueKey('terminal-copy-summary'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final details = Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const ExcludeSemantics(
                  child: AppIconBadge(
                    icon: Icons.terminal_rounded,
                    size: 42,
                    iconSize: 21,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          strings.terminalOutputSnapshot,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        strings.terminalOutputSummary(
                          lineCount,
                          characterCount,
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        strings.terminalOutputSelectionHint,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
            final status = _ReadOnlyStatus(strings: strings);

            if (constraints.maxWidth < 520) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  details,
                  const SizedBox(height: 12),
                  Align(alignment: Alignment.centerLeft, child: status),
                ],
              );
            }

            return Row(
              children: [
                Expanded(child: details),
                const SizedBox(width: 16),
                status,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _CompactSnapshotSummary extends StatelessWidget {
  const _CompactSnapshotSummary({
    required this.strings,
    required this.lineCount,
    required this.characterCount,
  });

  final TerminalStrings strings;
  final int lineCount;
  final int characterCount;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final summary = strings.terminalOutputSummary(lineCount, characterCount);

    return Semantics(
      key: const ValueKey('terminal-copy-compact-summary'),
      container: true,
      label: '${strings.terminalOutputSnapshot}. $summary. ${strings.readOnly}',
      child: ExcludeSemantics(
        child: Card(
          margin: EdgeInsets.zero,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.terminal_rounded, size: 20, color: colors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(
                    Icons.lock_outline_rounded,
                    size: 20,
                    color: colors.secondary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReadOnlyStatus extends StatelessWidget {
  const _ReadOnlyStatus({required this.strings});

  final TerminalStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent =
        theme.extension<ExtendedColors>()?.success ?? colors.secondary;

    return Semantics(
      key: const ValueKey('terminal-copy-read-only-status'),
      container: true,
      label: strings.readOnly,
      child: ExcludeSemantics(
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppTheme.radiusPill),
            border: Border.all(color: accent.withValues(alpha: 0.28)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline_rounded, size: 18, color: accent),
              const SizedBox(width: 7),
              Text(
                strings.readOnly,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TerminalOutputSurface extends StatelessWidget {
  const _TerminalOutputSurface({
    required this.controller,
    required this.scrollController,
    required this.strings,
  });

  final TextEditingController controller;
  final ScrollController scrollController;
  final TerminalStrings strings;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Card(
      key: const ValueKey('terminal-copy-output-surface'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(color: colors.outline.withValues(alpha: 0.72)),
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        ),
        child: Semantics(
          key: const ValueKey('terminal-copy-output'),
          container: true,
          label: strings.terminalOutput,
          hint: strings.terminalOutputSelectionHint,
          child: Scrollbar(
            controller: scrollController,
            child: TextField(
              key: const ValueKey('terminal-copy-text-field'),
              controller: controller,
              scrollController: scrollController,
              readOnly: true,
              minLines: null,
              maxLines: null,
              expands: true,
              keyboardType: TextInputType.multiline,
              textAlignVertical: TextAlignVertical.top,
              enableSuggestions: false,
              autocorrect: false,
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
              style: TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: AppTheme.monospaceFallback,
                fontSize: 13,
                height: 1.4,
                color: colors.onSurface,
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                filled: false,
                contentPadding: EdgeInsets.all(18),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
