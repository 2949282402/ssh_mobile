import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app_ui/app_ui.dart';

void main() {
  test('monochrome is the default app palette', () {
    expect(
      AppTheme.lightThemeFor().colorScheme.primary,
      const Color(0xFF202124),
    );
    expect(
      AppTheme.darkThemeFor().colorScheme.primary,
      const Color(0xFFE8EAED),
    );
  });

  test('all app palettes provide distinct light and dark primary colors', () {
    final lightColors = <Color>{};
    final darkColors = <Color>{};

    for (final palette in AppColorPalette.values) {
      final lightTheme = AppTheme.lightThemeFor(palette: palette);
      final darkTheme = AppTheme.darkThemeFor(palette: palette);
      final expectedLight = AppTheme.paletteColors(palette, Brightness.light);
      final expectedDark = AppTheme.paletteColors(palette, Brightness.dark);

      expect(lightTheme.colorScheme.primary, expectedLight.primary);
      expect(lightTheme.colorScheme.secondary, expectedLight.secondary);
      expect(darkTheme.colorScheme.primary, expectedDark.primary);
      expect(darkTheme.colorScheme.secondary, expectedDark.secondary);
      expect(
        lightTheme.floatingActionButtonTheme.backgroundColor,
        expectedLight.primary,
      );
      lightColors.add(lightTheme.colorScheme.primary);
      darkColors.add(darkTheme.colorScheme.primary);
    }

    expect(lightColors, hasLength(AppColorPalette.values.length));
    expect(darkColors, hasLength(AppColorPalette.values.length));
  });

  test('OLED dark keeps black surfaces while applying selected palette', () {
    final theme = AppTheme.darkThemeFor(
      oledDark: true,
      palette: AppColorPalette.ocean,
    );

    expect(theme.scaffoldBackgroundColor, Colors.black);
    expect(theme.colorScheme.surface, Colors.black);
    expect(theme.colorScheme.primary, const Color(0xFF38BDF8));
  });
}
