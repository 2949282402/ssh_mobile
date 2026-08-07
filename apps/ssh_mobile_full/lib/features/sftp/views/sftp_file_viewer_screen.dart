import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:ssh_mobile/features/sftp/viewmodels/sftp_viewmodel.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/theme/app_theme.dart';
import 'package:ssh_mobile/widgets/app_surface.dart';

part 'widgets/sftp_file_preview_chrome.dart';
part 'widgets/sftp_file_preview_renderers.dart';

typedef SftpViewerReadBytes =
    Future<Uint8List> Function(
      SftpEntry entry,
      int maxBytes, {
      required bool bypassCache,
    });
typedef SftpViewerHtmlBuilder =
    Widget Function(
      BuildContext context,
      String sandboxedHtml, {
      required Widget loadingWidget,
      required Widget Function(BuildContext context, Object error) onError,
    });
typedef SftpViewerImageProviderBuilder =
    ImageProvider Function(Uint8List bytes, int width, int height);

enum _PreviewKind { image, pdf, markdown, html, text, unsupported }

const _textPreviewHardLimitBytes = 8 * 1024 * 1024;
const _imagePreviewHardLimitBytes = 32 * 1024 * 1024;
const _maxImageSourcePixels = 25 * 1000 * 1000;
const _maxImageSourceDimension = 16 * 1024;
const _maxImageAnimationFrames = 120;
const _maxImageAnimationPixels = 100 * 1000 * 1000;
const _maxDecodedImagePixels = 12 * 1000 * 1000;

class SftpFileViewerScreen extends StatefulWidget {
  const SftpFileViewerScreen({super.key, required this.entry})
    : readBytesForTesting = null,
      htmlBuilderForTesting = null,
      imageProviderBuilderForTesting = null;

  @visibleForTesting
  const SftpFileViewerScreen.forTesting({
    super.key,
    required this.entry,
    required this.readBytesForTesting,
    this.htmlBuilderForTesting,
    this.imageProviderBuilderForTesting,
  });

  final SftpEntry entry;
  @visibleForTesting
  final SftpViewerReadBytes? readBytesForTesting;
  @visibleForTesting
  final SftpViewerHtmlBuilder? htmlBuilderForTesting;
  @visibleForTesting
  final SftpViewerImageProviderBuilder? imageProviderBuilderForTesting;

  @override
  State<SftpFileViewerScreen> createState() => _SftpFileViewerScreenState();
}

class _SftpFileViewerScreenState extends State<SftpFileViewerScreen> {
  late final _PreviewKind _kind;
  Future<_PreviewPayload>? _previewFuture;
  bool _showSource = false;
  bool _loadStarting = false;
  int _loadAttempt = 0;

  bool get _canToggleMode =>
      _kind == _PreviewKind.markdown || _kind == _PreviewKind.html;

  bool get _isTextPreview =>
      _kind == _PreviewKind.markdown ||
      _kind == _PreviewKind.html ||
      _kind == _PreviewKind.text;

  bool get _supportsHtmlPreview {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  String get _heroTag =>
      'sftp_file_${widget.entry.connectionId}_${widget.entry.path}';

  @override
  void initState() {
    super.initState();
    _kind = _previewKind(widget.entry.name);
    if (_kind != _PreviewKind.unsupported && _kind != _PreviewKind.pdf) {
      _beginLoad(rebuild: false);
    }
  }

  static String _parseUtf8(Uint8List bytes) {
    return utf8.decode(bytes, allowMalformed: true);
  }

  void _beginLoad({required bool rebuild, bool bypassCache = false}) {
    if (_loadStarting ||
        _kind == _PreviewKind.unsupported ||
        _kind == _PreviewKind.pdf) {
      return;
    }

    _loadStarting = true;
    _loadAttempt += 1;
    final future = _loadPreview(bypassCache: bypassCache);
    if (rebuild) {
      setState(() {
        _previewFuture = future;
      });
    } else {
      _previewFuture = future;
    }
    future.then<void>(
      (_) => _finishLoad(future),
      onError: (Object _, StackTrace _) => _finishLoad(future),
    );
  }

  void _finishLoad(Future<_PreviewPayload> future) {
    if (identical(_previewFuture, future)) {
      _loadStarting = false;
    }
  }

  Future<_PreviewPayload> _loadPreview({required bool bypassCache}) async {
    final settings = context.read<AppSettings>();
    final maxBytes = _previewLimitFor(_kind, settings);

    try {
      final declaredSize = widget.entry.size;
      if (declaredSize != null && declaredSize > maxBytes) {
        throw _PreviewTooLargeException(maxBytes);
      }

      final readBytes = widget.readBytesForTesting;
      final bytes = readBytes == null
          ? await context.read<SftpViewModel>().downloadBytes(
              widget.entry,
              maxBytes: maxBytes,
              bypassCache: bypassCache,
            )
          : await readBytes(widget.entry, maxBytes, bypassCache: bypassCache);
      if (bytes.length > maxBytes) {
        throw _PreviewTooLargeException(maxBytes);
      }

      if (_isTextPreview) {
        final text = await compute(_parseUtf8, bytes);
        return _PreviewPayload.text(text);
      }
      if (_kind == _PreviewKind.image) {
        final imageMetadata = await _inspectImage(bytes);
        return _PreviewPayload.image(bytes, imageMetadata);
      }
      throw StateError('Binary preview loading is disabled');
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        'SFTP file preview load failed',
        error: error,
        stackTrace: stackTrace,
        details: 'path=${widget.entry.path} kind=${_kind.name}',
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  void _setSourceMode(bool showSource) {
    if (_showSource == showSource) return;
    setState(() => _showSource = showSource);
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AppStrings(language);
    final theme = Theme.of(context);
    final appBarTitleStyle =
        theme.appBarTheme.titleTextStyle ?? theme.textTheme.titleLarge;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const ValueKey('sftp-viewer-back'),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          visualDensity: VisualDensity.standard,
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Hero(
          tag: _heroTag,
          child: Material(
            type: MaterialType.transparency,
            child: Text(
              widget.entry.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: appBarTitleStyle,
            ),
          ),
        ),
      ),
      body: AppPageSurface(
        child: SafeArea(top: false, child: _buildWorkspace(strings)),
      ),
    );
  }

  Widget _buildWorkspace(AppStrings strings) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compactWidth = constraints.maxWidth < 600;
        final compactHeight = constraints.maxHeight < 600;
        final useCompactSummary =
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
              key: const ValueKey('sftp-viewer-content'),
              constraints: const BoxConstraints(maxWidth: 1200),
              child: SizedBox(
                width: double.infinity,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (useCompactSummary)
                      _CompactFileSummary(
                        entry: widget.entry,
                        kind: _kind,
                        strings: strings,
                      )
                    else
                      _FileSummaryCard(
                        entry: widget.entry,
                        kind: _kind,
                        strings: strings,
                      ),
                    if (_canToggleMode) ...[
                      SizedBox(height: gap),
                      _PreviewModeToolbar(
                        strings: strings,
                        showSource: _showSource,
                        onChanged: _setSourceMode,
                      ),
                    ],
                    SizedBox(height: gap),
                    Expanded(
                      child: Card(
                        key: const ValueKey('sftp-viewer-preview-surface'),
                        margin: EdgeInsets.zero,
                        clipBehavior: Clip.antiAlias,
                        child: _buildPreviewContent(strings),
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

  Widget _buildPreviewContent(AppStrings strings) {
    if (_kind == _PreviewKind.unsupported) {
      return _PreviewStateView(
        key: const ValueKey('sftp-viewer-unsupported'),
        icon: Icons.insert_drive_file_outlined,
        title: strings.unsupportedPreviewTitle,
        message: strings.unsupportedPreview,
      );
    }
    if (_kind == _PreviewKind.pdf) {
      return _buildPdfUnavailable(strings);
    }

    return FutureBuilder<_PreviewPayload>(
      future: _previewFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _PreviewLoading(strings: strings);
        }
        if (snapshot.hasError) {
          final error = snapshot.error;
          if (error is _PreviewTooLargeException ||
              error is SftpFileSizeLimitException) {
            final maxBytes = error is _PreviewTooLargeException
                ? error.maxBytes
                : (error as SftpFileSizeLimitException).maxBytes;
            return _PreviewStateView(
              key: const ValueKey('sftp-viewer-too-large'),
              liveRegion: true,
              icon: Icons.data_usage_rounded,
              title: strings.filePreviewTooLarge,
              message: strings.filePreviewTooLargeHint(maxBytes),
              action: _ClosePreviewButton(
                strings: strings,
                onPressed: () => Navigator.maybePop(context),
              ),
            );
          }
          if (error is _PreviewResourceLimitException) {
            return _PreviewStateView(
              key: const ValueKey('sftp-viewer-resource-limit'),
              liveRegion: true,
              icon: Icons.shield_outlined,
              title: strings.filePreviewResourceLimit,
              message: strings.filePreviewResourceLimitHint,
              action: _ClosePreviewButton(
                strings: strings,
                onPressed: () => Navigator.maybePop(context),
              ),
            );
          }
          if (error is _PreviewDecodeException) {
            return _PreviewStateView(
              key: const ValueKey('sftp-viewer-image-error'),
              liveRegion: true,
              icon: Icons.broken_image_outlined,
              title: strings.filePreviewRenderFailed,
              message: strings.filePreviewRenderFailedHint,
              action: _RetryButton(
                strings: strings,
                onPressed: () => _beginLoad(rebuild: true, bypassCache: true),
              ),
            );
          }
          return _PreviewStateView(
            key: const ValueKey('sftp-viewer-load-error'),
            liveRegion: true,
            icon: Icons.cloud_off_rounded,
            title: strings.filePreviewLoadFailed,
            message: strings.filePreviewLoadFailedHint,
            action: _RetryButton(
              strings: strings,
              onPressed: () => _beginLoad(rebuild: true, bypassCache: true),
            ),
          );
        }

        return _buildLoadedPreview(strings, snapshot.data!);
      },
    );
  }

  Widget _buildLoadedPreview(AppStrings strings, _PreviewPayload payload) {
    if (_showSource && _canToggleMode) {
      return _TextPreview(
        key: const ValueKey('sftp-viewer-text'),
        text: payload.text!,
      );
    }

    switch (_kind) {
      case _PreviewKind.image:
        return _ImagePreview(
          bytes: payload.bytes!,
          metadata: payload.imageMetadata!,
          strings: strings,
          path: widget.entry.path,
          onRetry: () => _beginLoad(rebuild: true, bypassCache: true),
          providerBuilderForTesting: widget.imageProviderBuilderForTesting,
        );
      case _PreviewKind.pdf:
        return _buildPdfUnavailable(strings);
      case _PreviewKind.markdown:
        return _MarkdownPreview(text: payload.text!, strings: strings);
      case _PreviewKind.html:
        if (!_supportsHtmlPreview) {
          return _PreviewStateView(
            key: const ValueKey('sftp-viewer-html-unavailable'),
            icon: Icons.code_off_rounded,
            title: strings.htmlPreviewUnavailable,
            message: strings.htmlPreviewUnavailableHint,
            action: FilledButton.icon(
              key: const ValueKey('sftp-viewer-view-source'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: () => _setSourceMode(true),
              icon: const Icon(Icons.code_rounded),
              label: Text(strings.viewSource),
            ),
          );
        }
        return _buildHtmlPreview(strings, payload.text!);
      case _PreviewKind.text:
        return _TextPreview(
          key: const ValueKey('sftp-viewer-text'),
          text: payload.text!,
        );
      case _PreviewKind.unsupported:
        return _PreviewStateView(
          key: const ValueKey('sftp-viewer-unsupported'),
          icon: Icons.insert_drive_file_outlined,
          title: strings.unsupportedPreviewTitle,
          message: strings.unsupportedPreview,
        );
    }
  }

  Widget _buildHtmlPreview(AppStrings strings, String html) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final sandboxedHtml = _sandboxHtml(
      html,
      brightness: theme.brightness,
      backgroundColor: colors.surface,
      foregroundColor: colors.onSurface,
      linkColor: colors.primary,
      codeBackgroundColor: colors.surfaceContainerHighest,
    );
    final loadingWidget = _InlineLoading(label: strings.loadingFilePreview);
    Widget errorBuilder(BuildContext context, Object error) {
      return _LoggedRenderError(
        key: const ValueKey('sftp-viewer-html-error'),
        error: error,
        logMessage: 'SFTP HTML preview render failed',
        path: widget.entry.path,
        strings: strings,
        onRetry: () => _beginLoad(rebuild: true, bypassCache: true),
        secondaryAction: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
          onPressed: () => _setSourceMode(true),
          icon: const Icon(Icons.code_rounded),
          label: Text(strings.viewSource),
        ),
      );
    }

    final builder = widget.htmlBuilderForTesting;
    return Semantics(
      key: const ValueKey('sftp-viewer-html'),
      container: true,
      label: strings.htmlPreviewLabel,
      child: builder == null
          ? _SecureHtmlPreview(
              key: ValueKey('sftp-viewer-html-attempt-$_loadAttempt'),
              sandboxedHtml: sandboxedHtml,
              backgroundColor: colors.surface,
              loadingWidget: loadingWidget,
              errorBuilder: errorBuilder,
            )
          : builder(
              context,
              sandboxedHtml,
              loadingWidget: loadingWidget,
              onError: errorBuilder,
            ),
    );
  }

  Widget _buildPdfUnavailable(AppStrings strings) {
    return _PreviewStateView(
      key: const ValueKey('sftp-viewer-pdf-unavailable'),
      liveRegion: true,
      icon: Icons.picture_as_pdf_outlined,
      title: strings.pdfPreviewUnavailable,
      message: strings.pdfPreviewUnavailableHint,
      action: _ClosePreviewButton(
        strings: strings,
        onPressed: () => Navigator.maybePop(context),
      ),
    );
  }

  _PreviewKind _previewKind(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp')) {
      return _PreviewKind.image;
    }
    if (lower.endsWith('.pdf')) return _PreviewKind.pdf;
    if (lower.endsWith('.md') || lower.endsWith('.markdown')) {
      return _PreviewKind.markdown;
    }
    if (lower.endsWith('.html') || lower.endsWith('.htm')) {
      return _PreviewKind.html;
    }
    if (lower.endsWith('.txt') ||
        lower.endsWith('.log') ||
        lower.endsWith('.json') ||
        lower.endsWith('.yaml') ||
        lower.endsWith('.yml') ||
        lower.endsWith('.toml') ||
        lower.endsWith('.xml') ||
        lower.endsWith('.csv') ||
        lower.endsWith('.ini') ||
        lower.endsWith('.conf') ||
        lower.endsWith('.properties') ||
        lower.endsWith('.sh') ||
        lower.endsWith('.bash') ||
        lower.endsWith('.zsh') ||
        lower.endsWith('.ps1') ||
        lower.endsWith('.bat') ||
        lower.endsWith('.cmd') ||
        lower.endsWith('.py') ||
        lower.endsWith('.rb') ||
        lower.endsWith('.go') ||
        lower.endsWith('.rs') ||
        lower.endsWith('.java') ||
        lower.endsWith('.kt') ||
        lower.endsWith('.swift') ||
        lower.endsWith('.c') ||
        lower.endsWith('.h') ||
        lower.endsWith('.cpp') ||
        lower.endsWith('.hpp') ||
        lower.endsWith('.js') ||
        lower.endsWith('.ts') ||
        lower.endsWith('.css') ||
        lower.endsWith('.sql') ||
        lower.endsWith('.dart')) {
      return _PreviewKind.text;
    }
    return _PreviewKind.unsupported;
  }

  int _previewLimitFor(_PreviewKind kind, AppSettings settings) {
    switch (kind) {
      case _PreviewKind.text:
      case _PreviewKind.markdown:
      case _PreviewKind.html:
        return math.min(
          settings.sftpTextPreviewLimitBytes,
          _textPreviewHardLimitBytes,
        );
      case _PreviewKind.image:
        return math.min(
          settings.sftpRichPreviewLimitBytes,
          _imagePreviewHardLimitBytes,
        );
      case _PreviewKind.pdf:
        return 0;
      case _PreviewKind.unsupported:
        return 0;
    }
  }
}

class _PreviewPayload {
  const _PreviewPayload._({this.bytes, this.text, this.imageMetadata});

  const _PreviewPayload.text(String text) : this._(text: text);

  const _PreviewPayload.image(Uint8List bytes, _ImageMetadata imageMetadata)
    : this._(bytes: bytes, imageMetadata: imageMetadata);

  final Uint8List? bytes;
  final String? text;
  final _ImageMetadata? imageMetadata;
}

class _PreviewTooLargeException implements Exception {
  const _PreviewTooLargeException(this.maxBytes);

  final int maxBytes;
}

class _PreviewResourceLimitException implements Exception {
  const _PreviewResourceLimitException();
}

class _PreviewDecodeException implements Exception {
  const _PreviewDecodeException(this.cause);

  final Object cause;

  @override
  String toString() => 'Preview decode failed: $cause';
}

class _ImageMetadata {
  const _ImageMetadata({
    required this.width,
    required this.height,
    required this.frameCount,
  });

  final int width;
  final int height;
  final int frameCount;

  Size get size => Size(width.toDouble(), height.toDouble());
}

Future<_ImageMetadata> _inspectImage(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = descriptor.width;
    final height = descriptor.height;
    if (!sftpViewerImageMetadataWithinBudget(width, height, 1)) {
      throw const _PreviewResourceLimitException();
    }

    codec = await descriptor.instantiateCodec(targetWidth: 1, targetHeight: 1);
    final frameCount = codec.frameCount;
    if (!sftpViewerImageMetadataWithinBudget(width, height, frameCount)) {
      throw const _PreviewResourceLimitException();
    }
    return _ImageMetadata(width: width, height: height, frameCount: frameCount);
  } on _PreviewResourceLimitException {
    rethrow;
  } catch (error, stackTrace) {
    Error.throwWithStackTrace(_PreviewDecodeException(error), stackTrace);
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

@visibleForTesting
bool sftpViewerImageMetadataWithinBudget(
  int width,
  int height,
  int frameCount,
) {
  if (width <= 0 || height <= 0 || frameCount <= 0) return false;
  if (width > _maxImageSourceDimension ||
      height > _maxImageSourceDimension ||
      frameCount > _maxImageAnimationFrames) {
    return false;
  }
  final pixelsPerFrame = width * height;
  return pixelsPerFrame <= _maxImageSourcePixels &&
      pixelsPerFrame * frameCount <= _maxImageAnimationPixels;
}

Size _boundedPixelSize(
  Size source, {
  required double maxWidth,
  required double maxHeight,
  required int maxPixels,
  required bool allowUpscaling,
}) {
  if (!source.width.isFinite ||
      !source.height.isFinite ||
      source.width <= 0 ||
      source.height <= 0) {
    return const Size(1, 1);
  }

  final pixelScale = math.sqrt(maxPixels / (source.width * source.height));
  var scale = math.min(
    maxWidth / source.width,
    math.min(maxHeight / source.height, pixelScale),
  );
  if (!allowUpscaling) scale = math.min(scale, 1);
  return Size(
    math.max(1, (source.width * scale).floor()).toDouble(),
    math.max(1, (source.height * scale).floor()).toDouble(),
  );
}

IconData _previewKindIcon(_PreviewKind kind) {
  return switch (kind) {
    _PreviewKind.image => Icons.image_outlined,
    _PreviewKind.pdf => Icons.picture_as_pdf_outlined,
    _PreviewKind.markdown => Icons.article_outlined,
    _PreviewKind.html => Icons.code_rounded,
    _PreviewKind.text => Icons.description_outlined,
    _PreviewKind.unsupported => Icons.insert_drive_file_outlined,
  };
}

String _previewKindLabel(_PreviewKind kind, AppStrings strings) {
  return switch (kind) {
    _PreviewKind.image => strings.previewKindImage,
    _PreviewKind.pdf => strings.previewKindPdf,
    _PreviewKind.markdown => strings.previewKindMarkdown,
    _PreviewKind.html => strings.previewKindHtml,
    _PreviewKind.text => strings.previewKindText,
    _PreviewKind.unsupported => strings.previewKindUnsupported,
  };
}

const _htmlPreviewCsp =
    "default-src 'none'; "
    "base-uri 'none'; "
    "form-action 'none'; "
    "object-src 'none'; "
    "script-src 'none'; "
    "connect-src 'none'; "
    "frame-src 'none'; "
    "child-src 'none'; "
    "worker-src 'none'; "
    "style-src 'unsafe-inline'; "
    'img-src data:; '
    'media-src data:; '
    'font-src data:; '
    "navigate-to 'none'";

String _sandboxHtml(
  String rawHtml, {
  required Brightness brightness,
  required Color backgroundColor,
  required Color foregroundColor,
  required Color linkColor,
  required Color codeBackgroundColor,
}) {
  final colorScheme = brightness == Brightness.dark ? 'dark' : 'light';
  final background = _cssColor(backgroundColor);
  final foreground = _cssColor(foregroundColor);
  final link = _cssColor(linkColor);
  final codeBackground = _cssColor(codeBackgroundColor);
  return '''
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta http-equiv="Content-Security-Policy" content="$_htmlPreviewCsp">
  <meta name="referrer" content="no-referrer">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="$colorScheme">
  <style>
    :root { color-scheme: $colorScheme; }
    html, body {
      margin: 0;
      padding: 12px;
      overflow-wrap: anywhere;
      background: $background;
      color: $foreground;
      accent-color: $link;
      font-family: system-ui, sans-serif;
      line-height: 1.5;
    }
    a { color: $link; }
    pre, code { background: $codeBackground; }
    pre { padding: 10px; overflow: auto; border-radius: 8px; }
    img, video { max-width: 100%; height: auto; }
  </style>
</head>
<body>
$rawHtml
</body>
</html>
''';
}

String _cssColor(Color color) {
  final value = color.toARGB32();
  final rgb = value & 0x00FFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0')}';
}
