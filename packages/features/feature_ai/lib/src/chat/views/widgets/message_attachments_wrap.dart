import 'package:flutter/material.dart';

import 'package:feature_ai/src/chat/views/widgets/attachment_image_thumbnail.dart';
import 'package:feature_ai/src/domain/ai_compat.dart';
import 'package:app_ui/app_ui.dart';

class MessageAttachmentsWrap extends StatelessWidget {
  const MessageAttachmentsWrap({
    super.key,
    required this.attachments,
    this.isEnglish = false,
  });

  final List<AiChatAttachment> attachments;
  final bool isEnglish;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();

    final colorScheme = Theme.of(context).colorScheme;
    final fileChipMaxWidth = (MediaQuery.sizeOf(context).width * 0.72).clamp(
      180.0,
      320.0,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final attachment in attachments)
            if (attachment.isImage)
              AiAttachmentImageThumbnail(
                attachment: attachment,
                width: 120,
                height: 120,
                previewSemanticLabel: isEnglish
                    ? 'Preview image ${attachment.fileName}'
                    : '预览图片 ${attachment.fileName}',
                unavailableSemanticLabel: isEnglish
                    ? 'Image preview unavailable for ${attachment.fileName}'
                    : '图片预览不可用 ${attachment.fileName}',
              )
            else
              Semantics(
                container: true,
                label: isEnglish
                    ? 'File attachment ${attachment.fileName}, '
                          '${attachment.mimeType}, ${_formatSize(attachment.sizeBytes)}'
                    : '文件附件 ${attachment.fileName}，'
                          '${attachment.mimeType}，${_formatSize(attachment.sizeBytes)}',
                child: ExcludeSemantics(
                  child: Container(
                    constraints: BoxConstraints(maxWidth: fileChipMaxWidth),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.insert_drive_file_outlined,
                          size: 14,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
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
                      ],
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
