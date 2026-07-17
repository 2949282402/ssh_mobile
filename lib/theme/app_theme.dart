// ignore: unnecessary_import
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:animations/animations.dart';

part 'app_theme_extensions.dart';

class AppTheme {
  static const radiusSmall = 12.0;
  static const radiusMedium = 18.0;
  static const radiusLarge = 28.0;
  static const radiusPill = 999.0;

  static const pagePadding = 20.0;
  static const compactPagePadding = 14.0;

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

  static ThemeData lightThemeFor({
    AppColorPalette palette = AppColorPalette.monochrome,
  }) => _applyFont(_applyColorPalette(lightTheme, palette));
  static ThemeData darkThemeFor({
    bool oledDark = false,
    AppColorPalette palette = AppColorPalette.monochrome,
  }) => _applyFont(
    _applyColorPalette(buildDarkTheme(oledDark: oledDark), palette),
  );

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
      navigationBarTheme: _navigationBarTheme(
        surface: scheme.surface,
        primary: colors.primary,
        onSurfaceVariant: scheme.onSurfaceVariant,
      ),
      navigationRailTheme: _navigationRailTheme(
        surface: scheme.surface,
        primary: colors.primary,
        onSurfaceVariant: scheme.onSurfaceVariant,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colors.primary,
        foregroundColor: colors.onPrimary,
        elevation: 2,
        focusElevation: 3,
        hoverElevation: 4,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(radiusMedium)),
        ),
      ),
      textButtonTheme: _textButtonTheme(colors.primary),
      chipTheme: _chipTheme(
        background: scheme.surfaceContainer,
        selected: Color.alphaBlend(
          colors.primary.withValues(alpha: 0.14),
          scheme.surfaceContainer,
        ),
        outline: scheme.outline,
        label: scheme.onSurface,
      ),
      inputDecorationTheme: _inputDecorationTheme(
        fill: scheme.surface,
        outline: scheme.outline,
        focused: colors.primary,
        label: scheme.onSurfaceVariant,
      ),
      segmentedButtonTheme: _segmentedButtonTheme(
        primary: colors.primary,
        outline: scheme.outline,
        surface: scheme.surface,
        foreground: scheme.onSurface,
      ),
      progressIndicatorTheme: _progressIndicatorTheme(
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

  static final lightTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: const Color(0xFFF6F7FB),
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
      primary: Color(0xFF4F46E5),
      secondary: Color(0xFF0F9F87),
      tertiary: Color(0xFF7C3AED),
      surface: Color(0xFFFEFEFF),
      surfaceContainer: Color(0xFFF0F2F8),
      surfaceContainerHighest: Color(0xFFE6E9F1),
      outline: Color(0xFFDDE1EB),
      outlineVariant: Color(0xFFC9CEDA),
      error: Color(0xFFD92D4B),
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onTertiary: Colors.white,
      onSurface: Color(0xFF171923),
      onSurfaceVariant: Color(0xFF656B7A),
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
        glassBg: Color(0xD9FEFEFF),
        glassBorder: Color(0x66FFFFFF),
        cardHoverBorder: Color(0x664F46E5),
      ),
    ],
    textTheme: _textTheme(const Color(0xFF171923)),
    appBarTheme: _appBarTheme(
      background: const Color(0xFFF6F7FB),
      foreground: const Color(0xFF171923),
    ),
    cardTheme: _cardTheme(
      surface: const Color(0xFFFEFEFF),
      outline: const Color(0xFFDDE1EB),
    ),
    navigationBarTheme: _navigationBarTheme(
      surface: const Color(0xFFFEFEFF),
      primary: const Color(0xFF4F46E5),
      onSurfaceVariant: const Color(0xFF656B7A),
    ),
    navigationRailTheme: _navigationRailTheme(
      surface: const Color(0xFFFEFEFF),
      primary: const Color(0xFF4F46E5),
      onSurfaceVariant: const Color(0xFF656B7A),
    ),
    listTileTheme: _listTileTheme(
      iconColor: const Color(0xFF656B7A),
      textColor: const Color(0xFF171923),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Color(0xFF4F46E5),
      foregroundColor: Colors.white,
      elevation: 2,
      focusElevation: 3,
      hoverElevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(radiusMedium)),
      ),
    ),
    filledButtonTheme: _filledButtonTheme(),
    outlinedButtonTheme: _outlinedButtonTheme(const Color(0xFFDDE1EB)),
    textButtonTheme: _textButtonTheme(const Color(0xFF4F46E5)),
    iconButtonTheme: _iconButtonTheme(const Color(0xFF444A59)),
    chipTheme: _chipTheme(
      background: const Color(0xFFF0F2F8),
      selected: const Color(0xFFE6E4FF),
      outline: const Color(0xFFDDE1EB),
      label: const Color(0xFF444A59),
    ),
    inputDecorationTheme: _inputDecorationTheme(
      fill: const Color(0xFFF0F2F8),
      outline: const Color(0xFFDDE1EB),
      focused: const Color(0xFF4F46E5),
      label: const Color(0xFF656B7A),
    ),
    snackBarTheme: _snackBarTheme(
      background: const Color(0xFF0F172A),
      foreground: Colors.white,
    ),
    dialogTheme: _dialogTheme(Colors.white),
    popupMenuTheme: _popupMenuTheme(Colors.white),
    drawerTheme: _drawerTheme(const Color(0xFFFEFEFF), const Color(0xFFDDE1EB)),
    bottomSheetTheme: _bottomSheetTheme(
      background: Colors.white,
      outline: const Color(0xFFDDE1EB),
    ),
    segmentedButtonTheme: _segmentedButtonTheme(
      primary: const Color(0xFF4F46E5),
      outline: const Color(0xFFDDE1EB),
      surface: const Color(0xFFFEFEFF),
      foreground: const Color(0xFF444A59),
    ),
    expansionTileTheme: _expansionTileTheme(
      foreground: const Color(0xFF171923),
      muted: const Color(0xFF656B7A),
    ),
    progressIndicatorTheme: _progressIndicatorTheme(
      primary: const Color(0xFF4F46E5),
      track: const Color(0xFFDDE1EB),
    ),
    scrollbarTheme: _scrollbarTheme(
      thumb: const Color(0xFF8C93A5),
      track: const Color(0xFFDDE1EB),
    ),
    dividerTheme: const DividerThemeData(
      color: Color(0xFFDDE1EB),
      thickness: 1,
      space: 1,
    ),
  );

  static ThemeData buildDarkTheme({bool oledDark = false}) {
    final bgColor = oledDark
        ? const Color(0xFF000000)
        : const Color(0xFF090B11);
    final surfaceColor = oledDark
        ? const Color(0xFF000000)
        : const Color(0xFF11141C);
    final surfaceContainerColor = oledDark
        ? const Color(0xFF050505)
        : const Color(0xFF171B25);
    final outlineColor = oledDark
        ? const Color(0xFF111111)
        : const Color(0xFF282E3A);

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bgColor,
      canvasColor: bgColor,
      cardColor: surfaceColor,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeThroughPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: FadeThroughPageTransitionsBuilder(),
          TargetPlatform.macOS: FadeThroughPageTransitionsBuilder(),
          TargetPlatform.linux: FadeThroughPageTransitionsBuilder(),
        },
      ),
      colorScheme: ColorScheme.dark(
        primary: const Color(0xFF8B87FF),
        secondary: const Color(0xFF48CFB5),
        tertiary: const Color(0xFFC4B5FD),
        surface: surfaceColor,
        surfaceContainer: surfaceContainerColor,
        surfaceContainerHighest: oledDark
            ? const Color(0xFF111111)
            : const Color(0xFF202633),
        outline: outlineColor,
        outlineVariant: oledDark
            ? const Color(0xFF222222)
            : const Color(0xFF343B49),
        error: const Color(0xFFF87171),
        onPrimary: const Color(0xFF11102E),
        onSecondary: const Color(0xFF071D19),
        onTertiary: const Color(0xFF21183B),
        onSurface: const Color(0xFFF4F5F8),
        onSurfaceVariant: const Color(0xFFA7ADBA),
        onError: const Color(0xFF190A0A),
      ),
      extensions: [
        ExtendedColors(
          terminalBg: bgColor,
          terminalGreen: const Color(0xFF34D399),
          terminalAmber: const Color(0xFFFBBF24),
          terminalCyan: const Color(0xFF22D3EE),
          success: const Color(0xFF34D399),
          warning: const Color(0xFFFBBF24),
          glassBg: oledDark ? const Color(0xD9000000) : const Color(0xD911141C),
          glassBorder: oledDark
              ? const Color(0x26111111)
              : const Color(0x261F2937),
          cardHoverBorder: const Color(0x668B87FF),
        ),
      ],
      textTheme: _textTheme(const Color(0xFFF9FAFB)),
      appBarTheme: _appBarTheme(
        background: bgColor,
        foreground: const Color(0xFFF9FAFB),
      ),
      cardTheme: _cardTheme(surface: surfaceColor, outline: outlineColor),
      navigationBarTheme: _navigationBarTheme(
        surface: surfaceColor,
        primary: const Color(0xFF8B87FF),
        onSurfaceVariant: const Color(0xFF94A3B8),
      ),
      navigationRailTheme: _navigationRailTheme(
        surface: surfaceColor,
        primary: const Color(0xFF8B87FF),
        onSurfaceVariant: const Color(0xFF94A3B8),
      ),
      listTileTheme: _listTileTheme(
        iconColor: const Color(0xFF94A3B8),
        textColor: const Color(0xFFF9FAFB),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: Color(0xFF8B87FF),
        foregroundColor: Color(0xFF11102E),
        elevation: 2,
        focusElevation: 3,
        hoverElevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(radiusMedium)),
        ),
      ),
      filledButtonTheme: _filledButtonTheme(),
      outlinedButtonTheme: _outlinedButtonTheme(outlineColor),
      textButtonTheme: _textButtonTheme(const Color(0xFF8B87FF)),
      iconButtonTheme: _iconButtonTheme(const Color(0xFFCBD5E1)),
      chipTheme: _chipTheme(
        background: oledDark
            ? const Color(0xFF050505)
            : const Color(0xFF111827),
        selected: oledDark ? const Color(0xFF111111) : const Color(0xFF252B38),
        outline: oledDark ? const Color(0xFF111111) : const Color(0xFF282E3A),
        label: const Color(0xFFF9FAFB),
      ),
      inputDecorationTheme: _inputDecorationTheme(
        fill: surfaceColor,
        outline: outlineColor,
        focused: const Color(0xFF8B87FF),
        label: const Color(0xFF94A3B8),
      ),
      snackBarTheme: _snackBarTheme(
        background: const Color(0xFFF9FAFB),
        foreground: const Color(0xFF0B0F19),
      ),
      dialogTheme: _dialogTheme(surfaceColor),
      popupMenuTheme: _popupMenuTheme(surfaceColor),
      drawerTheme: _drawerTheme(surfaceColor, outlineColor),
      bottomSheetTheme: _bottomSheetTheme(
        background: surfaceColor,
        outline: outlineColor,
      ),
      segmentedButtonTheme: _segmentedButtonTheme(
        primary: const Color(0xFF8B87FF),
        outline: outlineColor,
        surface: surfaceColor,
        foreground: const Color(0xFFF9FAFB),
      ),
      expansionTileTheme: _expansionTileTheme(
        foreground: const Color(0xFFF9FAFB),
        muted: const Color(0xFF94A3B8),
      ),
      progressIndicatorTheme: _progressIndicatorTheme(
        primary: const Color(0xFF8B87FF),
        track: outlineColor,
      ),
      scrollbarTheme: _scrollbarTheme(
        thumb: const Color(0xFF64748B),
        track: outlineColor,
      ),
      dividerTheme: DividerThemeData(
        color: outlineColor,
        thickness: 1,
        space: 1,
      ),
    );
  }

  static TextTheme _textTheme(Color color) {
    return TextTheme(
      displaySmall: TextStyle(
        color: color,
        fontSize: 36,
        height: 1.12,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.1,
      ),
      headlineLarge: TextStyle(
        color: color,
        fontSize: 30,
        height: 1.18,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.9,
      ),
      headlineMedium: TextStyle(
        color: color,
        fontSize: 26,
        height: 1.2,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.7,
      ),
      headlineSmall: TextStyle(
        color: color,
        fontSize: 22,
        height: 1.24,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
      ),
      titleLarge: TextStyle(
        color: color,
        fontSize: 20,
        height: 1.25,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.35,
      ),
      titleMedium: TextStyle(
        color: color,
        fontSize: 16,
        height: 1.3,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
      ),
      titleSmall: TextStyle(
        color: color,
        fontSize: 14,
        height: 1.35,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: TextStyle(
        color: color,
        fontSize: 16,
        height: 1.5,
        letterSpacing: 0,
      ),
      bodyMedium: TextStyle(
        color: color,
        fontSize: 14,
        height: 1.45,
        letterSpacing: 0,
      ),
      bodySmall: TextStyle(
        color: color,
        fontSize: 12,
        height: 1.4,
        letterSpacing: 0.1,
      ),
      labelLarge: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      labelMedium: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
      ),
      labelSmall: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
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
        fontSize: 21,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
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
        borderRadius: BorderRadius.circular(radiusMedium),
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
      height: 72,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusPill),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          color: states.contains(WidgetState.selected)
              ? primary
              : onSurfaceVariant,
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
          letterSpacing: 0,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? primary
              : onSurfaceVariant,
          size: 22,
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
      useIndicator: true,
      minWidth: 82,
      minExtendedWidth: 224,
      groupAlignment: -0.72,
      elevation: 0,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusSmall),
      ),
      selectedIconTheme: IconThemeData(color: primary),
      unselectedIconTheme: IconThemeData(color: onSurfaceVariant),
      selectedLabelTextStyle: TextStyle(
        color: primary,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      unselectedLabelTextStyle: TextStyle(
        color: onSurfaceVariant,
        fontWeight: FontWeight.w500,
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
      selectedTileColor: iconColor.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusSmall),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
    );
  }

  static FilledButtonThemeData _filledButtonTheme() {
    return FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(46, 46),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
        ),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
        elevation: 0,
      ),
    );
  }

  static OutlinedButtonThemeData _outlinedButtonTheme(Color outline) {
    return OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(46, 46),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        side: BorderSide(color: outline),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
        ),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w600,
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
          borderRadius: BorderRadius.circular(radiusSmall),
        ),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
      ),
    );
  }

  static IconButtonThemeData _iconButtonTheme(Color foreground) {
    return IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: foreground,
        minimumSize: const Size(42, 42),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
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
        borderRadius: BorderRadius.circular(radiusPill),
      ),
      side: BorderSide(color: outline),
      backgroundColor: background,
      selectedColor: selected,
      labelStyle: TextStyle(
        color: label,
        fontWeight: FontWeight.w500,
        fontSize: 13,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 15),
      labelStyle: TextStyle(color: label, fontWeight: FontWeight.w500),
      floatingLabelStyle: TextStyle(
        color: focused,
        fontWeight: FontWeight.w600,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusSmall),
        borderSide: BorderSide(color: outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusSmall),
        borderSide: BorderSide(color: outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusSmall),
        borderSide: BorderSide(color: focused, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusSmall),
        borderSide: const BorderSide(color: Colors.red),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusSmall),
        borderSide: const BorderSide(color: Colors.red, width: 1.5),
      ),
    );
  }

  static SnackBarThemeData _snackBarTheme({
    required Color background,
    required Color foreground,
  }) {
    return SnackBarThemeData(
      backgroundColor: background,
      contentTextStyle: TextStyle(
        color: foreground,
        fontWeight: FontWeight.w500,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusSmall),
      ),
      behavior: SnackBarBehavior.floating,
    );
  }

  static DialogThemeData _dialogTheme(Color background) {
    return DialogThemeData(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusLarge),
      ),
    );
  }

  static PopupMenuThemeData _popupMenuTheme(Color background) {
    return PopupMenuThemeData(
      color: background,
      surfaceTintColor: Colors.transparent,
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusMedium),
      ),
    );
  }

  static DrawerThemeData _drawerTheme(Color background, Color outline) {
    return DrawerThemeData(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.horizontal(
          right: Radius.circular(radiusMedium),
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
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(radiusLarge),
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
          EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? primary.withValues(alpha: 0.08)
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
            borderRadius: BorderRadius.circular(radiusSmall),
          ),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0),
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
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusMedium),
      ),
      collapsedShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusMedium),
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
      radius: const Radius.circular(radiusSmall),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => thumb.withValues(
          alpha: states.contains(WidgetState.dragged) ? 0.6 : 0.4,
        ),
      ),
      trackColor: WidgetStatePropertyAll(track.withValues(alpha: 0.2)),
    );
  }
}
