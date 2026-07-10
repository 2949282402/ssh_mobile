part of 'terminal_screen.dart';

class _TerminalSettingsSnapshot {
  final AppLanguage language;
  final bool isDarkMode;
  final String terminalThemeId;
  final String terminalFontFamily;

  const _TerminalSettingsSnapshot({
    required this.language,
    required this.isDarkMode,
    required this.terminalThemeId,
    required this.terminalFontFamily,
  });

  factory _TerminalSettingsSnapshot.from(AppSettings settings) {
    return _TerminalSettingsSnapshot(
      language: settings.language,
      isDarkMode: settings.isDarkMode,
      terminalThemeId: settings.terminalThemeId,
      terminalFontFamily: settings.terminalFontFamily,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _TerminalSettingsSnapshot &&
        other.language == language &&
        other.isDarkMode == isDarkMode &&
        other.terminalThemeId == terminalThemeId &&
        other.terminalFontFamily == terminalFontFamily;
  }

  @override
  int get hashCode =>
      Object.hash(language, isDarkMode, terminalThemeId, terminalFontFamily);
}

class _SessionSwitcherAction {
  final String sessionId;
  final bool close;

  const _SessionSwitcherAction.switchTo(this.sessionId) : close = false;
  const _SessionSwitcherAction.close(this.sessionId) : close = true;
}

enum _TerminalEditAction { selectCopy, copy, paste, selectAll }

enum _NewWindowAction { current, editCurrent, addNew }
