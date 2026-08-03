import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/app_settings.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/app_surface.dart';

class SftpSettingsScreen extends StatelessWidget {
  const SftpSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final strings = AppStrings(settings.language);
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
    final settings = context.read<AppSettings>();
    final strings = AppStrings(settings.language);
    final controller = TextEditingController(
      text: (currentBytes / (1024 * 1024)).toStringAsFixed(
        currentBytes % (1024 * 1024) == 0 ? 0 : 1,
      ),
    );
    String? error;
    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: 'MB'),
              ),
              if (error != null) ...[
                const SizedBox(height: 6),
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 8),
              Text(strings.sftpLimitDialogHint),
              Text(
                strings.sftpLimitRange(
                  _formatBytes(AppSettings.minSftpLimitBytes),
                  _formatBytes(AppSettings.maxSftpLimitBytes),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(strings.cancel),
            ),
            FilledButton(
              onPressed: () {
                final value = double.tryParse(controller.text.trim());
                final bytes = value == null
                    ? null
                    : (value * 1024 * 1024).round();
                if (bytes == null ||
                    bytes < AppSettings.minSftpLimitBytes ||
                    bytes > AppSettings.maxSftpLimitBytes) {
                  setState(() => error = strings.sftpLimitInvalid);
                  return;
                }
                Navigator.pop(dialogContext, bytes);
              },
              child: Text(strings.save),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
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
