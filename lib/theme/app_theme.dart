import 'package:flutter/material.dart';

/// Material 3 亮色/暗色主题定义。
///
/// 两套完整主题：lightTheme / darkTheme，均使用 Material 3 ColorScheme。
/// lightThemeFor / darkThemeFor 接收字体参数，在主题基础上替换 textTheme 字体族。
///
/// 设计决策：
/// - 桌面端使用一致的 ColorScheme，通过自动亮度检测切换 themeMode
/// - 字体不内嵌 bundle，由系统安装字体提供
class AppTheme {
  static const _radius = 8.0;

  static ThemeData lightThemeFor(String? fontFamily) =>
      _applyFont(lightTheme, fontFamily);

  static ThemeData darkThemeFor(String? fontFamily) =>
      _applyFont(darkTheme, fontFamily);

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
    scaffoldBackgroundColor: const Color(0xFFF5F7FA),
    colorScheme: const ColorScheme.light(
      primary: Color(0xFF2563EB),
      secondary: Color(0xFF0F766E),
      tertiary: Color(0xFF7C3AED),
      surface: Color(0xFFFFFFFF),
      surfaceContainer: Color(0xFFF8FAFC),
      surfaceContainerHighest: Color(0xFFE8EEF6),
      outline: Color(0xFFCBD5E1),
      outlineVariant: Color(0xFFE2E8F0),
      error: Color(0xFFDC2626),
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onTertiary: Colors.white,
      onSurface: Color(0xFF111827),
      onSurfaceVariant: Color(0xFF5B6472),
      onError: Colors.white,
    ),
    textTheme: _textTheme(const Color(0xFF111827)),
    appBarTheme: _appBarTheme(
      background: const Color(0xFFF5F7FA),
      foreground: const Color(0xFF111827),
    ),
    cardTheme: _cardTheme(
      surface: Colors.white,
      outline: const Color(0xFFE2E8F0),
    ),
    navigationBarTheme: _navigationBarTheme(
      surface: const Color(0xFFFFFFFF),
      primary: const Color(0xFF2563EB),
      onSurfaceVariant: const Color(0xFF64748B),
    ),
    navigationRailTheme: _navigationRailTheme(
      surface: const Color(0xFFFFFFFF),
      primary: const Color(0xFF2563EB),
      onSurfaceVariant: const Color(0xFF64748B),
    ),
    listTileTheme: _listTileTheme(
      iconColor: const Color(0xFF64748B),
      textColor: const Color(0xFF111827),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Color(0xFF2563EB),
      foregroundColor: Colors.white,
      elevation: 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(_radius)),
      ),
    ),
    filledButtonTheme: _filledButtonTheme(),
    outlinedButtonTheme: _outlinedButtonTheme(const Color(0xFFCBD5E1)),
    textButtonTheme: _textButtonTheme(const Color(0xFF2563EB)),
    iconButtonTheme: _iconButtonTheme(const Color(0xFF334155)),
    chipTheme: _chipTheme(
      background: const Color(0xFFF1F5F9),
      selected: const Color(0xFFDBEAFE),
      outline: const Color(0xFFE2E8F0),
      label: const Color(0xFF334155),
    ),
    inputDecorationTheme: _inputDecorationTheme(
      fill: Colors.white,
      outline: const Color(0xFFD8E0EA),
      focused: const Color(0xFF2563EB),
      label: const Color(0xFF64748B),
    ),
    snackBarTheme: _snackBarTheme(
      background: const Color(0xFF111827),
      foreground: Colors.white,
    ),
    dialogTheme: _dialogTheme(Colors.white),
    popupMenuTheme: _popupMenuTheme(Colors.white),
    drawerTheme: _drawerTheme(Colors.white, const Color(0xFFE2E8F0)),
    bottomSheetTheme: _bottomSheetTheme(
      background: Colors.white,
      outline: const Color(0xFFE2E8F0),
    ),
    segmentedButtonTheme: _segmentedButtonTheme(
      primary: const Color(0xFF2563EB),
      outline: const Color(0xFFCBD5E1),
      surface: Colors.white,
      foreground: const Color(0xFF334155),
    ),
    expansionTileTheme: _expansionTileTheme(
      foreground: const Color(0xFF111827),
      muted: const Color(0xFF64748B),
    ),
    progressIndicatorTheme: _progressIndicatorTheme(
      primary: const Color(0xFF2563EB),
      track: const Color(0xFFE2E8F0),
    ),
    scrollbarTheme: _scrollbarTheme(
      thumb: const Color(0xFF94A3B8),
      track: const Color(0xFFE2E8F0),
    ),
    dividerTheme: const DividerThemeData(
      color: Color(0xFFE2E8F0),
      thickness: 1,
      space: 1,
    ),
  );

  static final darkTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xFF0A0F1D),
    colorScheme: const ColorScheme.dark(
      primary: Color(0xFF60A5FA),
      secondary: Color(0xFF2DD4BF),
      tertiary: Color(0xFFA78BFA),
      surface: Color(0xFF121B2E),
      surfaceContainer: Color(0xFF1A263F),
      surfaceContainerHighest: Color(0xFF253556),
      outline: Color(0xFF3D4F73),
      outlineVariant: Color(0xFF2B3A57),
      error: Color(0xFFF87171),
      onPrimary: Color(0xFF08111F),
      onSecondary: Color(0xFF08111F),
      onTertiary: Color(0xFF08111F),
      onSurface: Color(0xFFE5E7EB),
      onSurfaceVariant: Color(0xFFABB6C8),
      onError: Color(0xFF190A0A),
    ),
    textTheme: _textTheme(const Color(0xFFE5E7EB)),
    appBarTheme: _appBarTheme(
      background: const Color(0xFF0A0F1D),
      foreground: const Color(0xFFE5E7EB),
    ),
    cardTheme: _cardTheme(
      surface: const Color(0xFF121B2E),
      outline: const Color(0xFF2B3A57),
    ),
    navigationBarTheme: _navigationBarTheme(
      surface: const Color(0xFF121B2E),
      primary: const Color(0xFF60A5FA),
      onSurfaceVariant: const Color(0xFF94A3B8),
    ),
    navigationRailTheme: _navigationRailTheme(
      surface: const Color(0xFF121B2E),
      primary: const Color(0xFF60A5FA),
      onSurfaceVariant: const Color(0xFF94A3B8),
    ),
    listTileTheme: _listTileTheme(
      iconColor: const Color(0xFF94A3B8),
      textColor: const Color(0xFFE5E7EB),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Color(0xFF60A5FA),
      foregroundColor: Color(0xFF08111F),
      elevation: 3,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(_radius))),
    ),
    filledButtonTheme: _filledButtonTheme(),
    outlinedButtonTheme: _outlinedButtonTheme(const Color(0xFF3D4F73)),
    textButtonTheme: _textButtonTheme(const Color(0xFF60A5FA)),
    iconButtonTheme: _iconButtonTheme(const Color(0xFFCBD5E1)),
    chipTheme: _chipTheme(
      background: const Color(0xFF1A263F),
      selected: const Color(0xFF253556),
      outline: const Color(0xFF2B3A57),
      label: const Color(0xFFE5E7EB),
    ),
    inputDecorationTheme: _inputDecorationTheme(
      fill: const Color(0xFF121B2E),
      outline: const Color(0xFF2B3A57),
      focused: const Color(0xFF60A5FA),
      label: const Color(0xFF94A3B8),
    ),
    snackBarTheme: _snackBarTheme(
      background: const Color(0xFFE5E7EB),
      foreground: const Color(0xFF121B2E),
    ),
    dialogTheme: _dialogTheme(const Color(0xFF121B2E)),
    popupMenuTheme: _popupMenuTheme(const Color(0xFF121B2E)),
    drawerTheme: _drawerTheme(
      const Color(0xFF121B2E),
      const Color(0xFF2B3A57),
    ),
    bottomSheetTheme: _bottomSheetTheme(
      background: const Color(0xFF121B2E),
      outline: const Color(0xFF2B3A57),
    ),
    segmentedButtonTheme: _segmentedButtonTheme(
      primary: const Color(0xFF60A5FA),
      outline: const Color(0xFF3D4F73),
      surface: const Color(0xFF121B2E),
      foreground: const Color(0xFFE5E7EB),
    ),
    expansionTileTheme: _expansionTileTheme(
      foreground: const Color(0xFFE5E7EB),
      muted: const Color(0xFF94A3B8),
    ),
    progressIndicatorTheme: _progressIndicatorTheme(
      primary: const Color(0xFF60A5FA),
      track: const Color(0xFF2B3A57),
    ),
    scrollbarTheme: _scrollbarTheme(
      thumb: const Color(0xFF64748B),
      track: const Color(0xFF2B3A57),
    ),
    dividerTheme: const DividerThemeData(
      color: Color(0xFF2B3A57),
      thickness: 1,
      space: 1,
    ),
  );

  static TextTheme _textTheme(Color color) {
    return TextTheme(
      titleLarge: TextStyle(
        color: color,
        fontWeight: FontWeight.w800,
        letterSpacing: 0,
      ),
      titleMedium: TextStyle(
        color: color,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      bodyMedium: TextStyle(color: color, letterSpacing: 0, height: 1.32),
      labelLarge: const TextStyle(
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
    );
  }

  static AppBarTheme _appBarTheme({
    required Color background,
    required Color foreground,
  }) {
    return AppBarTheme(
      backgroundColor: background,
      foregroundColor: foreground,
      elevation: 0,
      centerTitle: false,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      titleTextStyle: TextStyle(
        color: foreground,
        fontSize: 26,
        fontWeight: FontWeight.w800,
        letterSpacing: 0,
      ),
    );
  }

  static CardThemeData _cardTheme({
    required Color surface,
    required Color outline,
  }) {
    return CardThemeData(
      color: surface,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_radius),
        side: BorderSide(color: outline, width: 1),
      ),
    );
  }

  static NavigationBarThemeData _navigationBarTheme({
    required Color surface,
    required Color primary,
    required Color onSurfaceVariant,
  }) {
    return NavigationBarThemeData(
      backgroundColor: surface,
      indicatorColor: primary.withValues(alpha: 0.12),
      elevation: 0,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          color: states.contains(WidgetState.selected)
              ? primary
              : onSurfaceVariant,
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w800
              : FontWeight.w600,
          letterSpacing: 0,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? primary
              : onSurfaceVariant,
          size: 23,
        ),
      ),
    );
  }

  static NavigationRailThemeData _navigationRailTheme({
    required Color surface,
    required Color primary,
    required Color onSurfaceVariant,
  }) {
    return NavigationRailThemeData(
      backgroundColor: surface,
      indicatorColor: primary.withValues(alpha: 0.12),
      elevation: 0,
      selectedIconTheme: IconThemeData(color: primary),
      unselectedIconTheme: IconThemeData(color: onSurfaceVariant),
      selectedLabelTextStyle: TextStyle(
        color: primary,
        fontWeight: FontWeight.w800,
        letterSpacing: 0,
      ),
      unselectedLabelTextStyle: TextStyle(
        color: onSurfaceVariant,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
    );
  }

  static ListTileThemeData _listTileTheme({
    required Color iconColor,
    required Color textColor,
  }) {
    return ListTileThemeData(
      iconColor: iconColor,
      textColor: textColor,
      selectedColor: textColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_radius),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
    );
  }

  static FilledButtonThemeData _filledButtonTheme() {
    return FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radius),
        ),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
      ),
    );
  }

  static OutlinedButtonThemeData _outlinedButtonTheme(Color outline) {
    return OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        side: BorderSide(color: outline),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radius),
        ),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
      ),
    );
  }

  static TextButtonThemeData _textButtonTheme(Color foreground) {
    return TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: foreground,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radius),
        ),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
      ),
    );
  }

  static IconButtonThemeData _iconButtonTheme(Color foreground) {
    return IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: foreground,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radius),
        ),
      ),
    );
  }

  static ChipThemeData _chipTheme({
    required Color background,
    required Color selected,
    required Color outline,
    required Color label,
  }) {
    return ChipThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_radius),
      ),
      side: BorderSide(color: outline),
      backgroundColor: background,
      selectedColor: selected,
      labelStyle: TextStyle(color: label, fontWeight: FontWeight.w600),
      padding: const EdgeInsets.symmetric(horizontal: 8),
    );
  }

  static InputDecorationTheme _inputDecorationTheme({
    required Color fill,
    required Color outline,
    required Color focused,
    required Color label,
  }) {
    return InputDecorationTheme(
      filled: true,
      fillColor: fill,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
      labelStyle: TextStyle(color: label, fontWeight: FontWeight.w600),
      floatingLabelStyle:
          TextStyle(color: focused, fontWeight: FontWeight.w700),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_radius),
        borderSide: BorderSide(color: outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_radius),
        borderSide: BorderSide(color: outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_radius),
        borderSide: BorderSide(color: focused, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_radius),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_radius),
      ),
    );
  }

  static SnackBarThemeData _snackBarTheme({
    required Color background,
    required Color foreground,
  }) {
    return SnackBarThemeData(
      backgroundColor: background,
      contentTextStyle: TextStyle(color: foreground),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(_radius)),
      behavior: SnackBarBehavior.floating,
    );
  }

  static DialogThemeData _dialogTheme(Color background) {
    return DialogThemeData(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_radius),
      ),
    );
  }

  static PopupMenuThemeData _popupMenuTheme(Color background) {
    return PopupMenuThemeData(
      color: background,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_radius),
      ),
    );
  }

  static DrawerThemeData _drawerTheme(Color background, Color outline) {
    return DrawerThemeData(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.horizontal(
          right: Radius.circular(_radius),
        ),
        side: BorderSide(color: outline),
      ),
    );
  }

  static BottomSheetThemeData _bottomSheetTheme({
    required Color background,
    required Color outline,
  }) {
    return BottomSheetThemeData(
      backgroundColor: background,
      modalBackgroundColor: background,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(_radius),
        ),
        side: BorderSide(color: outline),
      ),
    );
  }

  static SegmentedButtonThemeData _segmentedButtonTheme({
    required Color primary,
    required Color outline,
    required Color surface,
    required Color foreground,
  }) {
    return SegmentedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(44, 38)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? primary.withValues(alpha: 0.12)
              : surface,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? primary : foreground,
        ),
        side: WidgetStateProperty.resolveWith(
          (states) => BorderSide(
            color: states.contains(WidgetState.selected) ? primary : outline,
          ),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_radius),
          ),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0),
        ),
      ),
    );
  }

  static ExpansionTileThemeData _expansionTileTheme({
    required Color foreground,
    required Color muted,
  }) {
    return ExpansionTileThemeData(
      iconColor: muted,
      collapsedIconColor: muted,
      textColor: foreground,
      collapsedTextColor: foreground,
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_radius),
      ),
      collapsedShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_radius),
      ),
    );
  }

  static ProgressIndicatorThemeData _progressIndicatorTheme({
    required Color primary,
    required Color track,
  }) {
    return ProgressIndicatorThemeData(
      color: primary,
      circularTrackColor: track,
      linearTrackColor: track,
    );
  }

  static ScrollbarThemeData _scrollbarTheme({
    required Color thumb,
    required Color track,
  }) {
    return ScrollbarThemeData(
      thumbVisibility: const WidgetStatePropertyAll(false),
      thickness: const WidgetStatePropertyAll(4),
      radius: const Radius.circular(_radius),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => thumb.withValues(
          alpha: states.contains(WidgetState.dragged) ? 0.8 : 0.55,
        ),
      ),
      trackColor: WidgetStatePropertyAll(track.withValues(alpha: 0.42)),
    );
  }

  static const terminalBg = Color(0xFF07111F);
  static const terminalGreen = Color(0xFF4ADE80);
  static const terminalAmber = Color(0xFFFBBF24);
  static const terminalCyan = Color(0xFF38BDF8);
}
