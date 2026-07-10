import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:ssh_mobile/features/sftp/viewmodels/sftp_viewmodel.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/sftp_service.dart';

class SftpEditorScreen extends StatefulWidget {
  final SftpEntry entry;

  const SftpEditorScreen({super.key, required this.entry});

  @override
  State<SftpEditorScreen> createState() => _SftpEditorScreenState();
}

class _SftpEditorScreenState extends State<SftpEditorScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _verticalController = ScrollController();
  final ScrollController _horizontalController = ScrollController();
  late final Future<void> _loadFuture;
  String _originalText = '';
  double _fontSize = 14;
  bool _wrapLines = true;
  bool _saving = false;

  bool get _dirty => _controller.text != _originalText;

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
    final text = await context.read<SftpViewModel>().readTextFile(
      widget.entry,
      maxBytes: context.read<AppSettings>().sftpTextEditLimitBytes,
    );
    _originalText = text;
    _controller.text = text;
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AppStrings(language);
    final colorScheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: !_dirty || _saving,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !_dirty || _saving) return;
        if (await _confirmDiscard(context, strings) && context.mounted) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                strings.editRemoteFile(widget.entry.name),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15),
              ),
              Text(
                widget.entry.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colorScheme.onSurface.withValues(alpha: 0.62),
                  fontSize: 11,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: strings.smallerFont,
              icon: const Icon(Icons.text_decrease_rounded),
              onPressed: _saving
                  ? null
                  : () => setState(
                      () => _fontSize = (_fontSize - 1).clamp(10, 28),
                    ),
            ),
            IconButton(
              tooltip: strings.largerFont,
              icon: const Icon(Icons.text_increase_rounded),
              onPressed: _saving
                  ? null
                  : () => setState(
                      () => _fontSize = (_fontSize + 1).clamp(10, 28),
                    ),
            ),
            IconButton(
              tooltip: _wrapLines
                  ? strings.disableLineWrap
                  : strings.enableLineWrap,
              icon: Icon(
                _wrapLines ? Icons.wrap_text_rounded : Icons.notes_rounded,
              ),
              onPressed: _saving
                  ? null
                  : () => setState(() => _wrapLines = !_wrapLines),
            ),
            IconButton(
              tooltip: strings.save,
              icon: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              onPressed: _saving ? null : () => _save(context, strings),
            ),
          ],
        ),
        body: FutureBuilder<void>(
          future: _loadFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
            }
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(strings.openEditorFailed(snapshot.error!)),
                ),
              );
            }

            return Column(
              children: [
                Container(
                  height: 42,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: colorScheme.surface,
                    border: Border(
                      bottom: BorderSide(color: colorScheme.outlineVariant),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.format_size_rounded,
                        size: 18,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Slider(
                          min: 10,
                          max: 28,
                          divisions: 18,
                          label: _fontSize.toStringAsFixed(0),
                          value: _fontSize,
                          onChanged: _saving
                              ? null
                              : (value) => setState(() => _fontSize = value),
                        ),
                      ),
                      Text(
                        _fontSize.toStringAsFixed(0),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
                Expanded(child: _buildEditor(colorScheme)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildEditor(ColorScheme colorScheme) {
    final editor = TextField(
      controller: _controller,
      scrollController: _verticalController,
      expands: true,
      maxLines: null,
      minLines: null,
      keyboardType: TextInputType.multiline,
      textAlignVertical: TextAlignVertical.top,
      decoration: const InputDecoration(
        border: InputBorder.none,
        filled: false,
        contentPadding: EdgeInsets.all(14),
      ),
      style: TextStyle(
        fontFamily: 'monospace',
        fontFamilyFallback: [
          'Consolas',
          'Microsoft YaHei',
          'PingFang SC',
          'sans-serif',
        ],
        fontSize: _fontSize,
        height: 1.35,
      ),
    );

    if (_wrapLines) {
      return Scrollbar(controller: _verticalController, child: editor);
    }

    return Scrollbar(
      controller: _horizontalController,
      notificationPredicate: (notification) => notification.depth == 1,
      child: SingleChildScrollView(
        controller: _horizontalController,
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: 1600,
          child: Scrollbar(controller: _verticalController, child: editor),
        ),
      ),
    );
  }

  Future<void> _save(BuildContext context, AppStrings strings) async {
    setState(() => _saving = true);
    try {
      await context.read<SftpViewModel>().saveTextFile(
        widget.entry,
        _controller.text,
      );
      _originalText = _controller.text;
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.saveComplete)));
      Navigator.pop(context, true);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.saveFailed(e))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirmDiscard(BuildContext context, AppStrings strings) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(strings.discardChangesTitle),
            content: Text(strings.discardChangesContent),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(strings.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(strings.discard),
              ),
            ],
          ),
        ) ??
        false;
  }
}
