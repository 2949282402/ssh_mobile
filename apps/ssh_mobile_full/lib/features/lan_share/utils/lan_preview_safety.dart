import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Hard limits for untrusted LAN preview payloads.
///
/// These budgets intentionally match the established SFTP viewer policy.
const int lanPreviewTextLimitBytes = 8 * 1024 * 1024;
const int lanPreviewImageLimitBytes = 32 * 1024 * 1024;
const int lanPreviewMaxImageSourcePixels = 25 * 1000 * 1000;
const int lanPreviewMaxImageSourceDimension = 16 * 1024;
const int lanPreviewMaxImageAnimationFrames = 120;
const int lanPreviewMaxImageAnimationPixels = 100 * 1000 * 1000;
const int lanPreviewMaxDecodedImagePixels = 12 * 1000 * 1000;

const String lanPreviewHtmlCsp =
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
    "img-src 'none'; "
    "media-src 'none'; "
    "font-src 'none'; "
    "navigate-to 'none'";

class LanPreviewTooLargeException implements Exception {
  const LanPreviewTooLargeException(this.maxBytes);

  final int maxBytes;
}

class LanPreviewResourceLimitException implements Exception {
  const LanPreviewResourceLimitException();
}

class LanPreviewDecodeException implements Exception {
  const LanPreviewDecodeException(this.cause);

  final Object cause;

  @override
  String toString() => 'LAN preview decode failed: $cause';
}

class LanPreviewImageMetadata {
  const LanPreviewImageMetadata({
    required this.width,
    required this.height,
    required this.frameCount,
  });

  final int width;
  final int height;
  final int frameCount;

  ui.Size get size => ui.Size(width.toDouble(), height.toDouble());
}

/// Reads at most [maxBytes] plus one sentinel byte from [file].
///
/// The size is checked on the already-open handle and again while streaming,
/// so a file that grows after the metadata check is still rejected without
/// being accumulated in full.
Future<Uint8List> readLanPreviewFileBounded(
  File file, {
  required int maxBytes,
}) async {
  if (maxBytes <= 0) {
    throw ArgumentError.value(maxBytes, 'maxBytes', 'must be positive');
  }

  final handle = await file.open(mode: FileMode.read);
  try {
    if (await handle.length() > maxBytes) {
      throw LanPreviewTooLargeException(maxBytes);
    }

    final bytes = BytesBuilder(copy: false);
    var total = 0;
    while (total <= maxBytes) {
      final remainingWithSentinel = maxBytes + 1 - total;
      if (remainingWithSentinel <= 0) break;
      final chunk = await handle.read(
        math.min(64 * 1024, remainingWithSentinel),
      );
      if (chunk.isEmpty) break;
      total += chunk.length;
      if (total > maxBytes) {
        throw LanPreviewTooLargeException(maxBytes);
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  } finally {
    await handle.close();
  }
}

/// Counts UTF-8 bytes without allocating an encoded copy of [text].
bool lanPreviewUtf8WithinLimit(String text, int maxBytes) {
  if (maxBytes < 0) return false;
  var bytes = 0;
  for (final rune in text.runes) {
    bytes += switch (rune) {
      <= 0x7f => 1,
      <= 0x7ff => 2,
      <= 0xffff => 3,
      _ => 4,
    };
    if (bytes > maxBytes) return false;
  }
  return true;
}

String decodeLanPreviewUtf8(Uint8List bytes) {
  return utf8.decode(bytes, allowMalformed: true);
}

Future<LanPreviewImageMetadata> inspectLanPreviewImage(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = descriptor.width;
    final height = descriptor.height;
    if (!lanPreviewImageMetadataWithinBudget(width, height, 1)) {
      throw const LanPreviewResourceLimitException();
    }

    codec = await descriptor.instantiateCodec(targetWidth: 1, targetHeight: 1);
    final frameCount = codec.frameCount;
    if (!lanPreviewImageMetadataWithinBudget(width, height, frameCount)) {
      throw const LanPreviewResourceLimitException();
    }
    return LanPreviewImageMetadata(
      width: width,
      height: height,
      frameCount: frameCount,
    );
  } on LanPreviewResourceLimitException {
    rethrow;
  } catch (error, stackTrace) {
    Error.throwWithStackTrace(LanPreviewDecodeException(error), stackTrace);
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

bool lanPreviewImageMetadataWithinBudget(
  int width,
  int height,
  int frameCount,
) {
  if (width <= 0 || height <= 0 || frameCount <= 0) return false;
  if (width > lanPreviewMaxImageSourceDimension ||
      height > lanPreviewMaxImageSourceDimension ||
      frameCount > lanPreviewMaxImageAnimationFrames) {
    return false;
  }
  final pixelsPerFrame = width * height;
  return pixelsPerFrame <= lanPreviewMaxImageSourcePixels &&
      pixelsPerFrame * frameCount <= lanPreviewMaxImageAnimationPixels;
}

ui.Size boundedLanPreviewPixelSize(
  ui.Size source, {
  required double maxWidth,
  required double maxHeight,
  int maxPixels = lanPreviewMaxDecodedImagePixels,
}) {
  if (!source.width.isFinite ||
      !source.height.isFinite ||
      source.width <= 0 ||
      source.height <= 0 ||
      !maxWidth.isFinite ||
      !maxHeight.isFinite ||
      maxWidth <= 0 ||
      maxHeight <= 0 ||
      maxPixels <= 0) {
    return const ui.Size(1, 1);
  }

  final pixelScale = math.sqrt(maxPixels / (source.width * source.height));
  final scale = math.min(
    1,
    math.min(
      maxWidth / source.width,
      math.min(maxHeight / source.height, pixelScale),
    ),
  );
  return ui.Size(
    math.max(1, (source.width * scale).floor()).toDouble(),
    math.max(1, (source.height * scale).floor()).toDouble(),
  );
}

String buildLanPreviewSandboxedHtml(
  String rawHtml, {
  required ui.Brightness brightness,
  required ui.Color backgroundColor,
  required ui.Color foregroundColor,
  required ui.Color linkColor,
  required ui.Color codeBackgroundColor,
}) {
  final colorScheme = brightness == ui.Brightness.dark ? 'dark' : 'light';
  final background = _cssColor(backgroundColor);
  final foreground = _cssColor(foregroundColor);
  final link = _cssColor(linkColor);
  final codeBackground = _cssColor(codeBackgroundColor);
  return '''
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta http-equiv="Content-Security-Policy" content="$lanPreviewHtmlCsp">
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
    img, video, audio, iframe, object, embed { display: none !important; }
  </style>
</head>
<body>
$rawHtml
</body>
</html>
''';
}

/// Only the inert document URL used by WebViewController.loadHtmlString is
/// permitted. Every remote, local-file, data, custom-scheme, or top-level link
/// navigation is rejected by the WebView delegate.
bool lanPreviewNavigationAllowed(String url) {
  return url == 'about:blank' || url.startsWith('about:blank#');
}

String _cssColor(ui.Color color) {
  final rgb = color.toARGB32() & 0x00ffffff;
  return '#${rgb.toRadixString(16).padLeft(6, '0')}';
}
