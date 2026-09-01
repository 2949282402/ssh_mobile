import 'package:flutter/material.dart';

import 'app_theme.dart';

/// 统一的 Typography Token 契约，消除各 Feature 中的硬编码文字样式与风格漂移。
@immutable
class AppTypography {
  final TextStyle pageTitle;
  final TextStyle sectionTitle;
  final TextStyle body;
  final TextStyle bodyMedium;
  final TextStyle metadata;
  final TextStyle caption;
  final TextStyle code;
  final TextStyle codeSmall;
  final TextStyle button;

  const AppTypography({
    required this.pageTitle,
    required this.sectionTitle,
    required this.body,
    required this.bodyMedium,
    required this.metadata,
    required this.caption,
    required this.code,
    required this.codeSmall,
    required this.button,
  });

  /// 从当前 BuildContext 构建统一排版样式。
  factory AppTypography.of(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final onSurface = colors.onSurface;
    final onSurfaceVariant = colors.onSurfaceVariant;

    return AppTypography(
      pageTitle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.3,
        height: 1.25,
        color: onSurface,
        fontFamilyFallback: AppTheme.fontFallbacks,
      ),
      sectionTitle: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
        height: 1.35,
        color: onSurface,
        fontFamilyFallback: AppTheme.fontFallbacks,
      ),
      body: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
        height: 1.45,
        color: onSurface,
        fontFamilyFallback: AppTheme.fontFallbacks,
      ),
      bodyMedium: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
        height: 1.4,
        color: onSurface,
        fontFamilyFallback: AppTheme.fontFallbacks,
      ),
      metadata: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
        height: 1.35,
        color: onSurfaceVariant,
        fontFamilyFallback: AppTheme.fontFallbacks,
      ),
      caption: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.1,
        height: 1.3,
        color: onSurfaceVariant,
        fontFamilyFallback: AppTheme.fontFallbacks,
      ),
      code: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
        height: 1.4,
        color: onSurface,
        fontFamilyFallback: AppTheme.monospaceFallback,
      ),
      codeSmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
        height: 1.3,
        color: onSurfaceVariant,
        fontFamilyFallback: AppTheme.monospaceFallback,
      ),
      button: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
        height: 1.2,
        color: onSurface,
        fontFamilyFallback: AppTheme.fontFallbacks,
      ),
    );
  }
}

/// 方便快速访问 Typography Token 的扩展。
extension AppTypographyExtension on BuildContext {
  AppTypography get typography => AppTypography.of(this);
}
