import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class AppBreakpoints {
  static const double desktop = 900;
  static const double wideDesktop = 1280;

  const AppBreakpoints._();
}

bool isDesktopLayout(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  return width >= AppBreakpoints.desktop ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
}

bool isMobileTargetPlatform() {
  return !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
}

double mobileUiScaleFor(MediaQueryData mediaQuery) {
  if (!isMobileTargetPlatform()) return 1.0;

  final physicalShortestSide =
      mediaQuery.size.shortestSide * mediaQuery.devicePixelRatio;
  // Android/iOS already normalize layout with dp/pt. This is only a narrow
  // correction for 1.5K-class phones whose OEM density bucket makes app UI
  // visibly larger than 2K-class phones of similar physical size.
  if (physicalShortestSide <= 1240) return 0.88;
  if (physicalShortestSide >= 1440) return 1.0;

  final ratio = (physicalShortestSide - 1240) / (1440 - 1240);
  return 0.88 + ratio * 0.12;
}

MediaQueryData adaptMobileMediaQuery(MediaQueryData mediaQuery) {
  final uiScale = mobileUiScaleFor(mediaQuery);
  if (uiScale >= 0.999) return mediaQuery;

  final currentTextScale = mediaQuery.textScaler.scale(1);
  final adaptedTextScale = (currentTextScale * uiScale).clamp(0.9, 1.6);
  return mediaQuery.copyWith(
    textScaler: TextScaler.linear(adaptedTextScale.toDouble()),
  );
}

VisualDensity mobileVisualDensityFor(MediaQueryData mediaQuery) {
  final uiScale = mobileUiScaleFor(mediaQuery);
  if (uiScale >= 0.999) return VisualDensity.standard;

  final density = ((uiScale - 1.0) * 10).clamp(-1.0, 0.0).toDouble();
  return VisualDensity(horizontal: density, vertical: density);
}
