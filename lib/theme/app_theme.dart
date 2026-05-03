import 'package:flutter/material.dart';

/// 暗色终端主题 - 模拟经典终端风格
class AppTheme {
  static final darkTheme = ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xFF0D1117),
    colorScheme: ColorScheme.dark(
      primary: const Color(0xFF58A6FF),
      secondary: const Color(0xFF3FB950),
      surface: const Color(0xFF161B22),
      error: const Color(0xFFF85149),
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onSurface: const Color(0xFFC9D1D9),
      onError: Colors.white,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF161B22),
      foregroundColor: Color(0xFFC9D1D9),
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: const Color(0xFF161B22),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xFF30363D), width: 1),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Color(0xFF238636),
      foregroundColor: Colors.white,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF0D1117),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: Color(0xFF30363D)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: Color(0xFF30363D)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: Color(0xFF58A6FF), width: 2),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: const Color(0xFF161B22),
      contentTextStyle: const TextStyle(color: Color(0xFFC9D1D9)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      behavior: SnackBarBehavior.floating,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: const Color(0xFF161B22),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );

  // 终端配色
  static const terminalBg = Color(0xFF0A0E14);
  static const terminalGreen = Color(0xFF00FF41);
  static const terminalAmber = Color(0xFFFFB000);
  static const terminalCyan = Color(0xFF00D4FF);
}
