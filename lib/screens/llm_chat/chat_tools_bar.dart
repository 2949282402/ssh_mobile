part of '../llm_chat_screen.dart';

class _ChatToolsBar extends StatelessWidget {
  final String skillsLabel;
  final String serverLabel;
  final String webViewLabel;
  final String imageLabel;
  final String fileLabel;
  final String ragLabel;
  final VoidCallback onServerTap;
  final VoidCallback onSkillsTap;
  final VoidCallback onWebViewTap;
  final VoidCallback onImageTap;
  final VoidCallback onFileTap;
  final VoidCallback onRagTap;

  const _ChatToolsBar({
    required this.skillsLabel,
    required this.serverLabel,
    required this.webViewLabel,
    required this.imageLabel,
    required this.fileLabel,
    required this.ragLabel,
    required this.onServerTap,
    required this.onSkillsTap,
    required this.onWebViewTap,
    required this.onImageTap,
    required this.onFileTap,
    required this.onRagTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 100, maxHeight: 200),
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.36),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isMobile = defaultTargetPlatform == TargetPlatform.android ||
                defaultTargetPlatform == TargetPlatform.iOS;
            final itemsPerRow = isMobile ? 4 : 2;
            final spacing = 10.0;
            final tileWidth =
                (constraints.maxWidth - (spacing * (itemsPerRow - 1))) /
                    itemsPerRow;
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                _ChatToolTile(
                  width: tileWidth,
                  icon: Icons.dns_outlined,
                  label: Text(serverLabel),
                  onPressed: onServerTap,
                ),
                _ChatToolTile(
                  width: tileWidth,
                  icon: Icons.auto_awesome_outlined,
                  label: Text(skillsLabel),
                  onPressed: onSkillsTap,
                ),
                _ChatToolTile(
                  width: tileWidth,
                  icon: Icons.language_rounded,
                  label: Text(webViewLabel),
                  onPressed: onWebViewTap,
                ),
                _ChatToolTile(
                  width: tileWidth,
                  icon: Icons.image_outlined,
                  label: Text(imageLabel),
                  onPressed: onImageTap,
                ),
                _ChatToolTile(
                  width: tileWidth,
                  icon: Icons.attach_file_rounded,
                  label: Text(fileLabel),
                  onPressed: onFileTap,
                ),
                _ChatToolTile(
                  width: tileWidth,
                  icon: Icons.auto_stories_outlined,
                  label: Text(ragLabel),
                  onPressed: onRagTap,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ChatToolTile extends StatelessWidget {
  final double width;
  final IconData icon;
  final Widget label;
  final VoidCallback onPressed;

  const _ChatToolTile({
    required this.width,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: colorScheme.outlineVariant),
                ),
                child: Icon(icon, size: 20, color: colorScheme.primary),
              ),
              const SizedBox(height: 4),
              DefaultTextStyle.merge(
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 11,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                ),
                child: label,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  final AiChatAttachment attachment;
  final VoidCallback onRemove;

  const _AttachmentChip({
    required this.attachment,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isImage = attachment.isImage && attachment.dataBase64.isNotEmpty;
    return Container(
      constraints: const BoxConstraints(maxWidth: 160),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isImage)
            ClipRRect(
              borderRadius:
                  const BorderRadius.horizontal(left: Radius.circular(7)),
              child: Image.memory(
                base64Decode(attachment.dataBase64),
                width: 36,
                height: 36,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox(
                  width: 36,
                  height: 36,
                  child: Icon(Icons.broken_image_outlined, size: 18),
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Icon(
                Icons.insert_drive_file_outlined,
                size: 18,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              attachment.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          SizedBox(
            width: 28,
            height: 28,
            child: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 16,
              icon: Icon(
                Icons.close_rounded,
                color: colorScheme.onSurfaceVariant,
              ),
              onPressed: onRemove,
            ),
          ),
        ],
      ),
    );
  }
}
