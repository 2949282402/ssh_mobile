import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 移动端布局自适应工具函数。
///
/// 设计目标：在大屏设备（平板、桌面）上保持标准间距，在小屏手机上
/// 保留系统默认的 text scale（保障无障碍可访问性）并收紧 VisualDensity 来适配。
///
/// isDesktopLayout() 在性能监控等页面用于切换紧凑/展开布局。
/// adaptMobileMediaQuery() + mobileVisualDensityFor() 在 main.dart 的 builder 中
/// 作为 MaterialApp 的全局 Adaptive MediaQuery 注入。
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

double mobileUiScaleForMetrics({
  required Size size,
  required double devicePixelRatio,
}) {
  if (!isMobileTargetPlatform()) return 1.0;

  final physicalShortestSide = size.shortestSide * devicePixelRatio;
  // Android/iOS already normalize layout with dp/pt. This is only a narrow
  // correction for 1.5K-class phones whose OEM density bucket makes app UI
  // visibly larger than 2K-class phones of similar physical size.
  if (physicalShortestSide <= 1240) return 0.82;
  if (physicalShortestSide >= 1440) return 0.92;

  final ratio = (physicalShortestSide - 1240) / (1440 - 1240);
  return 0.82 + ratio * 0.10;
}

double mobileUiScaleFor(MediaQueryData mediaQuery) {
  return mobileUiScaleForMetrics(
    size: mediaQuery.size,
    devicePixelRatio: mediaQuery.devicePixelRatio,
  );
}

double mobileUiScaleOf(BuildContext context) {
  return mobileUiScaleForMetrics(
    size: MediaQuery.sizeOf(context),
    devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
  );
}

MediaQueryData adaptMobileMediaQuery(MediaQueryData mediaQuery) {
  return mediaQuery;
}

VisualDensity mobileVisualDensityFor(MediaQueryData mediaQuery) {
  final uiScale = mobileUiScaleFor(mediaQuery);
  if (uiScale >= 0.999) return VisualDensity.standard;

  final density = ((uiScale - 1.0) * 10).clamp(-1.0, 0.0).toDouble();
  return VisualDensity(horizontal: density, vertical: density);
}

class OpenSettingsNotification extends Notification {
  const OpenSettingsNotification();
}
