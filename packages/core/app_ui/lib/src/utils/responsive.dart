import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 响应式布局断点常量。
class AppBreakpoints {
  static const double compact = 600;
  static const double compactHeight = 480;
  static const double serverGrid = 720;
  static const double desktop = 840;
  static const double wideDesktop = 1280;

  const AppBreakpoints._();
}

/// 窗口尺寸类别定义，用于解耦操作系统平台与实际窗口可用宽度。
enum WindowSizeClass {
  /// 宽度 < 600 dp (手机竖屏、桌面窄窗口)
  compact,

  /// 宽度 600 .. 839 dp (折叠屏、平板竖屏、中等桌面窗口)
  medium,

  /// 宽度 840 .. 1279 dp (平板横屏、常规桌面窗口)
  expanded,

  /// 宽度 >= 1280 dp (大屏桌面工作区)
  large;

  static WindowSizeClass of(BuildContext context) {
    return fromWidth(MediaQuery.sizeOf(context).width);
  }

  static WindowSizeClass fromWidth(double width) {
    if (width < AppBreakpoints.compact) return WindowSizeClass.compact;
    if (width < AppBreakpoints.desktop) return WindowSizeClass.medium;
    if (width < AppBreakpoints.wideDesktop) return WindowSizeClass.expanded;
    return WindowSizeClass.large;
  }

  bool get isCompact => this == WindowSizeClass.compact;
  bool get isMedium => this == WindowSizeClass.medium;
  bool get isExpanded => this == WindowSizeClass.expanded;
  bool get isLarge => this == WindowSizeClass.large;
  bool get isExpandedOrLarger => index >= WindowSizeClass.expanded.index;
  bool get isMediumOrLarger => index >= WindowSizeClass.medium.index;
}

/// 输入交互模式，区分主要依赖鼠标键盘还是触控交互。
enum AppInputMode {
  mouseKeyboard,
  touch;

  static AppInputMode of(BuildContext context) {
    return isDesktopInputPlatform()
        ? AppInputMode.mouseKeyboard
        : AppInputMode.touch;
  }

  bool get isMouseKeyboard => this == AppInputMode.mouseKeyboard;
  bool get isTouch => this == AppInputMode.touch;
}

/// 界面密度模式。
enum AppDensity {
  compact,
  standard,
  comfortable;

  static AppDensity of(BuildContext context) {
    if (isDesktopInputPlatform()) {
      return AppDensity.compact;
    }
    return AppDensity.standard;
  }

  VisualDensity get visualDensity => switch (this) {
    AppDensity.compact => VisualDensity.compact,
    AppDensity.standard => VisualDensity.standard,
    AppDensity.comfortable => VisualDensity.comfortable,
  };
}

/// 移动端与自适应 UI 度量工具。
///
/// 依赖 Flutter 逻辑像素与标准 density，去除了对特定屏幕物理分辨率的补丁计算。
@immutable
class MobileUiMetrics {
  const MobileUiMetrics({
    required this.controlScale,
    required this.chromeScale,
    required this.visualDensity,
  });

  const MobileUiMetrics.desktop()
    : controlScale = 1.0,
      chromeScale = 1.0,
      visualDensity = VisualDensity.standard;

  const MobileUiMetrics.standard()
    : controlScale = 1.0,
      chromeScale = 1.0,
      visualDensity = VisualDensity.standard;

  factory MobileUiMetrics.fromMetrics({
    required Size size,
    required double devicePixelRatio,
    bool? mobileTargetOverride,
  }) {
    final mobileTarget = mobileTargetOverride ?? isMobileTargetPlatform();
    if (!mobileTarget) return const MobileUiMetrics.desktop();

    return const MobileUiMetrics.standard();
  }

  final double controlScale;
  final double chromeScale;
  final VisualDensity visualDensity;

  double get navigationHeight => 56.0 * chromeScale;
  double get navigationHorizontalInset => 0.0;
  double get navigationBottomInset => 0.0;
  double get navigationIconSize => 20.0 * chromeScale;
  double get navigationIndicatorWidth => 44.0 * chromeScale;
  double get navigationIndicatorHeight => 28.0 * chromeScale;
  double get navigationLabelSize => 11.0 * chromeScale;
}

bool supportsServerGridForWidth(double width) {
  return width >= AppBreakpoints.serverGrid;
}

bool usesCompactRailForHeight(double height) {
  return height < AppBreakpoints.compactHeight;
}

bool usesCompactKeyboardLayoutFor({
  required double viewportHeight,
  required double keyboardInset,
}) {
  return keyboardInset > 0 && usesCompactRailForHeight(viewportHeight);
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

/// 判断当前视口是否应呈现展开式工作区布局（宽屏布局）。
///
/// 严格依据可用窗口宽度断点（>= 840dp，即 [WindowSizeClass.expanded] 或 [WindowSizeClass.large]）。
///
/// 注意：该函数仅代表视口宽度能力，不代表当前 OS 平台或输入交互模式。
/// 若需要判断操作系统或输入模式，请使用 [isDesktopTargetPlatform] 或 [isDesktopInputPlatform]。
bool isDesktopLayout(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  return usesExpandedLayoutForWidth(width);
}

/// 判断当前是否为移动端目标平台 (Android / iOS)。
bool isMobileTargetPlatform([TargetPlatform? platform]) {
  if (kIsWeb) return false;
  final target = platform ?? defaultTargetPlatform;
  return target == TargetPlatform.android || target == TargetPlatform.iOS;
}

/// 判断当前是否为桌面端目标平台 (Windows / macOS / Linux)。
bool isDesktopTargetPlatform([TargetPlatform? platform]) {
  if (kIsWeb) return false;
  final target = platform ?? defaultTargetPlatform;
  return target == TargetPlatform.windows ||
      target == TargetPlatform.macOS ||
      target == TargetPlatform.linux;
}

/// 判断当前平台是否为主要使用鼠标/键盘的桌面交互模式。
bool isDesktopInputPlatform([TargetPlatform? platform]) {
  return isDesktopTargetPlatform(platform);
}

/// 判断当前平台是否为主要使用触控手势的移动交互模式。
bool isTouchPlatform([TargetPlatform? platform]) {
  return isMobileTargetPlatform(platform);
}

double mobileUiScaleForMetrics({
  required Size size,
  required double devicePixelRatio,
  bool? mobileTargetOverride,
}) {
  return 1.0;
}

double mobileUiScaleFor(MediaQueryData mediaQuery) {
  return 1.0;
}

double mobileUiScaleOf(BuildContext context) {
  return 1.0;
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
  return VisualDensity.standard;
}

class OpenSettingsNotification extends Notification {
  const OpenSettingsNotification();
}
