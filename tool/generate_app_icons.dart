import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as image;

void main() {
  final targets = <String, (String, int)>{
    'assets/app_icon_1024.png': ('default', 1024),
    'android/app/src/main/res/mipmap-mdpi/ic_launcher.png': ('android', 48),
    'android/app/src/main/res/mipmap-hdpi/ic_launcher.png': ('android', 72),
    'android/app/src/main/res/mipmap-xhdpi/ic_launcher.png': ('android', 96),
    'android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png': ('android', 144),
    'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png': ('android', 192),
    'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@1x.png': (
      'ios',
      20,
    ),
    'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@2x.png': (
      'ios',
      40,
    ),
    'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@3x.png': (
      'ios',
      60,
    ),
    'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@1x.png': (
      'ios',
      29,
    ),
    'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@2x.png': (
      'ios',
      58,
    ),
    'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@3x.png': (
      'ios',
      87,
    ),
    'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@1x.png': (
      'ios',
      40,
    ),
    'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@2x.png': (
      'ios',
      80,
    ),
    'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@3x.png': (
      'ios',
      120,
    ),
    'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@2x.png': (
      'ios',
      120,
    ),
    'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@3x.png': (
      'ios',
      180,
    ),
    'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@1x.png': (
      'ios',
      76,
    ),
    'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@2x.png': (
      'ios',
      152,
    ),
    'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-83.5x83.5@2x.png': (
      'ios',
      167,
    ),
    'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png': (
      'ios',
      1024,
    ),
    'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_16.png': (
      'macos',
      16,
    ),
    'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_32.png': (
      'macos',
      32,
    ),
    'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_64.png': (
      'macos',
      64,
    ),
    'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png': (
      'macos',
      128,
    ),
    'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png': (
      'macos',
      256,
    ),
    'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png': (
      'macos',
      512,
    ),
    'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png': (
      'macos',
      1024,
    ),
    'web/favicon.png': ('default', 32),
    'web/icons/Icon-192.png': ('default', 192),
    'web/icons/Icon-512.png': ('default', 512),
    'web/icons/Icon-maskable-192.png': ('default', 192),
    'web/icons/Icon-maskable-512.png': ('default', 512),
  };

  final sources = <String, image.Image>{
    'default': _buildIcon('default'),
    'android': _buildIcon('android'),
    'ios': _buildIcon('ios'),
    'macos': _buildIcon('macos'),
    'windows': _buildIcon('windows'),
  };

  for (final entry in targets.entries) {
    final platform = entry.value.$1;
    final size = entry.value.$2;
    final source = sources[platform]!;
    final resized = size == source.width
        ? source
        : image.copyResize(
            source,
            width: size,
            height: size,
            interpolation: image.Interpolation.cubic,
          );
    _write(entry.key, image.encodePng(resized));
  }

  final windowsIcon = image.copyResize(
    sources['windows']!,
    width: 256,
    height: 256,
    interpolation: image.Interpolation.cubic,
  );
  _write(
    'windows/runner/resources/app_icon.ico',
    image.encodeIco(windowsIcon, singleFrame: true),
  );

  stdout.writeln('Generated ${targets.length} PNG icons and one ICO icon.');
}

image.Image _buildIcon(String platform) {
  const scale = 2;
  const size = 1024 * scale;
  final canvas = image.Image(width: size, height: size);

  final image.Color background;
  final image.Color panel;
  final image.Color prompt;
  final image.Color cursor;
  final image.Color online = image.ColorRgb8(74, 222, 128);

  if (platform == 'android') {
    // Android: Green Theme (Teal/Lime/Green style)
    background = image.ColorRgb8(11, 24, 16);
    panel = image.ColorRgb8(24, 48, 33);
    prompt = image.ColorRgb8(163, 230, 53);
    cursor = image.ColorRgb8(34, 197, 94);
  } else if (platform == 'ios') {
    // iOS: Indigo / Rose Gradient Theme
    background = image.ColorRgb8(24, 18, 36);
    panel = image.ColorRgb8(45, 34, 71);
    prompt = image.ColorRgb8(244, 63, 94);
    cursor = image.ColorRgb8(139, 92, 246);
  } else if (platform == 'macos') {
    // macOS: Charcoal Grey / Silver Accent Theme
    background = image.ColorRgb8(20, 20, 23);
    panel = image.ColorRgb8(40, 40, 44);
    prompt = image.ColorRgb8(245, 245, 247);
    cursor = image.ColorRgb8(161, 161, 170);
  } else {
    // Windows / Default: Deep Blue / Cyan Theme
    background = image.ColorRgb8(7, 17, 31);
    panel = image.ColorRgb8(15, 39, 66);
    prompt = image.ColorRgb8(56, 189, 248);
    cursor = image.ColorRgb8(45, 212, 191);
  }

  image.fillRect(
    canvas,
    x1: 0,
    y1: 0,
    x2: size - 1,
    y2: size - 1,
    color: background,
  );
  image.fillRect(
    canvas,
    x1: 56 * scale,
    y1: 56 * scale,
    x2: 968 * scale,
    y2: 968 * scale,
    radius: 220 * scale,
    color: panel,
  );

  _roundedLine(
    canvas,
    260 * scale,
    320 * scale,
    480 * scale,
    512 * scale,
    prompt,
    96 * scale,
  );
  _roundedLine(
    canvas,
    480 * scale,
    512 * scale,
    260 * scale,
    704 * scale,
    prompt,
    96 * scale,
  );
  _roundedLine(
    canvas,
    560 * scale,
    690 * scale,
    790 * scale,
    690 * scale,
    cursor,
    82 * scale,
  );

  image.fillCircle(
    canvas,
    x: 780 * scale,
    y: 270 * scale,
    radius: 74 * scale,
    color: background,
    antialias: true,
  );
  image.fillCircle(
    canvas,
    x: 780 * scale,
    y: 270 * scale,
    radius: 52 * scale,
    color: online,
    antialias: true,
  );
  return image.copyResize(
    canvas,
    width: 1024,
    height: 1024,
    interpolation: image.Interpolation.cubic,
  );
}

void _roundedLine(
  image.Image canvas,
  int x1,
  int y1,
  int x2,
  int y2,
  image.Color color,
  int thickness,
) {
  final radius = thickness / 2;
  final dx = x2 - x1;
  final dy = y2 - y1;
  final length = math.sqrt((dx * dx) + (dy * dy));
  final offsetX = (-dy / length) * radius;
  final offsetY = (dx / length) * radius;

  image.fillPolygon(
    canvas,
    vertices: [
      image.Point(x1 + offsetX, y1 + offsetY),
      image.Point(x2 + offsetX, y2 + offsetY),
      image.Point(x2 - offsetX, y2 - offsetY),
      image.Point(x1 - offsetX, y1 - offsetY),
    ],
    color: color,
  );
  image.fillCircle(canvas, x: x1, y: y1, radius: radius.round(), color: color);
  image.fillCircle(canvas, x: x2, y: y2, radius: radius.round(), color: color);
}

void _write(String path, List<int> bytes) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
}
