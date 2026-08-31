part of 'ssh_mobile_app.dart';

/// Shared Material and Shad theme catalog for the Full App shell.
final class _SshMobileAppThemes {
  static final Map<AppColorPalette, ThemeData> lightThemes = {
    for (final palette in AppColorPalette.values)
      palette: AppTheme.lightThemeFor(palette: palette),
  };
  static final Map<AppColorPalette, ThemeData> darkThemes = {
    for (final palette in AppColorPalette.values)
      palette: AppTheme.darkThemeFor(palette: palette),
  };
  static final Map<AppColorPalette, ThemeData> oledDarkThemes = {
    for (final palette in AppColorPalette.values)
      palette: AppTheme.darkThemeFor(oledDark: true, palette: palette),
  };
  static final Map<AppColorPalette, ShadThemeData> shadLightThemes = {
    for (final palette in AppColorPalette.values)
      palette: buildShadTheme(palette, Brightness.light),
  };
  static final Map<AppColorPalette, ShadThemeData> shadDarkThemes = {
    for (final palette in AppColorPalette.values)
      palette: buildShadTheme(palette, Brightness.dark),
  };

  static ShadThemeData buildShadTheme(
    AppColorPalette palette,
    Brightness brightness,
  ) {
    final dark = brightness == Brightness.dark;
    final materialTheme = dark
        ? AppTheme.darkThemeFor(palette: palette)
        : AppTheme.lightThemeFor(palette: palette);
    final colors = materialTheme.colorScheme;
    final base = dark
        ? const ShadVioletColorScheme.dark()
        : const ShadVioletColorScheme.light();
    return ShadThemeData(
      brightness: brightness,
      radius: const BorderRadius.all(Radius.circular(AppTheme.radiusSmall)),
      colorScheme: base.copyWith(
        background: materialTheme.scaffoldBackgroundColor,
        foreground: colors.onSurface,
        card: colors.surface,
        cardForeground: colors.onSurface,
        popover: colors.surface,
        popoverForeground: colors.onSurface,
        primary: colors.primary,
        primaryForeground: colors.onPrimary,
        secondary: colors.surfaceContainer,
        secondaryForeground: colors.onSurface,
        muted: colors.surfaceContainer,
        mutedForeground: colors.onSurfaceVariant,
        accent: Color.alphaBlend(
          colors.primary.withValues(alpha: 0.14),
          colors.surfaceContainer,
        ),
        accentForeground: colors.onSurface,
        border: colors.outline,
        input: colors.outline,
        ring: colors.primary,
        selection: colors.primary.withValues(alpha: 0.2),
      ),
    );
  }
}
