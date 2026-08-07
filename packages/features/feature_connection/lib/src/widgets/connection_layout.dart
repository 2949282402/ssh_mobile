import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Connection 页面使用的最小响应式布局能力。
///
/// 当前仍处于 app_ui 建立前的过渡期，因此这里只复制表单需要的布局
/// 计算，不引入 App 层的响应式工具，保证 Feature 可以独立编译。
abstract final class ConnectionBreakpoints {
  static const desktop = 840.0;

  const ConnectionBreakpoints._();
}

@immutable
final class ConnectionMobileUiMetrics {
  const ConnectionMobileUiMetrics({
    required this.controlScale,
    required this.chromeScale,
  });

  const ConnectionMobileUiMetrics.desktop() : controlScale = 1, chromeScale = 1;

  factory ConnectionMobileUiMetrics.fromContext(BuildContext context) {
    final mobileTarget = !_isWeb && _isMobileTargetPlatform();
    if (!mobileTarget) return const ConnectionMobileUiMetrics.desktop();

    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final physicalShortestSide = size.shortestSide * dpr;
    final progress = ((physicalShortestSide - 1240) / (1440 - 1240))
        .clamp(0.0, 1.0)
        .toDouble();
    return ConnectionMobileUiMetrics(
      controlScale: 0.82 + progress * 0.10,
      chromeScale: 0.94 + progress * 0.06,
    );
  }

  final double controlScale;
  final double chromeScale;
}

bool connectionIsDesktopLayout(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  return width >= ConnectionBreakpoints.desktop ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
}

ConnectionMobileUiMetrics connectionMobileUiMetricsOf(BuildContext context) =>
    ConnectionMobileUiMetrics.fromContext(context);

const _isWeb = kIsWeb;

bool _isMobileTargetPlatform() {
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}
