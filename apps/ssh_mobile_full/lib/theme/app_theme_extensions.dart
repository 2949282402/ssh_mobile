part of 'app_theme.dart';

enum AppColorPalette { monochrome, indigo, ocean, emerald, rose, amber }

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

class ExtendedColors extends ThemeExtension<ExtendedColors> {
  final Color terminalBg;
  final Color terminalGreen;
  final Color terminalAmber;
  final Color terminalCyan;
  final Color success;
  final Color warning;
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
      glassBg: Color.lerp(glassBg, other.glassBg, t)!,
      glassBorder: Color.lerp(glassBorder, other.glassBorder, t)!,
      cardHoverBorder: Color.lerp(cardHoverBorder, other.cardHoverBorder, t)!,
    );
  }
}
