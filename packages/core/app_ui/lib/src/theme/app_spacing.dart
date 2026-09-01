import 'package:flutter/material.dart';

/// 统一的 Spacing Token 契约，消除魔法数字与布局漂移。
@immutable
class AppSpacing {
  static const double spacingXs = 4.0;
  static const double spacingSm = 8.0;
  static const double spacingMd = 12.0;
  static const double spacingLg = 16.0;
  static const double spacingXl = 24.0;
  static const double spacing2Xl = 32.0;

  // 别名支持
  static const double xs = spacingXs;
  static const double sm = spacingSm;
  static const double md = spacingMd;
  static const double lg = spacingLg;
  static const double xl = spacingXl;
  static const double xxl = spacing2Xl;

  // 内边距常用预设
  static const EdgeInsets insetsNone = EdgeInsets.zero;
  static const EdgeInsets insetsXs = EdgeInsets.all(spacingXs);
  static const EdgeInsets insetsSm = EdgeInsets.all(spacingSm);
  static const EdgeInsets insetsMd = EdgeInsets.all(spacingMd);
  static const EdgeInsets insetsLg = EdgeInsets.all(spacingLg);
  static const EdgeInsets insetsXl = EdgeInsets.all(spacingXl);
  static const EdgeInsets insets2Xl = EdgeInsets.all(spacing2Xl);

  static const EdgeInsets insetsHSm = EdgeInsets.symmetric(
    horizontal: spacingSm,
  );
  static const EdgeInsets insetsHMd = EdgeInsets.symmetric(
    horizontal: spacingMd,
  );
  static const EdgeInsets insetsHLg = EdgeInsets.symmetric(
    horizontal: spacingLg,
  );

  static const EdgeInsets insetsVSm = EdgeInsets.symmetric(vertical: spacingSm);
  static const EdgeInsets insetsVMd = EdgeInsets.symmetric(vertical: spacingMd);
  static const EdgeInsets insetsVLg = EdgeInsets.symmetric(vertical: spacingLg);

  // 垂直间隙预设
  static const Widget vGapXs = SizedBox(height: spacingXs);
  static const Widget vGapSm = SizedBox(height: spacingSm);
  static const Widget vGapMd = SizedBox(height: spacingMd);
  static const Widget vGapLg = SizedBox(height: spacingLg);
  static const Widget vGapXl = SizedBox(height: spacingXl);
  static const Widget vGap2Xl = SizedBox(height: spacing2Xl);

  // 水平间隙预设
  static const Widget hGapXs = SizedBox(width: spacingXs);
  static const Widget hGapSm = SizedBox(width: spacingSm);
  static const Widget hGapMd = SizedBox(width: spacingMd);
  static const Widget hGapLg = SizedBox(width: spacingLg);
  static const Widget hGapXl = SizedBox(width: spacingXl);
  static const Widget hGap2Xl = SizedBox(width: spacing2Xl);

  const AppSpacing._();
}

/// 实例型 Spacing 访问对象，供 `context.spacing.md` 等方式访问。
@immutable
class AppSpacingTokens {
  const AppSpacingTokens();

  double get xs => AppSpacing.xs;
  double get sm => AppSpacing.sm;
  double get md => AppSpacing.md;
  double get lg => AppSpacing.lg;
  double get xl => AppSpacing.xl;
  double get xxl => AppSpacing.xxl;

  double get spacingXs => AppSpacing.spacingXs;
  double get spacingSm => AppSpacing.spacingSm;
  double get spacingMd => AppSpacing.spacingMd;
  double get spacingLg => AppSpacing.spacingLg;
  double get spacingXl => AppSpacing.spacingXl;
  double get spacing2Xl => AppSpacing.spacing2Xl;
}

/// 方便快速访问 Spacing Token 的扩展。
extension AppSpacingExtension on BuildContext {
  AppSpacingTokens get spacing => const AppSpacingTokens();
}
