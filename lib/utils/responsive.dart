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
  static const double compactHeight = 480;
  static const double serverGrid = 720;
  static const double desktop = 840;
  static const double wideDesktop = 1280;

  const AppBreakpoints._();
}

@immutable
class MobileUiMetrics {
  const MobileUiMetrics({
    required this.controlScale,
    required this.chromeScale,
    required this.visualDensity,
  });

  const MobileUiMetrics.desktop()
    : controlScale = 1,
      chromeScale = 1,
      visualDensity = VisualDensity.standard;

  factory MobileUiMetrics.fromMetrics({
    required Size size,
    required double devicePixelRatio,
    bool? mobileTargetOverride,
  }) {
    final mobileTarget = mobileTargetOverride ?? isMobileTargetPlatform();
    if (!mobileTarget) return const MobileUiMetrics.desktop();

    final physicalShortestSide = size.shortestSide * devicePixelRatio;
    final resolutionProgress = ((physicalShortestSide - 1240) / (1440 - 1240))
        .clamp(0.0, 1.0)
        .toDouble();
    final controlScale = 0.82 + resolutionProgress * 0.10;

    // Logical dp already handles most device differences. Keep this correction
    // deliberately narrow: 1.5K OEM density buckets need slightly tighter app
    // chrome, while 2K-class devices retain the standard Material dimensions.
    final chromeScale = 0.94 + resolutionProgress * 0.06;
    final densityCorrection = -0.5 * (1 - resolutionProgress);

    return MobileUiMetrics(
      controlScale: controlScale,
      chromeScale: chromeScale,
      visualDensity: VisualDensity(
        horizontal: densityCorrection,
        vertical: densityCorrection,
      ),
    );
  }

  final double controlScale;
  final double chromeScale;
  final VisualDensity visualDensity;

  double get navigationHeight => 68 * chromeScale;
  double get navigationHorizontalInset => 10 * chromeScale;
  double get navigationBottomInset => 10 * chromeScale;
  double get navigationIconSize => 21 * chromeScale;
  double get navigationIndicatorWidth => 48 * chromeScale;
  double get navigationIndicatorHeight => 30 * chromeScale;
  double get navigationLabelSize => 10.5 * chromeScale;
}

bool supportsServerGridForWidth(double width) {
  return width >= AppBreakpoints.serverGrid;
}

bool usesCompactRailForHeight(double height) {
  return height < AppBreakpoints.compactHeight;
}

bool usesExpandedLayoutForWidth(double width) {
  return width >= AppBreakpoints.desktop;
}

double settingsDrawerWidthFor({
  required double viewportWidth,
  required bool desktop,
}) {
  final desiredWidth = (viewportWidth * (desktop ? 0.46 : 0.92))
      .clamp(320.0, desktop ? 560.0 : 420.0)
      .toDouble();
  return desiredWidth > viewportWidth ? viewportWidth : desiredWidth;
}

bool isDesktopLayout(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  return usesExpandedLayoutForWidth(width) ||
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
  bool? mobileTargetOverride,
}) {
  return MobileUiMetrics.fromMetrics(
    size: size,
    devicePixelRatio: devicePixelRatio,
    mobileTargetOverride: mobileTargetOverride,
  ).controlScale;
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

MobileUiMetrics mobileUiMetricsFor(MediaQueryData mediaQuery) {
  return MobileUiMetrics.fromMetrics(
    size: mediaQuery.size,
    devicePixelRatio: mediaQuery.devicePixelRatio,
  );
}

MobileUiMetrics mobileUiMetricsOf(BuildContext context) {
  return MobileUiMetrics.fromMetrics(
    size: MediaQuery.sizeOf(context),
    devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
  );
}

MediaQueryData adaptMobileMediaQuery(MediaQueryData mediaQuery) {
  return mediaQuery;
}

VisualDensity mobileVisualDensityFor(MediaQueryData mediaQuery) {
  return mobileUiMetricsFor(mediaQuery).visualDensity;
}

class OpenSettingsNotification extends Notification {
  const OpenSettingsNotification();
}
