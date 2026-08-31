// Coverage tests for every localized string in TerminalStrings.

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  const en = TerminalStrings(AppLanguage.en);
  const zh = TerminalStrings(AppLanguage.zh);

  group('terminal connection, window, and keyboard strings', () {
    test('every TerminalStrings terminal and keyboard string is localized', () {
      _expectLocalized(en.connected, zh.connected);
      _expectLocalized(en.connecting, zh.connecting);
      _expectLocalized(en.disconnected, zh.disconnected);
      _expectLocalized(en.fontSize, zh.fontSize);
      _expectLocalized(en.defaultTerminal, zh.defaultTerminal);
      _expectLocalized(en.currentServer, zh.currentServer);
      _expectLocalized(en.unknown, zh.unknown);
      _expectLocalized(en.smallerFont, zh.smallerFont);
      _expectLocalized(en.largerFont, zh.largerFont);
      _expectLocalized(en.switchToLightMode, zh.switchToLightMode);
      _expectLocalized(en.switchToDarkMode, zh.switchToDarkMode);
      _expectLocalized(en.newWindow, zh.newWindow);
      _expectLocalized(en.renameWindow, zh.renameWindow);
      _expectLocalized(en.switchWindow, zh.switchWindow);
      _expectLocalized(en.disconnect, zh.disconnect);
      _expectLocalized(en.reconnect, zh.reconnect);
      _expectLocalized(en.reconnecting, zh.reconnecting);
      _expectLocalized(en.connectingSession, zh.connectingSession);
      _expectLocalized(en.connectingSessionHint, zh.connectingSessionHint);
      _expectLocalized(en.connectionInterrupted, zh.connectionInterrupted);
      _expectLocalized(
        en.connectionInterruptedHint,
        zh.connectionInterruptedHint,
      );
      _expectLocalized(en.terminalConnectionError, zh.terminalConnectionError);
      _expectLocalized(
        en.terminalConnectionErrorStatus,
        zh.terminalConnectionErrorStatus,
      );
      _expectLocalized(
        en.terminalConnectionErrorHint,
        zh.terminalConnectionErrorHint,
      );
      _expectLocalized(en.manageWindows, zh.manageWindows);
      _expectLocalized(en.closeWindow, zh.closeWindow);
      _expectLocalized(en.restoringTerminalOutput, zh.restoringTerminalOutput);
      _expectLocalized(en.closeDisconnected, zh.closeDisconnected);
      _expectLocalized(en.openNewWindow, zh.openNewWindow);
      _expectLocalized(en.createFrom('sample'), zh.createFrom('sample'));
      _expectLocalized(en.cancel, zh.cancel);
      _expectLocalized(en.editServer, zh.editServer);
      _expectLocalized(en.addServer, zh.addServer);
      _expectLocalized(en.create, zh.create);
      _expectLocalized(en.connectingTo('sample'), zh.connectingTo('sample'));
      _expectLocalized(en.openingNewWindow, zh.openingNewWindow);
      _expectLocalized(
        en.connectionFailed('sample'),
        zh.connectionFailed('sample'),
      );
      _expectLocalized(
        en.tmuxMissingHint('sample'),
        zh.tmuxMissingHint('sample'),
      );
      _expectLocalized(en.currentWindow, zh.currentWindow);
      _expectLocalized(en.save, zh.save);
      _expectLocalized(en.windowName, zh.windowName);
      _expectLocalized(en.duplicateWindowName, zh.duplicateWindowName);
      _expectLocalized(en.addShortcut, zh.addShortcut);
      _expectLocalized(en.complexKeyboard, zh.complexKeyboard);
      _expectLocalized(en.advancedKeyboardHint, zh.advancedKeyboardHint);
      _expectLocalized(en.windowsKeyboard, zh.windowsKeyboard);
      _expectLocalized(en.windowsKeyboardHint, zh.windowsKeyboardHint);
      _expectLocalized(en.keyboardComposeMode, zh.keyboardComposeMode);
      _expectLocalized(en.keyboardDirectMode, zh.keyboardDirectMode);
      _expectLocalized(en.customizeQuickKeys, zh.customizeQuickKeys);
      _expectLocalized(en.keyboardLetters, zh.keyboardLetters);
      _expectLocalized(en.keyboardNavigation, zh.keyboardNavigation);
      _expectLocalized(en.keyboardSpace, zh.keyboardSpace);
      _expectLocalized(en.keyboardBackspace, zh.keyboardBackspace);
      _expectLocalized(en.keyboardEnter, zh.keyboardEnter);
      _expectLocalized(en.quickKeysTitle, zh.quickKeysTitle);
      _expectLocalized(en.quickKeysHint, zh.quickKeysHint);
      _expectLocalized(en.quickKeysAtLeastOne, zh.quickKeysAtLeastOne);
      _expectLocalized(en.resetQuickKeys, zh.resetQuickKeys);
      _expectLocalized(en.done, zh.done);
      _expectLocalized(en.shellSymbols, zh.shellSymbols);
      _expectLocalized(en.controlShortcuts, zh.controlShortcuts);
      _expectLocalized(en.moreKeys, zh.moreKeys);
      _expectLocalized(en.moreKeysHint, zh.moreKeysHint);
      _expectLocalized(en.multilineHint, zh.multilineHint);
      _expectLocalized(en.commandComposer, zh.commandComposer);
      _expectLocalized(en.commandComposerHint, zh.commandComposerHint);
      _expectLocalized(en.pasteIntoCommand, zh.pasteIntoCommand);
      _expectLocalized(en.clearCommand, zh.clearCommand);
      _expectLocalized(en.send, zh.send);
      _expectLocalized(en.label, zh.label);
      _expectLocalized(en.command, zh.command);
      _expectLocalized(en.add, zh.add);
      _expectLocalized(en.removeShortcut, zh.removeShortcut);
      _expectLocalized(
        en.removeShortcutContent('sample'),
        zh.removeShortcutContent('sample'),
      );
      _expectLocalized(en.remove, zh.remove);
      _expectLocalized(en.selectCopy, zh.selectCopy);
      _expectLocalized(en.copy, zh.copy);
      _expectLocalized(en.paste, zh.paste);
      _expectLocalized(en.closeDisconnectedTitle, zh.closeDisconnectedTitle);
      _expectLocalized(
        en.disconnectContent('sample'),
        zh.disconnectContent('sample'),
      );
      _expectLocalized(
        en.closeDisconnectedContent('sample'),
        zh.closeDisconnectedContent('sample'),
      );
      _expectLocalized(en.copyAll, zh.copyAll);
      _expectLocalized(en.terminalOutput, zh.terminalOutput);
      _expectLocalized(en.terminalOutputSnapshot, zh.terminalOutputSnapshot);
      _expectLocalized(
        en.terminalOutputSelectionHint,
        zh.terminalOutputSelectionHint,
      );
      _expectLocalized(en.readOnly, zh.readOnly);
      _expectLocalized(en.copyingTerminalOutput, zh.copyingTerminalOutput);
      _expectLocalized(
        en.copyTerminalOutputFailed,
        zh.copyTerminalOutputFailed,
      );
      _expectLocalized(
        en.terminalOutputSummary(1, 1),
        zh.terminalOutputSummary(1, 1),
      );
      _expectLocalized(
        en.terminalOutputSummary(2, 2),
        zh.terminalOutputSummary(2, 2),
      );
      _expectLocalized(en.moreActions, zh.moreActions);
      _expectLocalized(en.terminalAppearance, zh.terminalAppearance);
      _expectLocalized(en.navigationShell, zh.navigationShell);
      _expectLocalized(en.editControl, zh.editControl);
      _expectLocalized(en.functionKeys, zh.functionKeys);
    });
  });
}

void _expectLocalized(String english, String chinese) {
  expect(english, isNotEmpty);
  expect(chinese, isNotEmpty);
}
