part of '../terminal_screen.dart';

class _TerminalSettingsSnapshot {
  final AppLanguage language;
  final bool isDarkMode;

  const _TerminalSettingsSnapshot({
    required this.language,
    required this.isDarkMode,
  });

  factory _TerminalSettingsSnapshot.from(AppSettings settings) {
    return _TerminalSettingsSnapshot(
      language: settings.language,
      isDarkMode: settings.isDarkMode,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _TerminalSettingsSnapshot &&
        other.language == language &&
        other.isDarkMode == isDarkMode;
  }

  @override
  int get hashCode => Object.hash(language, isDarkMode);
}

class _SessionSwitcherAction {
  final String sessionId;
  final bool close;

  const _SessionSwitcherAction.switchTo(this.sessionId) : close = false;
  const _SessionSwitcherAction.close(this.sessionId) : close = true;
}

enum _TerminalEditAction {
  selectCopy,
  copy,
  paste,
  selectAll,
}

enum _NewWindowAction {
  current,
  editCurrent,
  addNew,
}
