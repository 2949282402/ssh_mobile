part of 'app_theme.dart';

/// 应用支持的主题调色板。
enum AppColorPalette { monochrome, indigo, ocean, emerald, rose, amber }

/// 调色板在当前亮度下的颜色契约。
@immutable
class AppColorPaletteColors {
  const AppColorPaletteColors({
    required this.primary,
    required this.secondary,
    required this.tertiary,
    required this.onPrimary,
  });

  final Color primary;
  final Color secondary;
  final Color tertiary;
  final Color onPrimary;
}

/// 统一的状态颜色 Token，为整个工作区提供一致的语义色彩。
@immutable
class AppStatusColors {
  final Color success;
  final Color warning;
  final Color error;
  final Color info;
  final Color neutral;

  const AppStatusColors({
    required this.success,
    required this.warning,
    required this.error,
    required this.info,
    required this.neutral,
  });

  /// 浅色模式下的标准状态色
  static const light = AppStatusColors(
    success: Color(0xFF10B981), // green
    warning: Color(0xFFF59E0B), // amber
    error: Color(0xFFEF4444), // red
    info: Color(0xFF3B82F6), // blue
    neutral: Color(0xFF6B7280), // gray
  );

  /// 深色模式下的标准状态色
  static const dark = AppStatusColors(
    success: Color(0xFF34D399), // emerald/green
    warning: Color(0xFFFBBF24), // amber
    error: Color(0xFFF87171), // red
    info: Color(0xFF60A5FA), // blue
    neutral: Color(0xFF9CA3AF), // gray
  );

  /// 从当前 BuildContext 解析统一状态色
  static AppStatusColors of(BuildContext context) {
    final theme = Theme.of(context);
    final ext = theme.extension<ExtendedColors>();
    final isDark = theme.brightness == Brightness.dark;
    final base = isDark ? dark : light;

    return AppStatusColors(
      success: ext?.success ?? base.success,
      warning: ext?.warning ?? base.warning,
      error: ext?.error ?? theme.colorScheme.error,
      info: ext?.info ?? base.info,
      neutral: ext?.neutral ?? theme.colorScheme.onSurfaceVariant,
    );
  }
}

/// Material ThemeData 无法直接表达的终端和状态颜色扩展。
class ExtendedColors extends ThemeExtension<ExtendedColors> {
  final Color terminalBg;
  final Color terminalGreen;
  final Color terminalAmber;
  final Color terminalCyan;
  final Color success;
  final Color warning;
  final Color error;
  final Color info;
  final Color neutral;
  final Color glassBg;
  final Color glassBorder;
  final Color cardHoverBorder;

  const ExtendedColors({
    required this.terminalBg,
    required this.terminalGreen,
    required this.terminalAmber,
    required this.terminalCyan,
    required this.success,
    required this.warning,
    this.error = const Color(0xFFEF4444),
    this.info = const Color(0xFF3B82F6),
    this.neutral = const Color(0xFF6B7280),
    required this.glassBg,
    required this.glassBorder,
    required this.cardHoverBorder,
  });

  @override
  ExtendedColors copyWith({
    Color? terminalBg,
    Color? terminalGreen,
    Color? terminalAmber,
    Color? terminalCyan,
    Color? success,
    Color? warning,
    Color? error,
    Color? info,
    Color? neutral,
    Color? glassBg,
    Color? glassBorder,
    Color? cardHoverBorder,
  }) {
    return ExtendedColors(
      terminalBg: terminalBg ?? this.terminalBg,
      terminalGreen: terminalGreen ?? this.terminalGreen,
      terminalAmber: terminalAmber ?? this.terminalAmber,
      terminalCyan: terminalCyan ?? this.terminalCyan,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      error: error ?? this.error,
      info: info ?? this.info,
      neutral: neutral ?? this.neutral,
      glassBg: glassBg ?? this.glassBg,
      glassBorder: glassBorder ?? this.glassBorder,
      cardHoverBorder: cardHoverBorder ?? this.cardHoverBorder,
    );
  }

  @override
  ExtendedColors lerp(ThemeExtension<ExtendedColors>? other, double t) {
    if (other is! ExtendedColors) return this;
    return ExtendedColors(
      terminalBg: Color.lerp(terminalBg, other.terminalBg, t)!,
      terminalGreen: Color.lerp(terminalGreen, other.terminalGreen, t)!,
      terminalAmber: Color.lerp(terminalAmber, other.terminalAmber, t)!,
      terminalCyan: Color.lerp(terminalCyan, other.terminalCyan, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      error: Color.lerp(error, other.error, t)!,
      info: Color.lerp(info, other.info, t)!,
      neutral: Color.lerp(neutral, other.neutral, t)!,
      glassBg: Color.lerp(glassBg, other.glassBg, t)!,
      glassBorder: Color.lerp(glassBorder, other.glassBorder, t)!,
      cardHoverBorder: Color.lerp(cardHoverBorder, other.cardHoverBorder, t)!,
    );
  }
}
