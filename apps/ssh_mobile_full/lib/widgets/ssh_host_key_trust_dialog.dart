import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/services/ssh_host_key_policy.dart';
import '../services/app_settings.dart';

Future<bool> showSshHostKeyTrustDialog(
  BuildContext context,
  SshHostKeyPromptRequest request,
) async {
  if (!context.mounted) return false;
  final isEnglish = context.read<AppSettings>().isEnglish;
  final trusted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(isEnglish ? 'Trust SSH host key?' : '信任 SSH 主机密钥？'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isEnglish
                  ? 'This is the first time this app has seen the SSH host key for this server.'
                  : '这是本应用首次看到该服务器的 SSH 主机密钥。',
            ),
            const SizedBox(height: 12),
            _HostKeyDetailRow(
              label: isEnglish ? 'Server' : '服务器',
              value:
                  '${request.connectionName} (${request.username}@${request.host}:${request.port})',
            ),
            _HostKeyDetailRow(
              label: isEnglish ? 'Algorithm' : '算法',
              value: request.algorithm,
            ),
            _HostKeyDetailRow(
              label: isEnglish ? 'Fingerprint' : '指纹',
              value: request.fingerprint,
              selectable: true,
            ),
            const SizedBox(height: 12),
            Text(
              isEnglish
                  ? 'Only continue if this fingerprint matches the server you expect.'
                  : '请仅在该指纹与预期服务器一致时继续。',
              style: TextStyle(
                color: Theme.of(ctx).colorScheme.error,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(isEnglish ? 'Cancel' : '取消'),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.verified_user_outlined),
          onPressed: () => Navigator.pop(ctx, true),
          label: Text(isEnglish ? 'Trust key' : '信任密钥'),
        ),
      ],
    ),
  );
  return trusted ?? false;
}

class _HostKeyDetailRow extends StatelessWidget {
  final String label;
  final String value;
  final bool selectable;

  const _HostKeyDetailRow({
    required this.label,
    required this.value,
    this.selectable = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final valueStyle = TextStyle(
      fontSize: 13,
      color: colorScheme.onSurface,
      fontFamily: selectable ? 'monospace' : null,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          selectable
              ? SelectableText(value, style: valueStyle)
              : Text(value, style: valueStyle),
        ],
      ),
    );
  }
}
