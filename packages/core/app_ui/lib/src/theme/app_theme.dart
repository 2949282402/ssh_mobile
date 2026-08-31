// 全局视觉主题定义。
//
// 本文件保留 AppTheme 的稳定公共 API；主题构建仍由应用统一选择，
// app_ui 不保存运行时状态，也不创建任何外部资源。
// ignore: unnecessary_import
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:animations/animations.dart';

part 'app_theme_extensions.dart';
part 'app_theme_components.dart';
part 'app_theme_variants.dart';

/// 提供浅色、深色和调色板主题，以及跨 Feature 使用的视觉常量。
class AppTheme {
  static const radiusXs = 4.0;
  static const radiusSmall = 6.0;
  static const radiusMedium = 8.0;
  static const radiusLarge = 12.0;
  static const radiusDialog = 16.0;
  static const radiusPill = 999.0;

  static const space2 = 2.0;
  static const space4 = 4.0;
  static const space8 = 8.0;
  static const space12 = 12.0;
  static const space16 = 16.0;
  static const space20 = 20.0;
  static const space24 = 24.0;
  static const space32 = 32.0;

  static const pagePadding = 20.0;
  static const compactPagePadding = 12.0;

  // 终端配色静态常量，用于保持与其他已有组件的向后兼容性
  static const terminalBg = Color(0xFF0F172A);
  static const terminalGreen = Color(0xFF10B981);
  static const terminalAmber = Color(0xFFF59E0B);
  static const terminalCyan = Color(0xFF06B6D4);

  static const fontFallbacks = [
    'Microsoft YaHei',
    'PingFang SC',
    'Heiti SC',
    'DengXian',
    'SimSun',
    'sans-serif',
  ];

  static const monospaceFallback = [
    'Consolas',
    'Courier New',
    'Microsoft YaHei Mono',
    'Microsoft YaHei',
    'PingFang SC',
    'monospace',
  ];

  /// 构建应用浅色主题并应用指定调色板。
  static ThemeData lightThemeFor({
    AppColorPalette palette = AppColorPalette.monochrome,
  }) => _applyFont(_applyColorPalette(lightTheme, palette));

  /// 构建应用深色主题并应用指定调色板。
  static ThemeData darkThemeFor({
    bool oledDark = false,
    AppColorPalette palette = AppColorPalette.monochrome,
  }) => _applyFont(
    _applyColorPalette(buildDarkTheme(oledDark: oledDark), palette),
  );

  /// 返回调色板在指定亮度下的 Material 颜色。
  static AppColorPaletteColors paletteColors(
    AppColorPalette palette,
    Brightness brightness,
  ) {
    final dark = brightness == Brightness.dark;
    return switch (palette) {
      AppColorPalette.monochrome => AppColorPaletteColors(
        primary: dark ? const Color(0xFFE8EAED) : const Color(0xFF202124),
        secondary: dark ? const Color(0xFFBDC1C6) : const Color(0xFF5F6368),
        tertiary: dark ? const Color(0xFF9AA0A6) : const Color(0xFF3C4043),
        onPrimary: dark ? const Color(0xFF202124) : Colors.white,
      ),
      AppColorPalette.indigo => AppColorPaletteColors(
        primary: dark ? const Color(0xFF8B87FF) : const Color(0xFF4F46E5),
        secondary: dark ? const Color(0xFF48CFB5) : const Color(0xFF0F9F87),
        tertiary: dark ? const Color(0xFFC4B5FD) : const Color(0xFF7C3AED),
        onPrimary: dark ? const Color(0xFF11102E) : Colors.white,
      ),
      AppColorPalette.ocean => AppColorPaletteColors(
        primary: dark ? const Color(0xFF38BDF8) : const Color(0xFF0369A1),
        secondary: dark ? const Color(0xFF22D3EE) : const Color(0xFF0891B2),
        tertiary: dark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
        onPrimary: dark ? const Color(0xFF082F49) : Colors.white,
      ),
      AppColorPalette.emerald => AppColorPaletteColors(
        primary: dark ? const Color(0xFF34D399) : const Color(0xFF047857),
        secondary: dark ? const Color(0xFF2DD4BF) : const Color(0xFF0F766E),
        tertiary: dark ? const Color(0xFFA3E635) : const Color(0xFF65A30D),
        onPrimary: dark ? const Color(0xFF052E24) : Colors.white,
      ),
      AppColorPalette.rose => AppColorPaletteColors(
        primary: dark ? const Color(0xFFFB7185) : const Color(0xFFBE123C),
        secondary: dark ? const Color(0xFFE879F9) : const Color(0xFFC026D3),
        tertiary: dark ? const Color(0xFFC4B5FD) : const Color(0xFF7C3AED),
        onPrimary: dark ? const Color(0xFF4C0519) : Colors.white,
      ),
      AppColorPalette.amber => AppColorPaletteColors(
        primary: dark ? const Color(0xFFFBBF24) : const Color(0xFFB45309),
        secondary: dark ? const Color(0xFFFACC15) : const Color(0xFFCA8A04),
        tertiary: dark ? const Color(0xFFFB923C) : const Color(0xFFEA580C),
        onPrimary: dark ? const Color(0xFF3A2500) : Colors.white,
      ),
    };
  }

  static ThemeData _applyColorPalette(
    ThemeData theme,
    AppColorPalette palette,
  ) {
    final colors = paletteColors(palette, theme.brightness);
    final surface = theme.colorScheme.surface;
    Color container(Color color) => Color.alphaBlend(
      color.withValues(
        alpha: theme.brightness == Brightness.dark ? 0.24 : 0.12,
      ),
      surface,
    );
    Color foreground(Color color) =>
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : const Color(0xFF202124);
    final scheme = theme.colorScheme.copyWith(
      primary: colors.primary,
      onPrimary: colors.onPrimary,
      primaryContainer: container(colors.primary),
      onPrimaryContainer: foreground(container(colors.primary)),
      secondary: colors.secondary,
      onSecondary: foreground(colors.secondary),
      secondaryContainer: container(colors.secondary),
      onSecondaryContainer: foreground(container(colors.secondary)),
      tertiary: colors.tertiary,
      onTertiary: foreground(colors.tertiary),
      tertiaryContainer: container(colors.tertiary),
      onTertiaryContainer: foreground(container(colors.tertiary)),
      inversePrimary: colors.primary,
      surfaceTint: colors.primary,
    );
    final extended = theme.extension<ExtendedColors>();
    return theme.copyWith(
      colorScheme: scheme,
      extensions: [
        if (extended != null)
          extended.copyWith(
            success: colors.secondary,
            cardHoverBorder: colors.primary.withValues(alpha: 0.4),
          ),
      ],
      navigationBarTheme: _AppThemeComponentBuilders._navigationBarTheme(
        surface: scheme.surface,
        primary: colors.primary,
        onSurfaceVariant: scheme.onSurfaceVariant,
      ),
      navigationRailTheme: _AppThemeComponentBuilders._navigationRailTheme(
        surface: scheme.surface,
        primary: colors.primary,
        onSurfaceVariant: scheme.onSurfaceVariant,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colors.primary,
        foregroundColor: colors.onPrimary,
        elevation: 0,
        focusElevation: 1,
        hoverElevation: 1,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(radiusSmall)),
        ),
      ),
      textButtonTheme: _AppThemeComponentBuilders._textButtonTheme(
        colors.primary,
      ),
      chipTheme: _AppThemeComponentBuilders._chipTheme(
        background: scheme.surfaceContainer,
        selected: Color.alphaBlend(
          colors.primary.withValues(alpha: 0.14),
          scheme.surfaceContainer,
        ),
        outline: scheme.outline,
        label: scheme.onSurface,
      ),
      inputDecorationTheme: _AppThemeComponentBuilders._inputDecorationTheme(
        fill: scheme.surface,
        outline: scheme.outline,
        focused: colors.primary,
        label: scheme.onSurfaceVariant,
      ),
      segmentedButtonTheme: _AppThemeComponentBuilders._segmentedButtonTheme(
        primary: colors.primary,
        outline: scheme.outline,
        surface: scheme.surface,
        foreground: scheme.onSurface,
      ),
      progressIndicatorTheme:
          _AppThemeComponentBuilders._progressIndicatorTheme(
            primary: colors.primary,
            track: scheme.outline,
          ),
    );
  }

  static ThemeData _applyFont(ThemeData theme) {
    return theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamilyFallback: fontFallbacks),
      primaryTextTheme: theme.primaryTextTheme.apply(
        fontFamilyFallback: fontFallbacks,
      ),
    );
  }

  static final lightTheme = _AppThemeThemeVariants.lightTheme;

  /// 构建深色主题；具体控件配置由主题变体构建器负责。
  static ThemeData buildDarkTheme({bool oledDark = false}) =>
      _AppThemeThemeVariants.buildDarkTheme(oledDark: oledDark);
}
