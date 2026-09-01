part of '../llm_chat_screen.dart';

class ChatToolsBar extends StatelessWidget {
  final String skillsLabel;
  final String serverLabel;
  final String webViewLabel;
  final String imageLabel;
  final String fileLabel;
  final String ragLabel;
  final String promptLabel;
  final String planModeLabel;
  final String playbooksLabel;
  final bool isPlanModeActive;
  final bool isPlanModeBusy;
  final VoidCallback onServerTap;
  final VoidCallback onSkillsTap;
  final VoidCallback onWebViewTap;
  final VoidCallback onImageTap;
  final VoidCallback onFileTap;
  final VoidCallback onRagTap;
  final VoidCallback onPromptTap;
  final VoidCallback onPlanModeTap;
  final VoidCallback onPlaybooksTap;

  const ChatToolsBar({
    super.key,
    required this.skillsLabel,
    required this.serverLabel,
    required this.webViewLabel,
    required this.imageLabel,
    required this.fileLabel,
    required this.ragLabel,
    required this.promptLabel,
    required this.planModeLabel,
    required this.playbooksLabel,
    required this.isPlanModeActive,
    this.isPlanModeBusy = false,
    required this.onServerTap,
    required this.onSkillsTap,
    required this.onWebViewTap,
    required this.onImageTap,
    required this.onFileTap,
    required this.onRagTap,
    required this.onPromptTap,
    required this.onPlanModeTap,
    required this.onPlaybooksTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.36),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final itemsPerRow = chatToolColumnCountFor(constraints.maxWidth);
          const spacing = 8.0;
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
              _ChatToolTile(
                width: tileWidth,
                icon: Icons.psychology_outlined,
                label: Text(promptLabel),
                onPressed: onPromptTap,
              ),
              _ChatToolTile(
                width: tileWidth,
                icon: Icons.rocket_launch_outlined,
                label: Text(playbooksLabel),
                onPressed: onPlaybooksTap,
              ),
              _ChatToolTile(
                tileKey: const ValueKey<String>('chat-tool-plan-mode'),
                width: tileWidth,
                icon: Icons.edit_note_rounded,
                label: Text(planModeLabel),
                onPressed: isPlanModeBusy ? null : onPlanModeTap,
                isActive: isPlanModeActive,
                isBusy: isPlanModeBusy,
                semanticLabel: planModeLabel,
                selected: isPlanModeActive,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ChatToolTile extends StatelessWidget {
  final Key? tileKey;
  final double width;
  final IconData icon;
  final Widget label;
  final VoidCallback? onPressed;
  final bool isActive;
  final bool isBusy;
  final String? semanticLabel;
  final bool? selected;

  const _ChatToolTile({
    this.tileKey,
    required this.width,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.isActive = false,
    this.isBusy = false,
    this.semanticLabel,
    this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final tile = SizedBox(
      key: semanticLabel == null ? tileKey : null,
      width: width,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: isActive
                        ? colorScheme.primaryContainer
                        : colorScheme.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isActive
                          ? colorScheme.primary
                          : colorScheme.outlineVariant,
                    ),
                  ),
                  child: isBusy
                      ? const Padding(
                          padding: EdgeInsets.all(9),
                          child: AppLoadingIndicator(size: 18, strokeWidth: 2),
                        )
                      : Icon(
                          icon,
                          size: 20,
                          color: isActive
                              ? colorScheme.onPrimaryContainer
                              : colorScheme.primary,
                        ),
                ),
                const SizedBox(height: 4),
                DefaultTextStyle.merge(
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isActive
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
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
      ),
    );
    if (semanticLabel == null) return tile;
    return Semantics(
      key: tileKey,
      container: true,
      button: true,
      enabled: onPressed != null,
      selected: selected,
      label: semanticLabel,
      excludeSemantics: true,
      onTap: onPressed,
      child: tile,
    );
  }
}

class AttachmentChip extends StatelessWidget {
  final AiChatAttachment attachment;
  final VoidCallback onRemove;

  const AttachmentChip({
    super.key,
    required this.attachment,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AiStrings(language);
    final isImage = attachment.isImage;
    final maxWidth = (MediaQuery.sizeOf(context).width * 0.72).clamp(
      180.0,
      260.0,
    );
    return Container(
      constraints: BoxConstraints(maxWidth: maxWidth, minHeight: 48),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isImage)
            AiAttachmentImageThumbnail(
              attachment: attachment,
              width: 48,
              height: 48,
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(7),
              ),
              previewSemanticLabel: strings.previewImage(attachment.fileName),
              unavailableSemanticLabel: strings.imagePreviewUnavailable(
                attachment.fileName,
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
          IconButton(
            tooltip: strings.removeAttachmentNamed(attachment.fileName),
            style: IconButton.styleFrom(minimumSize: const Size.square(48)),
            iconSize: 18,
            icon: Icon(
              Icons.close_rounded,
              color: colorScheme.onSurfaceVariant,
            ),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
