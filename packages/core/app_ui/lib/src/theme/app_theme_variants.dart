part of 'app_theme.dart';

/// 浅色和深色主题变体构建器。
///
/// 主题选择入口仍由 [AppTheme] 暴露；本类只承载大块 Material 主题配置，
/// 以保持组合入口和控件级样式的职责边界。
class _AppThemeThemeVariants {
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
    textTheme: _AppThemeComponentBuilders._textTheme(const Color(0xFF171923)),
    appBarTheme: _AppThemeComponentBuilders._appBarTheme(
      background: const Color(0xFFF6F7FB),
      foreground: const Color(0xFF171923),
    ),
    cardTheme: _AppThemeComponentBuilders._cardTheme(
      surface: const Color(0xFFFEFEFF),
      outline: const Color(0xFFDDE1EB),
    ),
    navigationBarTheme: _AppThemeComponentBuilders._navigationBarTheme(
      surface: const Color(0xFFFEFEFF),
      primary: const Color(0xFF4F46E5),
      onSurfaceVariant: const Color(0xFF656B7A),
    ),
    navigationRailTheme: _AppThemeComponentBuilders._navigationRailTheme(
      surface: const Color(0xFFFEFEFF),
      primary: const Color(0xFF4F46E5),
      onSurfaceVariant: const Color(0xFF656B7A),
    ),
    listTileTheme: _AppThemeComponentBuilders._listTileTheme(
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
        borderRadius: BorderRadius.all(Radius.circular(AppTheme.radiusMedium)),
      ),
    ),
    filledButtonTheme: _AppThemeComponentBuilders._filledButtonTheme(),
    outlinedButtonTheme: _AppThemeComponentBuilders._outlinedButtonTheme(
      const Color(0xFFDDE1EB),
    ),
    textButtonTheme: _AppThemeComponentBuilders._textButtonTheme(
      const Color(0xFF4F46E5),
    ),
    iconButtonTheme: _AppThemeComponentBuilders._iconButtonTheme(
      const Color(0xFF444A59),
    ),
    chipTheme: _AppThemeComponentBuilders._chipTheme(
      background: const Color(0xFFF0F2F8),
      selected: const Color(0xFFE6E4FF),
      outline: const Color(0xFFDDE1EB),
      label: const Color(0xFF444A59),
    ),
    inputDecorationTheme: _AppThemeComponentBuilders._inputDecorationTheme(
      fill: const Color(0xFFF0F2F8),
      outline: const Color(0xFFDDE1EB),
      focused: const Color(0xFF4F46E5),
      label: const Color(0xFF656B7A),
    ),
    snackBarTheme: _AppThemeComponentBuilders._snackBarTheme(
      background: const Color(0xFF0F172A),
      foreground: Colors.white,
    ),
    dialogTheme: _AppThemeComponentBuilders._dialogTheme(Colors.white),
    popupMenuTheme: _AppThemeComponentBuilders._popupMenuTheme(Colors.white),
    drawerTheme: _AppThemeComponentBuilders._drawerTheme(
      const Color(0xFFFEFEFF),
      const Color(0xFFDDE1EB),
    ),
    bottomSheetTheme: _AppThemeComponentBuilders._bottomSheetTheme(
      background: Colors.white,
      outline: const Color(0xFFDDE1EB),
    ),
    segmentedButtonTheme: _AppThemeComponentBuilders._segmentedButtonTheme(
      primary: const Color(0xFF4F46E5),
      outline: const Color(0xFFDDE1EB),
      surface: const Color(0xFFFEFEFF),
      foreground: const Color(0xFF444A59),
    ),
    expansionTileTheme: _AppThemeComponentBuilders._expansionTileTheme(
      foreground: const Color(0xFF171923),
      muted: const Color(0xFF656B7A),
    ),
    progressIndicatorTheme: _AppThemeComponentBuilders._progressIndicatorTheme(
      primary: const Color(0xFF4F46E5),
      track: const Color(0xFFDDE1EB),
    ),
    scrollbarTheme: _AppThemeComponentBuilders._scrollbarTheme(
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
      textTheme: _AppThemeComponentBuilders._textTheme(const Color(0xFFF9FAFB)),
      appBarTheme: _AppThemeComponentBuilders._appBarTheme(
        background: bgColor,
        foreground: const Color(0xFFF9FAFB),
      ),
      cardTheme: _AppThemeComponentBuilders._cardTheme(
        surface: surfaceColor,
        outline: outlineColor,
      ),
      navigationBarTheme: _AppThemeComponentBuilders._navigationBarTheme(
        surface: surfaceColor,
        primary: const Color(0xFF8B87FF),
        onSurfaceVariant: const Color(0xFF94A3B8),
      ),
      navigationRailTheme: _AppThemeComponentBuilders._navigationRailTheme(
        surface: surfaceColor,
        primary: const Color(0xFF8B87FF),
        onSurfaceVariant: const Color(0xFF94A3B8),
      ),
      listTileTheme: _AppThemeComponentBuilders._listTileTheme(
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
          borderRadius: BorderRadius.all(
            Radius.circular(AppTheme.radiusMedium),
          ),
        ),
      ),
      filledButtonTheme: _AppThemeComponentBuilders._filledButtonTheme(),
      outlinedButtonTheme: _AppThemeComponentBuilders._outlinedButtonTheme(
        outlineColor,
      ),
      textButtonTheme: _AppThemeComponentBuilders._textButtonTheme(
        const Color(0xFF8B87FF),
      ),
      iconButtonTheme: _AppThemeComponentBuilders._iconButtonTheme(
        const Color(0xFFCBD5E1),
      ),
      chipTheme: _AppThemeComponentBuilders._chipTheme(
        background: oledDark
            ? const Color(0xFF050505)
            : const Color(0xFF111827),
        selected: oledDark ? const Color(0xFF111111) : const Color(0xFF252B38),
        outline: oledDark ? const Color(0xFF111111) : const Color(0xFF282E3A),
        label: const Color(0xFFF9FAFB),
      ),
      inputDecorationTheme: _AppThemeComponentBuilders._inputDecorationTheme(
        fill: surfaceColor,
        outline: outlineColor,
        focused: const Color(0xFF8B87FF),
        label: const Color(0xFF94A3B8),
      ),
      snackBarTheme: _AppThemeComponentBuilders._snackBarTheme(
        background: const Color(0xFFF9FAFB),
        foreground: const Color(0xFF0B0F19),
      ),
      dialogTheme: _AppThemeComponentBuilders._dialogTheme(surfaceColor),
      popupMenuTheme: _AppThemeComponentBuilders._popupMenuTheme(surfaceColor),
      drawerTheme: _AppThemeComponentBuilders._drawerTheme(
        surfaceColor,
        outlineColor,
      ),
      bottomSheetTheme: _AppThemeComponentBuilders._bottomSheetTheme(
        background: surfaceColor,
        outline: outlineColor,
      ),
      segmentedButtonTheme: _AppThemeComponentBuilders._segmentedButtonTheme(
        primary: const Color(0xFF8B87FF),
        outline: outlineColor,
        surface: surfaceColor,
        foreground: const Color(0xFFF9FAFB),
      ),
      expansionTileTheme: _AppThemeComponentBuilders._expansionTileTheme(
        foreground: const Color(0xFFF9FAFB),
        muted: const Color(0xFF94A3B8),
      ),
      progressIndicatorTheme:
          _AppThemeComponentBuilders._progressIndicatorTheme(
            primary: const Color(0xFF8B87FF),
            track: outlineColor,
          ),
      scrollbarTheme: _AppThemeComponentBuilders._scrollbarTheme(
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
}
