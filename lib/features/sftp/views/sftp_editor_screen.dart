import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:ssh_mobile/features/sftp/viewmodels/sftp_viewmodel.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/theme/app_theme.dart';
import 'package:ssh_mobile/widgets/app_surface.dart';

typedef SftpEditorReadText =
    Future<String> Function(SftpEntry entry, int maxBytes);
typedef SftpEditorSaveText =
    Future<void> Function(SftpEntry entry, String text, int maxBytes);

class SftpEditorScreen extends StatefulWidget {
  const SftpEditorScreen({super.key, required this.entry})
    : readTextForTesting = null,
      saveTextForTesting = null;

  @visibleForTesting
  const SftpEditorScreen.forTesting({
    super.key,
    required this.entry,
    required this.readTextForTesting,
    required this.saveTextForTesting,
  });

  final SftpEntry entry;
  @visibleForTesting
  final SftpEditorReadText? readTextForTesting;
  @visibleForTesting
  final SftpEditorSaveText? saveTextForTesting;

  @override
  State<SftpEditorScreen> createState() => _SftpEditorScreenState();
}

class _SftpEditorScreenState extends State<SftpEditorScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _verticalController = ScrollController();
  final ScrollController _horizontalController = ScrollController();

  late Future<void> _loadFuture;
  String _originalText = '';
  double _fontSize = 14;
  bool _wrapLines = true;
  bool _loaded = false;
  bool _hasUnsavedChanges = false;
  bool _saving = false;
  bool _confirmingDiscard = false;

  @override
  void initState() {
    super.initState();
    _loadFuture = _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    _verticalController.dispose();
    _horizontalController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final maxBytes = context.read<AppSettings>().sftpTextEditLimitBytes;
    try {
      final readText = widget.readTextForTesting;
      final text = readText == null
          ? await context.read<SftpViewModel>().readTextFile(
              widget.entry,
              maxBytes: maxBytes,
            )
          : await readText(widget.entry, maxBytes);
      if (!mounted) return;

      _originalText = text;
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      _loaded = true;
      _hasUnsavedChanges = false;
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        'SFTP editor load failed',
        error: error,
        stackTrace: stackTrace,
        details: 'path=${widget.entry.path}',
      );
      if (!mounted) return;
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  void _retryLoad() {
    if (_saving) return;
    setState(() {
      _loaded = false;
      _hasUnsavedChanges = false;
      _loadFuture = _load();
    });
  }

  void _handleTextChanged(String text) {
    if (!_loaded) return;
    final dirty = text != _originalText;
    if (dirty == _hasUnsavedChanges) return;
    setState(() => _hasUnsavedChanges = dirty);
  }

  void _adjustFontSize(double delta) {
    setState(() {
      _fontSize = (_fontSize + delta).clamp(10.0, 28.0);
    });
  }

  void _setFontSize(double value) {
    setState(() => _fontSize = value);
  }

  void _toggleLineWrap() {
    setState(() => _wrapLines = !_wrapLines);
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AppStrings(language);

    return PopScope(
      canPop: !_hasUnsavedChanges && !_saving,
      onPopInvokedWithResult: (didPop, _) => _handlePop(didPop, strings),
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            key: const ValueKey('sftp-editor-back'),
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => Navigator.maybePop(context),
          ),
          title: Text(
            strings.editRemoteFile(widget.entry.name),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            Semantics(
              key: const ValueKey('sftp-editor-save'),
              container: true,
              liveRegion: _saving,
              label: _saving
                  ? strings.savingRemoteFile
                  : strings.saveRemoteFile,
              button: true,
              enabled: _loaded && _hasUnsavedChanges && !_saving,
              onTap: _loaded && _hasUnsavedChanges && !_saving
                  ? () => _save(strings)
                  : null,
              child: ExcludeSemantics(
                child: IconButton(
                  tooltip: _saving
                      ? strings.savingRemoteFile
                      : strings.saveRemoteFile,
                  onPressed: _loaded && _hasUnsavedChanges && !_saving
                      ? () => _save(strings)
                      : null,
                  icon: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.2),
                        )
                      : const Icon(Icons.save_outlined),
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: AppPageSurface(
          child: SafeArea(
            top: false,
            child: FutureBuilder<void>(
              future: _loadFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return _EditorLoading(strings: strings);
                }
                if (snapshot.hasError) {
                  return _EditorLoadError(
                    strings: strings,
                    onRetry: _retryLoad,
                  );
                }
                return _buildWorkspace(strings);
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWorkspace(AppStrings strings) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compactWidth = constraints.maxWidth < 600;
        final compactHeight = constraints.maxHeight < 600;
        final hideFileSummary =
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
              constraints: const BoxConstraints(maxWidth: 1200),
              child: SizedBox(
                width: double.infinity,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (hideFileSummary)
                      _CompactFileSummary(
                        entry: widget.entry,
                        strings: strings,
                        hasUnsavedChanges: _hasUnsavedChanges,
                      )
                    else
                      _FileSummaryCard(
                        entry: widget.entry,
                        strings: strings,
                        hasUnsavedChanges: _hasUnsavedChanges,
                      ),
                    SizedBox(height: gap),
                    _EditorToolbar(
                      strings: strings,
                      fontSize: _fontSize,
                      wrapLines: _wrapLines,
                      enabled: !_saving,
                      onDecreaseFont: () => _adjustFontSize(-1),
                      onIncreaseFont: () => _adjustFontSize(1),
                      onFontSizeChanged: _setFontSize,
                      onToggleLineWrap: _toggleLineWrap,
                    ),
                    SizedBox(height: gap),
                    Expanded(
                      child: _EditorSurface(
                        controller: _controller,
                        verticalController: _verticalController,
                        horizontalController: _horizontalController,
                        strings: strings,
                        fontSize: _fontSize,
                        wrapLines: _wrapLines,
                        readOnly: _saving,
                        onChanged: _handleTextChanged,
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

  Future<void> _handlePop(bool didPop, AppStrings strings) async {
    if (didPop || _saving || !_hasUnsavedChanges || _confirmingDiscard) {
      return;
    }

    _confirmingDiscard = true;
    final discard = await _confirmDiscard(context, strings);
    if (!mounted) return;
    _confirmingDiscard = false;
    if (!discard) return;

    setState(() {
      _originalText = _controller.text;
      _hasUnsavedChanges = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> _save(AppStrings strings) async {
    if (_saving || !_loaded || !_hasUnsavedChanges) return;

    final textToSave = _controller.text;
    final maxBytes = context.read<AppSettings>().sftpTextEditLimitBytes;
    setState(() => _saving = true);

    try {
      final saveText = widget.saveTextForTesting;
      if (saveText == null) {
        await context.read<SftpViewModel>().saveTextFile(
          widget.entry,
          textToSave,
          maxBytes: maxBytes,
        );
      } else {
        await saveText(widget.entry, textToSave, maxBytes);
      }
      if (!mounted) return;

      _originalText = textToSave;
      final hasNewerChanges = _controller.text != _originalText;
      setState(() {
        _saving = false;
        _hasUnsavedChanges = hasNewerChanges;
      });
      if (hasNewerChanges) {
        _showSaveFeedback(strings.remoteFileNewChangesRemain);
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final hasLateChanges =
            _controller.text != _originalText || _hasUnsavedChanges || _saving;
        if (hasLateChanges) {
          if (!_hasUnsavedChanges) {
            setState(() => _hasUnsavedChanges = true);
          }
          _showSaveFeedback(strings.remoteFileNewChangesRemain);
          return;
        }
        _showSaveFeedback(strings.saveComplete);
        Navigator.pop(context, true);
      });
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        'SFTP editor save failed',
        error: error,
        stackTrace: stackTrace,
        details: 'path=${widget.entry.path}',
      );
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is SftpTextSizeLimitException
                ? strings.remoteFileTooLarge(error.maxBytes)
                : strings.remoteFileSaveFailed,
          ),
        ),
      );
    }
  }

  void _showSaveFeedback(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirmDiscard(BuildContext context, AppStrings strings) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(strings.discardChangesTitle),
            content: Text(strings.discardChangesContent),
            actions: [
              TextButton(
                key: const ValueKey('sftp-editor-keep-editing'),
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(strings.cancel),
              ),
              FilledButton.tonal(
                key: const ValueKey('sftp-editor-discard'),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(strings.discard),
              ),
            ],
          ),
        ) ??
        false;
  }
}

class _EditorLoading extends StatelessWidget {
  const _EditorLoading({required this.strings});

  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Semantics(
              key: const ValueKey('sftp-editor-loading'),
              container: true,
              liveRegion: true,
              label: strings.loadingRemoteFile,
              child: ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.all(AppTheme.pagePadding),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 30,
                        height: 30,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        strings.loadingRemoteFile,
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

class _EditorLoadError extends StatelessWidget {
  const _EditorLoadError({required this.strings, required this.onRetry});

  final AppStrings strings;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Semantics(
            key: const ValueKey('sftp-editor-load-error'),
            container: true,
            explicitChildNodes: true,
            liveRegion: true,
            label:
                '${strings.remoteFileOpenFailed}. '
                '${strings.remoteFileOpenFailedHint}',
            child: AppEmptyState(
              icon: Icons.cloud_off_rounded,
              title: strings.remoteFileOpenFailed,
              message: strings.remoteFileOpenFailedHint,
              action: FilledButton.icon(
                key: const ValueKey('sftp-editor-retry'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(strings.retry),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FileSummaryCard extends StatelessWidget {
  const _FileSummaryCard({
    required this.entry,
    required this.strings,
    required this.hasUnsavedChanges,
  });

  final SftpEntry entry;
  final AppStrings strings;
  final bool hasUnsavedChanges;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Card(
      key: const ValueKey('sftp-editor-file-summary'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final fileDetails = Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const AppIconBadge(
                  icon: Icons.code_rounded,
                  size: 42,
                  iconSize: 21,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Semantics(
                        key: const ValueKey('sftp-editor-path'),
                        container: true,
                        label: '${strings.remoteFilePath}: ${entry.path}',
                        child: ExcludeSemantics(
                          child: Text(
                            entry.path,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                              fontFamily: 'monospace',
                              fontFamilyFallback: AppTheme.monospaceFallback,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
            final status = _EditorStatusPill(
              strings: strings,
              hasUnsavedChanges: hasUnsavedChanges,
            );

            if (constraints.maxWidth < 520) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  fileDetails,
                  const SizedBox(height: 12),
                  Align(alignment: Alignment.centerLeft, child: status),
                ],
              );
            }

            return Row(
              children: [
                Expanded(child: fileDetails),
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

class _CompactFileSummary extends StatelessWidget {
  const _CompactFileSummary({
    required this.entry,
    required this.strings,
    required this.hasUnsavedChanges,
  });

  final SftpEntry entry;
  final AppStrings strings;
  final bool hasUnsavedChanges;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final extended = Theme.of(context).extension<ExtendedColors>();
    final accent = hasUnsavedChanges
        ? (extended?.warning ?? colors.tertiary)
        : (extended?.success ?? colors.secondary);
    final status = hasUnsavedChanges
        ? strings.remoteFileUnsaved
        : strings.remoteFileSaved;

    return Semantics(
      key: const ValueKey('sftp-editor-compact-summary'),
      container: true,
      liveRegion: true,
      label: '${strings.remoteFilePath}: ${entry.path}. $status',
      child: ExcludeSemantics(
        child: Card(
          margin: EdgeInsets.zero,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.code_rounded, size: 20, color: colors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      entry.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontFamily: 'monospace',
                        fontFamilyFallback: AppTheme.monospaceFallback,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(
                    hasUnsavedChanges
                        ? Icons.edit_note_rounded
                        : Icons.cloud_done_rounded,
                    size: 20,
                    color: accent,
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

class _EditorStatusPill extends StatelessWidget {
  const _EditorStatusPill({
    required this.strings,
    required this.hasUnsavedChanges,
  });

  final AppStrings strings;
  final bool hasUnsavedChanges;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final extended = theme.extension<ExtendedColors>();
    final accent = hasUnsavedChanges
        ? (extended?.warning ?? colors.tertiary)
        : (extended?.success ?? colors.secondary);
    final label = hasUnsavedChanges
        ? strings.remoteFileUnsaved
        : strings.remoteFileSaved;

    return Semantics(
      key: const ValueKey('sftp-editor-save-status'),
      container: true,
      liveRegion: true,
      label: label,
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
              Icon(
                hasUnsavedChanges
                    ? Icons.edit_note_rounded
                    : Icons.cloud_done_rounded,
                size: 18,
                color: accent,
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EditorToolbar extends StatelessWidget {
  const _EditorToolbar({
    required this.strings,
    required this.fontSize,
    required this.wrapLines,
    required this.enabled,
    required this.onDecreaseFont,
    required this.onIncreaseFont,
    required this.onFontSizeChanged,
    required this.onToggleLineWrap,
  });

  final AppStrings strings;
  final double fontSize;
  final bool wrapLines;
  final bool enabled;
  final VoidCallback onDecreaseFont;
  final VoidCallback onIncreaseFont;
  final ValueChanged<double> onFontSizeChanged;
  final VoidCallback onToggleLineWrap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final wrapTooltip = wrapLines
        ? strings.disableLineWrap
        : strings.enableLineWrap;

    return Card(
      key: const ValueKey('sftp-editor-toolbar'),
      margin: EdgeInsets.zero,
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: strings.editorControls,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final showLabel = constraints.maxWidth >= 560;
              return Row(
                children: [
                  if (showLabel) ...[
                    Icon(
                      Icons.format_size_rounded,
                      size: 20,
                      color: colors.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      strings.editorFontSize,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(width: 8),
                  ],
                  IconButton(
                    key: const ValueKey('sftp-editor-font-decrease'),
                    tooltip: strings.smallerFont,
                    constraints: const BoxConstraints.tightFor(
                      width: 48,
                      height: 48,
                    ),
                    onPressed: enabled && fontSize > 10 ? onDecreaseFont : null,
                    icon: const Icon(Icons.text_decrease_rounded),
                  ),
                  Expanded(
                    child: Semantics(
                      key: const ValueKey('sftp-editor-font-slider'),
                      label: strings.editorFontSize,
                      value: strings.fontSizeValue(fontSize.round()),
                      child: Slider(
                        min: 10,
                        max: 28,
                        divisions: 18,
                        label: fontSize.toStringAsFixed(0),
                        value: fontSize,
                        onChanged: enabled ? onFontSizeChanged : null,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 38,
                    child: Text(
                      fontSize.toStringAsFixed(0),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('sftp-editor-font-increase'),
                    tooltip: strings.largerFont,
                    constraints: const BoxConstraints.tightFor(
                      width: 48,
                      height: 48,
                    ),
                    onPressed: enabled && fontSize < 28 ? onIncreaseFont : null,
                    icon: const Icon(Icons.text_increase_rounded),
                  ),
                  const SizedBox(width: 4),
                  Semantics(
                    key: const ValueKey('sftp-editor-line-wrap'),
                    container: true,
                    label: wrapTooltip,
                    button: true,
                    enabled: enabled,
                    toggled: wrapLines,
                    onTap: enabled ? onToggleLineWrap : null,
                    child: ExcludeSemantics(
                      child: IconButton(
                        tooltip: wrapTooltip,
                        constraints: const BoxConstraints.tightFor(
                          width: 48,
                          height: 48,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor: wrapLines
                              ? colors.primaryContainer
                              : Colors.transparent,
                          foregroundColor: wrapLines
                              ? colors.onPrimaryContainer
                              : colors.onSurfaceVariant,
                        ),
                        onPressed: enabled ? onToggleLineWrap : null,
                        icon: Icon(
                          wrapLines
                              ? Icons.wrap_text_rounded
                              : Icons.notes_rounded,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _EditorSurface extends StatefulWidget {
  const _EditorSurface({
    required this.controller,
    required this.verticalController,
    required this.horizontalController,
    required this.strings,
    required this.fontSize,
    required this.wrapLines,
    required this.readOnly,
    required this.onChanged,
  });

  final TextEditingController controller;
  final ScrollController verticalController;
  final ScrollController horizontalController;
  final AppStrings strings;
  final double fontSize;
  final bool wrapLines;
  final bool readOnly;
  final ValueChanged<String> onChanged;

  @override
  State<_EditorSurface> createState() => _EditorSurfaceState();
}

class _EditorSurfaceState extends State<_EditorSurface> {
  static const _widthRecalculationDelay = Duration(milliseconds: 220);

  Timer? _widthRecalculationTimer;
  late String _lastText;
  late double _longestColumns;

  @override
  void initState() {
    super.initState();
    _resetWidthCache();
  }

  @override
  void didUpdateWidget(covariant _EditorSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _widthRecalculationTimer?.cancel();
      _resetWidthCache();
      return;
    }
    if (oldWidget.wrapLines && !widget.wrapLines) {
      _recalculateWidth(notify: false);
    } else if (widget.controller.text != _lastText) {
      _recalculateWidth(notify: false);
    }
  }

  @override
  void dispose() {
    _widthRecalculationTimer?.cancel();
    super.dispose();
  }

  void _resetWidthCache() {
    _lastText = widget.controller.text;
    _longestColumns = _measureLongestColumns(_lastText);
  }

  void _handleTextChanged(String text) {
    if (text != _lastText) {
      final lengthDelta = text.length - _lastText.length;
      if (lengthDelta > 0) {
        _longestColumns += lengthDelta * 2;
      } else if (lengthDelta == 0) {
        _longestColumns += 2;
      }
      _lastText = text;
      _scheduleWidthRecalculation();
      if (!widget.wrapLines) setState(() {});
    }
    widget.onChanged(text);
  }

  void _scheduleWidthRecalculation() {
    _widthRecalculationTimer?.cancel();
    _widthRecalculationTimer = Timer(
      _widthRecalculationDelay,
      () => _recalculateWidth(notify: true),
    );
  }

  void _recalculateWidth({required bool notify}) {
    final text = widget.controller.text;
    final longestColumns = _measureLongestColumns(text);
    final changed = longestColumns != _longestColumns || text != _lastText;
    _lastText = text;
    _longestColumns = longestColumns;
    if (notify && changed && mounted && !widget.wrapLines) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Card(
      key: const ValueKey('sftp-editor-surface'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(color: colors.outline.withValues(alpha: 0.72)),
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        ),
        child: Semantics(
          container: true,
          label: widget.strings.remoteFileContent,
          child: widget.wrapLines
              ? _buildWrappedEditor()
              : _buildUnwrappedEditor(),
        ),
      ),
    );
  }

  Widget _buildWrappedEditor() {
    return Scrollbar(
      controller: widget.verticalController,
      child: _buildTextField(),
    );
  }

  Widget _buildUnwrappedEditor() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = _estimatedUnwrappedWidth(
          _longestColumns,
          widget.fontSize,
          constraints.maxWidth,
        );
        return Scrollbar(
          controller: widget.horizontalController,
          notificationPredicate: (notification) => notification.depth == 0,
          child: SingleChildScrollView(
            controller: widget.horizontalController,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              key: const ValueKey('sftp-editor-unwrapped-canvas'),
              width: width,
              height: constraints.maxHeight,
              child: Scrollbar(
                controller: widget.verticalController,
                child: _buildTextField(),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTextField() {
    return TextField(
      key: const ValueKey('sftp-editor-text-field'),
      controller: widget.controller,
      scrollController: widget.verticalController,
      expands: true,
      maxLines: null,
      minLines: null,
      readOnly: widget.readOnly,
      autocorrect: false,
      enableSuggestions: false,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      keyboardType: TextInputType.multiline,
      textAlignVertical: TextAlignVertical.top,
      onChanged: _handleTextChanged,
      decoration: InputDecoration(
        border: InputBorder.none,
        filled: false,
        hintText: widget.strings.remoteFileContent,
        contentPadding: const EdgeInsets.all(18),
      ),
      style: TextStyle(
        fontFamily: 'monospace',
        fontFamilyFallback: AppTheme.monospaceFallback,
        fontSize: widget.fontSize,
        height: 1.45,
      ),
    );
  }
}

double _estimatedUnwrappedWidth(
  double longestColumns,
  double fontSize,
  double viewportWidth,
) {
  final estimated = longestColumns * fontSize * 0.82 + 48;
  final practicalWidth = estimated.clamp(1600.0, 40000.0).toDouble();
  return math.max(viewportWidth, practicalWidth);
}

double _measureLongestColumns(String text) {
  var currentColumns = 0.0;
  var longestColumns = 0.0;
  for (final rune in text.runes) {
    if (rune == 0x0A || rune == 0x0D) {
      longestColumns = math.max(longestColumns, currentColumns);
      currentColumns = 0;
    } else if (rune == 0x09) {
      currentColumns += 4;
    } else {
      currentColumns += rune > 0x7F ? 2 : 1;
    }
  }
  longestColumns = math.max(longestColumns, currentColumns);
  return longestColumns;
}
