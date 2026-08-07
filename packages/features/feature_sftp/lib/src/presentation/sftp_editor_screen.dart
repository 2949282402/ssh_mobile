import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:app_ui/app_ui.dart';

import '../application/sftp_viewmodel.dart';
import '../domain/sftp_models.dart';
import '../domain/sftp_ports.dart';
import '../domain/sftp_strings.dart';

part 'widgets/sftp_editor_status.dart';
part 'widgets/sftp_editor_toolbar.dart';
part 'widgets/sftp_editor_surface.dart';

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
    final maxBytes = context.read<SftpSettingsPort>().sftpTextEditLimitBytes;
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
      context.read<SftpLoggerPort?>()?.error(
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
    final language = context.select<SftpSettingsPort, SftpLanguage>(
      (settings) => settings.language,
    );
    final strings = SftpStrings(language);

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

  Widget _buildWorkspace(SftpStrings strings) {
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

  Future<void> _handlePop(bool didPop, SftpStrings strings) async {
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

  Future<void> _save(SftpStrings strings) async {
    if (_saving || !_loaded || !_hasUnsavedChanges) return;

    final textToSave = _controller.text;
    final maxBytes = context.read<SftpSettingsPort>().sftpTextEditLimitBytes;
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
      context.read<SftpLoggerPort?>()?.error(
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

  Future<bool> _confirmDiscard(
    BuildContext context,
    SftpStrings strings,
  ) async {
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
