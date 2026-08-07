import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:app_ui/app_ui.dart';

import '../domain/sftp_ports.dart';
import '../domain/sftp_strings.dart';

class SftpSettingsScreen extends StatelessWidget {
  const SftpSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SftpSettingsPort>();
    final strings = SftpStrings(settings.language);
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.sftpSettings),
        leading: IconButton(
          tooltip: strings.close,
          onPressed: () => Navigator.maybePop(context),
          icon: const Icon(Icons.close_rounded),
        ),
      ),
      body: AppPageSurface(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(AppTheme.compactPagePadding),
            children: [
              AppSectionCard(
                title: strings.sftpLimits,
                subtitle: strings.sftpLimitsHint,
                child: Column(
                  children: [
                    _LimitTile(
                      icon: Icons.download_outlined,
                      title: strings.sftpDownloadLimit,
                      value: _formatBytes(settings.sftpDownloadLimitBytes),
                      onTap: () => _editLimit(
                        context,
                        title: strings.sftpDownloadLimit,
                        currentBytes: settings.sftpDownloadLimitBytes,
                        onChanged: settings.setSftpDownloadLimitBytes,
                      ),
                    ),
                    _LimitTile(
                      icon: Icons.article_outlined,
                      title: strings.sftpTextPreviewLimit,
                      value: _formatBytes(settings.sftpTextPreviewLimitBytes),
                      onTap: () => _editLimit(
                        context,
                        title: strings.sftpTextPreviewLimit,
                        currentBytes: settings.sftpTextPreviewLimitBytes,
                        onChanged: settings.setSftpTextPreviewLimitBytes,
                      ),
                    ),
                    _LimitTile(
                      icon: Icons.preview_outlined,
                      title: strings.sftpRichPreviewLimit,
                      value: _formatBytes(settings.sftpRichPreviewLimitBytes),
                      onTap: () => _editLimit(
                        context,
                        title: strings.sftpRichPreviewLimit,
                        currentBytes: settings.sftpRichPreviewLimitBytes,
                        onChanged: settings.setSftpRichPreviewLimitBytes,
                      ),
                    ),
                    _LimitTile(
                      icon: Icons.edit_note_outlined,
                      title: strings.sftpEditLimit,
                      value: _formatBytes(settings.sftpTextEditLimitBytes),
                      onTap: () => _editLimit(
                        context,
                        title: strings.sftpEditLimit,
                        currentBytes: settings.sftpTextEditLimitBytes,
                        onChanged: settings.setSftpTextEditLimitBytes,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Future<void> _editLimit(
    BuildContext context, {
    required String title,
    required int currentBytes,
    required Future<void> Function(int) onChanged,
  }) async {
    final strings = SftpStrings(context.read<SftpSettingsPort>().language);
    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => _LimitEditDialog(
        title: title,
        currentBytes: currentBytes,
        strings: strings,
      ),
    );
    if (result != null && context.mounted) await onChanged(result);
  }

  static String _formatBytes(int bytes) {
    const kb = 1024;
    const mb = 1024 * 1024;
    const gb = 1024 * 1024 * 1024;
    if (bytes >= gb) {
      final value = bytes / gb;
      return '${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1)} GB';
    }
    if (bytes >= mb) {
      final value = bytes / mb;
      return '${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1)} MB';
    }
    final value = bytes / kb;
    return '${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1)} KB';
  }
}

/// Owns the edit dialog's text controller so it is disposed only after the
/// dialog route is fully removed (the exit animation can otherwise rebuild the
/// TextField after the controller is gone).
class _LimitEditDialog extends StatefulWidget {
  final String title;
  final int currentBytes;
  final SftpStrings strings;

  const _LimitEditDialog({
    required this.title,
    required this.currentBytes,
    required this.strings,
  });

  @override
  State<_LimitEditDialog> createState() => _LimitEditDialogState();
}

class _LimitEditDialogState extends State<_LimitEditDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    final bytes = widget.currentBytes;
    _controller = TextEditingController(
      text: (bytes / (1024 * 1024)).toStringAsFixed(
        bytes % (1024 * 1024) == 0 ? 0 : 1,
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'MB'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 6),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 8),
          Text(strings.sftpLimitDialogHint),
          Text(
            strings.sftpLimitRange(
              SftpSettingsScreen._formatBytes(SftpSettingsLimits.minBytes),
              SftpSettingsScreen._formatBytes(SftpSettingsLimits.maxBytes),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(strings.cancel),
        ),
        FilledButton(onPressed: _save, child: Text(strings.save)),
      ],
    );
  }

  void _save() {
    final value = double.tryParse(_controller.text.trim());
    final bytes = value == null ? null : (value * 1024 * 1024).round();
    if (bytes == null ||
        bytes < SftpSettingsLimits.minBytes ||
        bytes > SftpSettingsLimits.maxBytes) {
      setState(() => _error = widget.strings.sftpLimitInvalid);
      return;
    }
    Navigator.pop(context, bytes);
  }
}

class _LimitTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final VoidCallback onTap;

  const _LimitTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, size: 20),
      title: Text(title),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          const Icon(Icons.edit_outlined, size: 18),
        ],
      ),
      onTap: onTap,
    );
  }
}
