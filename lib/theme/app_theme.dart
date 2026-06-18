import 'package:flutter/material.dart';
import 'package:animations/animations.dart';

class ExtendedColors extends ThemeExtension<ExtendedColors> {
  final Color terminalBg;
  final Color terminalGreen;
  final Color terminalAmber;
  final Color terminalCyan;
  final Color success;
  final Color warning;

  const ExtendedColors({
    required this.terminalBg,
    required this.terminalGreen,
    required this.terminalAmber,
    required this.terminalCyan,
    required this.success,
    required this.warning,
  });

  @override
  ExtendedColors copyWith({
    Color? terminalBg,
    Color? terminalGreen,
    Color? terminalAmber,
    Color? terminalCyan,
    Color? success,
    Color? warning,
  }) {
    return ExtendedColors(
      terminalBg: terminalBg ?? this.terminalBg,
      terminalGreen: terminalGreen ?? this.terminalGreen,
      terminalAmber: terminalAmber ?? this.terminalAmber,
      terminalCyan: terminalCyan ?? this.terminalCyan,
      success: success ?? this.success,
      warning: warning ?? this.warning,
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
    );
  }
}

class AppTheme {
  static const radiusSmall = 10.0;
  static const radiusMedium = 16.0;
  static const radiusLarge = 24.0;

  // 终端配色静态常量，用于保持与其他已有组件的向后兼容性
  static const terminalBg = Color(0xFF0F172A);
  static const terminalGreen = Color(0xFF10B981);
  static const terminalAmber = Color(0xFFF59E0B);
  static const terminalCyan = Color(0xFF06B6D4);

  static ThemeData lightThemeFor(String? fontFamily) => _applyFont(lightTheme, fontFamily);
  static ThemeData darkThemeFor(String? fontFamily) => _applyFont(darkTheme, fontFamily);

  static ThemeData _applyFont(ThemeData theme, String? fontFamily) {
    final family = fontFamily?.trim();
    if (family == null || family.isEmpty) return theme;
    return theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: family),
      primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: family),
    );
  }

  static final lightTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: const Color(0xFFF8FAFC),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeThroughPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: FadeThroughPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeThroughPageTransitionsBuilder(),
        TargetPlatform.linux: FadeThroughPageTransitionsBuilder(),
      },
    ),
    colorScheme: const ColorScheme.light(
      primary: Color(0xFF2563EB),
      secondary: Color(0xFF0F766E),
      tertiary: Color(0xFF7C3AED),
      surface: Color(0xFFFFFFFF),
      surfaceContainer: Color(0xFFF1F5F9),
      surfaceContainerHighest: Color(0xFFE2E8F0),
      outline: Color(0xFFE2E8F0),
      outlineVariant: Color(0xFFCBD5E1),
      error: Color(0xFFDC2626),
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onTertiary: Colors.white,
      onSurface: Color(0xFF0F172A),
      onSurfaceVariant: Color(0xFF64748B),
      onError: Colors.white,
    ),
    extensions: const [
      ExtendedColors(
        terminalBg: Color(0xFF0F172A),
        terminalGreen: Color(0xFF10B981),
        terminalAmber: Color(0xFFF59E0B),
        terminalCyan: Color(0xFF06B6D4),
        success: Color(0xFF10B981),
        warning: Color(0xFFF59E0B),
      ),
    ],
    textTheme: _textTheme(const Color(0xFF0F172A)),
    appBarTheme: _appBarTheme(background: const Color(0xFFF8FAFC), foreground: const Color(0xFF0F172A)),
    cardTheme: _cardTheme(surface: Colors.white, outline: const Color(0xFFE2E8F0)),
    navigationBarTheme: _navigationBarTheme(surface: const Color(0xFFFFFFFF), primary: const Color(0xFF2563EB), onSurfaceVariant: const Color(0xFF64748B)),
    navigationRailTheme: _navigationRailTheme(surface: const Color(0xFFFFFFFF), primary: const Color(0xFF2563EB), onSurfaceVariant: const Color(0xFF64748B)),
    listTileTheme: _listTileTheme(iconColor: const Color(0xFF64748B), textColor: const Color(0xFF0F172A)),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Color(0xFF2563EB),
      foregroundColor: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(radiusSmall))),
    ),
    filledButtonTheme: _filledButtonTheme(),
    outlinedButtonTheme: _outlinedButtonTheme(const Color(0xFFE2E8F0)),
    textButtonTheme: _textButtonTheme(const Color(0xFF2563EB)),
    iconButtonTheme: _iconButtonTheme(const Color(0xFF334155)),
    chipTheme: _chipTheme(background: const Color(0xFFF1F5F9), selected: const Color(0xFFDBEAFE), outline: const Color(0xFFE2E8F0), label: const Color(0xFF334155)),
    inputDecorationTheme: _inputDecorationTheme(fill: const Color(0xFFF8FAFC), outline: const Color(0xFFE2E8F0), focused: const Color(0xFF2563EB), label: const Color(0xFF64748B)),
    snackBarTheme: _snackBarTheme(background: const Color(0xFF0F172A), foreground: Colors.white),
    dialogTheme: _dialogTheme(Colors.white),
    popupMenuTheme: _popupMenuTheme(Colors.white),
    drawerTheme: _drawerTheme(Colors.white, const Color(0xFFE2E8F0)),
    bottomSheetTheme: _bottomSheetTheme(background: Colors.white, outline: const Color(0xFFE2E8F0)),
    segmentedButtonTheme: _segmentedButtonTheme(primary: const Color(0xFF2563EB), outline: const Color(0xFFE2E8F0), surface: Colors.white, foreground: const Color(0xFF334155)),
    expansionTileTheme: _expansionTileTheme(foreground: const Color(0xFF0F172A), muted: const Color(0xFF64748B)),
    progressIndicatorTheme: _progressIndicatorTheme(primary: const Color(0xFF2563EB), track: const Color(0xFFE2E8F0)),
    scrollbarTheme: _scrollbarTheme(thumb: const Color(0xFF94A3B8), track: const Color(0xFFE2E8F0)),
    dividerTheme: const DividerThemeData(color: Color(0xFFE2E8F0), thickness: 1, space: 1),
  );

  static final darkTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xFF030712),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeThroughPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: FadeThroughPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeThroughPageTransitionsBuilder(),
        TargetPlatform.linux: FadeThroughPageTransitionsBuilder(),
      },
    ),
    colorScheme: const ColorScheme.dark(
      primary: Color(0xFF3B82F6),
      secondary: Color(0xFF14B8A6),
      tertiary: Color(0xFFA78BFA),
      surface: Color(0xFF0B0F19),
      surfaceContainer: Color(0xFF111827),
      surfaceContainerHighest: Color(0xFF1F2937),
      outline: Color(0xFF1F2937),
      outlineVariant: Color(0xFF374151),
      error: Color(0xFFF87171),
      onPrimary: Color(0xFF030712),
      onSecondary: Color(0xFF030712),
      onTertiary: Color(0xFF030712),
      onSurface: Color(0xFFF9FAFB),
      onSurfaceVariant: Color(0xFF94A3B8),
      onError: Color(0xFF190A0A),
    ),
    extensions: const [
      ExtendedColors(
        terminalBg: Color(0xFF030712),
        terminalGreen: Color(0xFF34D399),
        terminalAmber: Color(0xFFFBBF24),
        terminalCyan: Color(0xFF22D3EE),
        success: Color(0xFF34D399),
        warning: Color(0xFFFBBF24),
      ),
    ],
    textTheme: _textTheme(const Color(0xFFF9FAFB)),
    appBarTheme: _appBarTheme(background: const Color(0xFF030712), foreground: const Color(0xFFF9FAFB)),
    cardTheme: _cardTheme(surface: const Color(0xFF0B0F19), outline: const Color(0xFF1F2937)),
    navigationBarTheme: _navigationBarTheme(surface: const Color(0xFF0B0F19), primary: const Color(0xFF3B82F6), onSurfaceVariant: const Color(0xFF94A3B8)),
    navigationRailTheme: _navigationRailTheme(surface: const Color(0xFF0B0F19), primary: const Color(0xFF3B82F6), onSurfaceVariant: const Color(0xFF94A3B8)),
    listTileTheme: _listTileTheme(iconColor: const Color(0xFF94A3B8), textColor: const Color(0xFFF9FAFB)),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Color(0xFF3B82F6),
      foregroundColor: Color(0xFF030712),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(radiusSmall))),
    ),
    filledButtonTheme: _filledButtonTheme(),
    outlinedButtonTheme: _outlinedButtonTheme(const Color(0xFF1F2937)),
    textButtonTheme: _textButtonTheme(const Color(0xFF3B82F6)),
    iconButtonTheme: _iconButtonTheme(const Color(0xFFCBD5E1)),
    chipTheme: _chipTheme(background: const Color(0xFF111827), selected: const Color(0xFF1F2937), outline: const Color(0xFF1F2937), label: const Color(0xFFF9FAFB)),
    inputDecorationTheme: _inputDecorationTheme(fill: const Color(0xFF0B0F19), outline: const Color(0xFF1F2937), focused: const Color(0xFF3B82F6), label: const Color(0xFF94A3B8)),
    snackBarTheme: _snackBarTheme(background: const Color(0xFFF9FAFB), foreground: const Color(0xFF0B0F19)),
    dialogTheme: _dialogTheme(const Color(0xFF0B0F19)),
    popupMenuTheme: _popupMenuTheme(const Color(0xFF0B0F19)),
    drawerTheme: _drawerTheme(const Color(0xFF0B0F19), const Color(0xFF1F2937)),
    bottomSheetTheme: _bottomSheetTheme(background: const Color(0xFF0B0F19), outline: const Color(0xFF1F2937)),
    segmentedButtonTheme: _segmentedButtonTheme(primary: const Color(0xFF3B82F6), outline: const Color(0xFF1F2937), surface: const Color(0xFF0B0F19), foreground: const Color(0xFFF9FAFB)),
    expansionTileTheme: _expansionTileTheme(foreground: const Color(0xFFF9FAFB), muted: const Color(0xFF94A3B8)),
    progressIndicatorTheme: _progressIndicatorTheme(primary: const Color(0xFF3B82F6), track: const Color(0xFF1F2937)),
    scrollbarTheme: _scrollbarTheme(thumb: const Color(0xFF64748B), track: const Color(0xFF1F2937)),
    dividerTheme: const DividerThemeData(color: Color(0xFF1F2937), thickness: 1, space: 1),
  );

  static TextTheme _textTheme(Color color) {
    return TextTheme(
      titleLarge: TextStyle(color: color, fontWeight: FontWeight.w700, letterSpacing: -0.5),
      titleMedium: TextStyle(color: color, fontWeight: FontWeight.w600, letterSpacing: -0.2),
      bodyMedium: TextStyle(color: color, letterSpacing: 0, height: 1.4),
      labelLarge: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0),
    );
  }

  static AppBarTheme _appBarTheme({required Color background, required Color foreground}) {
    return AppBarTheme(
      backgroundColor: background,
      foregroundColor: foreground,
      elevation: 0,
      centerTitle: false,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      titleTextStyle: TextStyle(color: foreground, fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.5),
    );
  }

  static CardThemeData _cardTheme({required Color surface, required Color outline}) {
    return CardThemeData(
      color: surface,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusMedium),
        side: BorderSide(color: outline, width: 1),
      ),
    );
  }

  static NavigationBarThemeData _navigationBarTheme({required Color surface, required Color primary, required Color onSurfaceVariant}) {
    return NavigationBarThemeData(
      backgroundColor: surface,
      indicatorColor: primary.withValues(alpha: 0.08),
      elevation: 0,
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
        color: states.contains(WidgetState.selected) ? primary : onSurfaceVariant,
        fontSize: 12,
        fontWeight: states.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
        letterSpacing: 0,
      )),
      iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
        color: states.contains(WidgetState.selected) ? primary : onSurfaceVariant,
        size: 22,
      )),
    );
  }

  static NavigationRailThemeData _navigationRailTheme({required Color surface, required Color primary, required Color onSurfaceVariant}) {
    return NavigationRailThemeData(
      backgroundColor: surface,
      indicatorColor: primary.withValues(alpha: 0.08),
      elevation: 0,
      selectedIconTheme: IconThemeData(color: primary),
      unselectedIconTheme: IconThemeData(color: onSurfaceVariant),
      selectedLabelTextStyle: TextStyle(color: primary, fontWeight: FontWeight.w700, letterSpacing: 0),
      unselectedLabelTextStyle: TextStyle(color: onSurfaceVariant, fontWeight: FontWeight.w500, letterSpacing: 0),
    );
  }

  static ListTileThemeData _listTileTheme({required Color iconColor, required Color textColor}) {
    return ListTileThemeData(
      iconColor: iconColor,
      textColor: textColor,
      selectedColor: textColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSmall)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    );
  }

  static FilledButtonThemeData _filledButtonTheme() {
    return FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSmall)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0),
        elevation: 0,
      ),
    );
  }

  static OutlinedButtonThemeData _outlinedButtonTheme(Color outline) {
    return OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        side: BorderSide(color: outline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSmall)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0),
      ),
    );
  }

  static TextButtonThemeData _textButtonTheme(Color foreground) {
    return TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: foreground,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSmall)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0),
      ),
    );
  }

  static IconButtonThemeData _iconButtonTheme(Color foreground) {
    return IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: foreground,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSmall)),
      ),
    );
  }

  static ChipThemeData _chipTheme({required Color background, required Color selected, required Color outline, required Color label}) {
    return ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSmall)),
      side: BorderSide(color: outline),
      backgroundColor: background,
      selectedColor: selected,
      labelStyle: TextStyle(color: label, fontWeight: FontWeight.w500, fontSize: 13),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    );
  }

  static InputDecorationTheme _inputDecorationTheme({required Color fill, required Color outline, required Color focused, required Color label}) {
    return InputDecorationTheme(
      filled: true,
      fillColor: fill,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      labelStyle: TextStyle(color: label, fontWeight: FontWeight.w500),
      floatingLabelStyle: TextStyle(color: focused, fontWeight: FontWeight.w600),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusSmall), borderSide: BorderSide(color: outline)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusSmall), borderSide: BorderSide(color: outline)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusSmall), borderSide: BorderSide(color: focused, width: 1.5)),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusSmall), borderSide: const BorderSide(color: Colors.red)),
      focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusSmall), borderSide: const BorderSide(color: Colors.red, width: 1.5)),
    );
  }

  static SnackBarThemeData _snackBarTheme({required Color background, required Color foreground}) {
    return SnackBarThemeData(
      backgroundColor: background,
      contentTextStyle: TextStyle(color: foreground, fontWeight: FontWeight.w500),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSmall)),
      behavior: SnackBarBehavior.floating,
    );
  }

  static DialogThemeData _dialogTheme(Color background) {
    return DialogThemeData(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusLarge)),
    );
  }

  static PopupMenuThemeData _popupMenuTheme(Color background) {
    return PopupMenuThemeData(
      color: background,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSmall)),
    );
  }

  static DrawerThemeData _drawerTheme(Color background, Color outline) {
    return DrawerThemeData(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(radiusMedium)),
        side: BorderSide(color: outline),
      ),
    );
  }

  static BottomSheetThemeData _bottomSheetTheme({required Color background, required Color outline}) {
    return BottomSheetThemeData(
      backgroundColor: background,
      modalBackgroundColor: background,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(radiusLarge)),
        side: BorderSide(color: outline),
      ),
    );
  }

  static SegmentedButtonThemeData _segmentedButtonTheme({required Color primary, required Color outline, required Color surface, required Color foreground}) {
    return SegmentedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(44, 38)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
        backgroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? primary.withValues(alpha: 0.08) : surface),
        foregroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? primary : foreground),
        side: WidgetStateProperty.resolveWith((states) => BorderSide(color: states.contains(WidgetState.selected) ? primary : outline)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSmall))),
        textStyle: const WidgetStatePropertyAll(TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0)),
      ),
    );
  }

  static ExpansionTileThemeData _expansionTileTheme({required Color foreground, required Color muted}) {
    return ExpansionTileThemeData(
      iconColor: muted,
      collapsedIconColor: muted,
      textColor: foreground,
      collapsedTextColor: foreground,
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMedium)),
      collapsedShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMedium)),
    );
  }

  static ProgressIndicatorThemeData _progressIndicatorTheme({required Color primary, required Color track}) {
    return ProgressIndicatorThemeData(color: primary, circularTrackColor: track, linearTrackColor: track);
  }

  static ScrollbarThemeData _scrollbarTheme({required Color thumb, required Color track}) {
    return ScrollbarThemeData(
      thumbVisibility: const WidgetStatePropertyAll(false),
      thickness: const WidgetStatePropertyAll(4),
      radius: const Radius.circular(radiusSmall),
      thumbColor: WidgetStateProperty.resolveWith((states) => thumb.withValues(alpha: states.contains(WidgetState.dragged) ? 0.6 : 0.4)),
      trackColor: WidgetStatePropertyAll(track.withValues(alpha: 0.2)),
    );
  }
}
