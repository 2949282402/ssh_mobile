import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/theme/app_theme.dart';

class AiAttachmentImageThumbnail extends StatefulWidget {
  const AiAttachmentImageThumbnail({
    super.key,
    required this.attachment,
    required this.width,
    required this.height,
    required this.previewSemanticLabel,
    required this.unavailableSemanticLabel,
    this.borderRadius = const BorderRadius.all(
      Radius.circular(AppTheme.radiusSmall),
    ),
    this.fit = BoxFit.cover,
  });

  final AiChatAttachment attachment;
  final double width;
  final double height;
  final String previewSemanticLabel;
  final String unavailableSemanticLabel;
  final BorderRadius borderRadius;
  final BoxFit fit;

  @override
  State<AiAttachmentImageThumbnail> createState() =>
      _AiAttachmentImageThumbnailState();
}

class _AiAttachmentImageThumbnailState
    extends State<AiAttachmentImageThumbnail> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(covariant AiAttachmentImageThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.dataBase64 != widget.attachment.dataBase64) {
      _decode();
    }
  }

  void _decode() {
    try {
      final encoded = widget.attachment.dataBase64.trim();
      _bytes = encoded.isEmpty ? null : base64Decode(encoded);
    } on FormatException {
      _bytes = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    final colorScheme = Theme.of(context).colorScheme;
    if (bytes == null || bytes.isEmpty) {
      return Semantics(
        image: true,
        label: widget.unavailableSemanticLabel,
        child: ExcludeSemantics(
          child: Material(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: widget.borderRadius,
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: widget.width,
              height: widget.height,
              child: Icon(
                Icons.broken_image_outlined,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (widget.width * pixelRatio)
        .round()
        .clamp(1, 4096)
        .toInt();
    final cacheHeight = (widget.height * pixelRatio)
        .round()
        .clamp(1, 4096)
        .toInt();

    return Semantics(
      image: true,
      button: true,
      label: widget.previewSemanticLabel,
      child: ExcludeSemantics(
        child: Material(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: widget.borderRadius,
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: widget.width,
            height: widget.height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(
                  bytes,
                  fit: widget.fit,
                  cacheWidth: cacheWidth,
                  cacheHeight: cacheHeight,
                  errorBuilder: (_, _, _) => Icon(
                    Icons.broken_image_outlined,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                Material(
                  type: MaterialType.transparency,
                  child: InkWell(onTap: () => _openPreview(context, bytes)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openPreview(BuildContext context, Uint8List bytes) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _AiAttachmentImagePreviewPage(
          fileName: widget.attachment.fileName,
          bytes: bytes,
          unavailableLabel: widget.unavailableSemanticLabel,
        ),
      ),
    );
  }
}

class _AiAttachmentImagePreviewPage extends StatelessWidget {
  const _AiAttachmentImagePreviewPage({
    required this.fileName,
    required this.bytes,
    required this.unavailableLabel,
  });

  final String fileName;
  final Uint8List bytes;
  final String unavailableLabel;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: Center(
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 6,
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => Semantics(
                image: true,
                label: unavailableLabel,
                child: const Icon(
                  Icons.broken_image_outlined,
                  size: 48,
                  color: Colors.white70,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
