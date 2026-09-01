part of 'app_theme.dart';

/// 主题组件构建器，集中维护控件级样式，避免组合根文件承担所有细节。
///
/// 这些方法保持私有，只由 [AppTheme] 调用；拆分仅改变文件职责，不改变
/// 现有主题参数和公共静态入口。
class _AppThemeComponentBuilders {
  static TextTheme _textTheme(Color color) {
    return TextTheme(
      displaySmall: TextStyle(
        color: color,
        fontSize: 30,
        height: 1.15,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.8,
      ),
      headlineLarge: TextStyle(
        color: color,
        fontSize: 24,
        height: 1.2,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.6,
      ),
      headlineMedium: TextStyle(
        color: color,
        fontSize: 20,
        height: 1.25,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.4,
      ),
      headlineSmall: TextStyle(
        color: color,
        fontSize: 18,
        height: 1.3,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
      titleLarge: TextStyle(
        color: color,
        fontSize: 16,
        height: 1.3,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
      ),
      titleMedium: TextStyle(
        color: color,
        fontSize: 14,
        height: 1.35,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      titleSmall: TextStyle(
        color: color,
        fontSize: 13,
        height: 1.4,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: TextStyle(
        color: color,
        fontSize: 14,
        height: 1.45,
        letterSpacing: 0,
      ),
      bodyMedium: TextStyle(
        color: color,
        fontSize: 13,
        height: 1.4,
        letterSpacing: 0,
      ),
      bodySmall: TextStyle(
        color: color,
        fontSize: 12,
        height: 1.35,
        letterSpacing: 0,
      ),
      labelLarge: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      labelMedium: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.1,
      ),
      labelSmall: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.1,
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
        fontSize: 16,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
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
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
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
      indicatorColor: primary.withValues(alpha: 0.10),
      height: 56,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          color: states.contains(WidgetState.selected)
              ? primary
              : onSurfaceVariant,
          fontSize: 11,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w500,
          letterSpacing: 0,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? primary
              : onSurfaceVariant,
          size: 20,
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
      indicatorColor: primary.withValues(alpha: 0.10),
      useIndicator: true,
      minWidth: 60,
      minExtendedWidth: 200,
      groupAlignment: -1.0,
      elevation: 0,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      ),
      selectedIconTheme: IconThemeData(color: primary, size: 20),
      unselectedIconTheme: IconThemeData(color: onSurfaceVariant, size: 20),
      selectedLabelTextStyle: TextStyle(
        color: primary,
        fontWeight: FontWeight.w600,
        fontSize: 13,
        letterSpacing: 0,
      ),
      unselectedLabelTextStyle: TextStyle(
        color: onSurfaceVariant,
        fontWeight: FontWeight.w500,
        fontSize: 13,
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
      selectedTileColor: iconColor.withValues(alpha: 0.06),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      visualDensity: VisualDensity.compact,
    );
  }

  static FilledButtonThemeData _filledButtonTheme() {
    return FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(36, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        tapTargetSize: MaterialTapTargetSize.padded,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        ),
        textStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          letterSpacing: 0,
        ),
        elevation: 0,
      ),
    );
  }

  static OutlinedButtonThemeData _outlinedButtonTheme(Color outline) {
    return OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(36, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        tapTargetSize: MaterialTapTargetSize.padded,
        side: BorderSide(color: outline),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        ),
        textStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          letterSpacing: 0,
        ),
        elevation: 0,
      ),
    );
  }

  static TextButtonThemeData _textButtonTheme(Color foreground) {
    return TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: foreground,
        minimumSize: const Size(36, 36),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        tapTargetSize: MaterialTapTargetSize.padded,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        ),
        textStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          letterSpacing: 0,
        ),
      ),
    );
  }

  static IconButtonThemeData _iconButtonTheme(Color foreground) {
    return IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: foreground,
        minimumSize: const Size(36, 36),
        tapTargetSize: MaterialTapTargetSize.padded,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
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
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      ),
      side: BorderSide(color: outline),
      backgroundColor: background,
      selectedColor: selected,
      labelStyle: TextStyle(
        color: label,
        fontWeight: FontWeight.w500,
        fontSize: 12,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      labelStyle: TextStyle(
        color: label,
        fontSize: 13,
        fontWeight: FontWeight.w400,
      ),
      floatingLabelStyle: TextStyle(
        color: focused,
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        borderSide: BorderSide(color: outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        borderSide: BorderSide(color: outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        borderSide: BorderSide(color: focused, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        borderSide: const BorderSide(color: Colors.red),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
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
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      ),
      behavior: SnackBarBehavior.floating,
      elevation: 2,
    );
  }

  static DialogThemeData _dialogTheme(Color background) {
    return DialogThemeData(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusDialog),
      ),
    );
  }

  static PopupMenuThemeData _popupMenuTheme(Color background) {
    return PopupMenuThemeData(
      color: background,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
      ),
    );
  }

  static DrawerThemeData _drawerTheme(Color background, Color outline) {
    return DrawerThemeData(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
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
          top: Radius.circular(AppTheme.radiusLarge),
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
        minimumSize: const WidgetStatePropertyAll(Size(36, 32)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        ),
        tapTargetSize: MaterialTapTargetSize.padded,
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
            borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
          ),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            letterSpacing: 0,
          ),
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
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
      ),
      collapsedShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
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
      radius: const Radius.circular(AppTheme.radiusSmall),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => thumb.withValues(
          alpha: states.contains(WidgetState.dragged) ? 0.6 : 0.4,
        ),
      ),
      trackColor: WidgetStatePropertyAll(track.withValues(alpha: 0.2)),
    );
  }
}
