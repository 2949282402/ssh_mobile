// Coverage tests for every localized string in AppStrings.

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  const en = AppStrings(AppLanguage.en);
  const zh = AppStrings(AppLanguage.zh);

  group('language, appearance, and connection strings', () {
    test(
      'every AppStrings language, appearance, and connection string is localized',
      () {
        expect(en.isEnglish, isTrue);
        expect(zh.isEnglish, isFalse);
        _expectLocalized(en.appTitle, zh.appTitle);
        _expectLocalized(en.switchToChinese, zh.switchToChinese);
        _expectLocalized(en.switchToEnglish, zh.switchToEnglish);
        _expectLocalized(en.languageLabel, zh.languageLabel);
        _expectLocalized(en.currentLanguageName, zh.currentLanguageName);
        _expectLocalized(en.defaultOption, zh.defaultOption);
        _expectLocalized(en.switchToLightMode, zh.switchToLightMode);
        _expectLocalized(en.switchToDarkMode, zh.switchToDarkMode);
        _expectLocalized(en.oledDarkMode, zh.oledDarkMode);
        _expectLocalized(en.colorPalette, zh.colorPalette);
        _expectLocalized(en.paletteMonochrome, zh.paletteMonochrome);
        _expectLocalized(en.paletteIndigo, zh.paletteIndigo);
        _expectLocalized(en.paletteOcean, zh.paletteOcean);
        _expectLocalized(en.paletteEmerald, zh.paletteEmerald);
        _expectLocalized(en.paletteRose, zh.paletteRose);
        _expectLocalized(en.paletteAmber, zh.paletteAmber);
        _expectLocalized(en.terminalTheme, zh.terminalTheme);
        _expectLocalized(en.customTerminalFont, zh.customTerminalFont);
        _expectLocalized(en.customTerminalFontHint, zh.customTerminalFontHint);
        _expectLocalized(en.serverListLayout, zh.serverListLayout);
        _expectLocalized(en.layoutList, zh.layoutList);
        _expectLocalized(en.layoutGrid, zh.layoutGrid);
        _expectLocalized(en.servers, zh.servers);
        _expectLocalized(en.server, zh.server);
        _expectLocalized(en.loadingServers, zh.loadingServers);
        _expectLocalized(en.windows, zh.windows);
        _expectLocalized(en.window, zh.window);
        _expectLocalized(en.active, zh.active);
        _expectLocalized(en.performanceMonitor, zh.performanceMonitor);
        _expectLocalized(en.monitor, zh.monitor);
        _expectLocalized(en.admin, zh.admin);
        _expectLocalized(en.logs, zh.logs);
        _expectLocalized(en.cancel, zh.cancel);
        _expectLocalized(en.create, zh.create);
        _expectLocalized(en.save, zh.save);
        _expectLocalized(en.saving, zh.saving);
        _expectLocalized(en.add, zh.add);
        _expectLocalized(en.edit, zh.edit);
        _expectLocalized(en.delete, zh.delete);
        _expectLocalized(en.close, zh.close);
        _expectLocalized(en.copy, zh.copy);
        _expectLocalized(en.remove, zh.remove);
        _expectLocalized(en.unknown, zh.unknown);
        _expectLocalized(en.addConnection, zh.addConnection);
        _expectLocalized(en.verifyAndSave, zh.verifyAndSave);
        _expectLocalized(
          en.deleteRemoteEntryConfirmPrompt,
          zh.deleteRemoteEntryConfirmPrompt,
        );
        _expectLocalized(
          en.deleteRemoteEntryConfirmLabel,
          zh.deleteRemoteEntryConfirmLabel,
        );
        _expectLocalized(
          en.deleteRemoteEntryConfirmMismatch,
          zh.deleteRemoteEntryConfirmMismatch,
        );
        _expectLocalized(
          en.uploadFileTooLarge('sample'),
          zh.uploadFileTooLarge('sample'),
        );
        _expectLocalized(en.uploadFileNoAccess, zh.uploadFileNoAccess);
        _expectLocalized(en.uploadCancelled, zh.uploadCancelled);
        _expectLocalized(
          en.downloadFileTooLarge('sample'),
          zh.downloadFileTooLarge('sample'),
        );
        _expectLocalized(en.downloadCancelled, zh.downloadCancelled);
        _expectLocalized(
          en.uploadingFile('sample'),
          zh.uploadingFile('sample'),
        );
        _expectLocalized(
          en.downloadingFile('sample'),
          zh.downloadingFile('sample'),
        );
        _expectLocalized(en.editConnection, zh.editConnection);
        _expectLocalized(en.noConnections, zh.noConnections);
        _expectLocalized(en.addHint, zh.addHint);
        _expectLocalized(en.reorderServer, zh.reorderServer);
        _expectLocalized(en.noMonitoringData, zh.noMonitoringData);
        _expectLocalized(en.newWindow, zh.newWindow);
        _expectLocalized(en.connectingTo('sample'), zh.connectingTo('sample'));
        _expectLocalized(en.establishingConnection, zh.establishingConnection);
        _expectLocalized(en.deleteConnectionTitle, zh.deleteConnectionTitle);
        _expectLocalized(
          en.deleteConnectionContent('sample'),
          zh.deleteConnectionContent('sample'),
        );
        _expectLocalized(
          en.deleteConnectionConfirm,
          zh.deleteConnectionConfirm,
        );
        _expectLocalized(en.connectionInfo, zh.connectionInfo);
        _expectLocalized(en.basicInfo, zh.basicInfo);
        _expectLocalized(en.authMethod, zh.authMethod);
        _expectLocalized(en.jumpHostOptional, zh.jumpHostOptional);
        _expectLocalized(en.advancedOptions, zh.advancedOptions);
        _expectLocalized(en.connectionName, zh.connectionName);
        _expectLocalized(en.connectionNameHint, zh.connectionNameHint);
        _expectLocalized(en.enterConnectionName, zh.enterConnectionName);
        _expectLocalized(en.hostAddress, zh.hostAddress);
        _expectLocalized(en.hostAddressHint, zh.hostAddressHint);
        _expectLocalized(en.enterHostAddress, zh.enterHostAddress);
        _expectLocalized(en.port, zh.port);
        _expectLocalized(en.invalidPort, zh.invalidPort);
        _expectLocalized(en.username, zh.username);
        _expectLocalized(en.enterUsername, zh.enterUsername);
        _expectLocalized(en.password, zh.password);
        _expectLocalized(en.privateKey, zh.privateKey);
        _expectLocalized(en.privateKeyPassword, zh.privateKeyPassword);
        _expectLocalized(en.passwordHint, zh.passwordHint);
        _expectLocalized(en.showPassword, zh.showPassword);
        _expectLocalized(en.hidePassword, zh.hidePassword);
        _expectLocalized(en.passwordRequired, zh.passwordRequired);
        _expectLocalized(en.sshPrivateKey, zh.sshPrivateKey);
        _expectLocalized(en.privateKeyRequired, zh.privateKeyRequired);
        _expectLocalized(en.jumpHost, zh.jumpHost);
        _expectLocalized(en.jumpHostHint, zh.jumpHostHint);
        _expectLocalized(en.jumpPort, zh.jumpPort);
        _expectLocalized(en.jumpUsername, zh.jumpUsername);
        _expectLocalized(en.optional, zh.optional);
        _expectLocalized(en.tmuxModeDescription, zh.tmuxModeDescription);
        _expectLocalized(en.sshModeDescription, zh.sshModeDescription);
        _expectLocalized(en.tmuxAutoDeleteMinutes, zh.tmuxAutoDeleteMinutes);
        _expectLocalized(en.tmuxAutoDeleteHelp, zh.tmuxAutoDeleteHelp);
        _expectLocalized(en.minOneMinute, zh.minOneMinute);
        _expectLocalized(en.max1440Minutes, zh.max1440Minutes);
        _expectLocalized(en.keepAliveTitle, zh.keepAliveTitle);
        _expectLocalized(en.keepAliveSubtitle, zh.keepAliveSubtitle);
        _expectLocalized(en.saveFailed('sample'), zh.saveFailed('sample'));
        _expectLocalized(en.saveFailedGuidance, zh.saveFailedGuidance);
        _expectLocalized(en.paste, zh.paste);
        _expectLocalized(en.serverSystem, zh.serverSystem);
        _expectLocalized(en.windowsTmuxUnavailable, zh.windowsTmuxUnavailable);
        _expectLocalized(
          en.windowsMonitoringDescription,
          zh.windowsMonitoringDescription,
        );
        _expectLocalized(
          en.linuxMonitoringDescription,
          zh.linuxMonitoringDescription,
        );
        _expectLocalized(
          en.saveWillCloseWindowsTitle,
          zh.saveWillCloseWindowsTitle,
        );
        _expectLocalized(
          en.saveWillCloseWindowsContent(2),
          zh.saveWillCloseWindowsContent(2),
        );
        _expectLocalized(en.saveAndDisconnect, zh.saveAndDisconnect);
        _expectLocalized(en.newTerminalWindow, zh.newTerminalWindow);
        _expectLocalized(en.windowName, zh.windowName);
        _expectLocalized(en.enterWindowName, zh.enterWindowName);
        _expectLocalized(en.duplicateWindowName, zh.duplicateWindowName);
        _expectLocalized(en.terminalWindows, zh.terminalWindows);
        _expectLocalized(
          en.terminalWindowsOverview(2, 2, 2),
          zh.terminalWindowsOverview(2, 2, 2),
        );
        _expectLocalized(
          en.terminalWindowsForServer(2, 2),
          zh.terminalWindowsForServer(2, 2),
        );
        _expectLocalized(en.selectedWindows(2), zh.selectedWindows(2));
        _expectLocalized(en.selectedWindowsHint(2), zh.selectedWindowsHint(2));
        _expectLocalized(en.selectedServers(2), zh.selectedServers(2));
        _expectLocalized(
          en.viewAllTerminalWindows(2),
          zh.viewAllTerminalWindows(2),
        );
        _expectLocalized(en.exitSelection, zh.exitSelection);
        _expectLocalized(en.selectAll, zh.selectAll);
        _expectLocalized(en.closeSelectedWindows, zh.closeSelectedWindows);
        _expectLocalized(en.connectionHistory, zh.connectionHistory);
        _expectLocalized(en.noOpenWindows, zh.noOpenWindows);
        _expectLocalized(en.openWindowsHint, zh.openWindowsHint);
        _expectLocalized(en.enterWindow, zh.enterWindow);
        _expectLocalized(en.renameTerminalWindow, zh.renameTerminalWindow);
        _expectLocalized(en.windowActions, zh.windowActions);
        _expectLocalized(en.closeWindow, zh.closeWindow);
        _expectLocalized(en.sessionMode, zh.sessionMode);
        _expectLocalized(en.tmuxSession, zh.tmuxSession);
        _expectLocalized(en.plainSshSession, zh.plainSshSession);
        _expectLocalized(en.createdAt, zh.createdAt);
        _expectLocalized(en.autoDestroy, zh.autoDestroy);
        _expectLocalized(en.memoryUsage, zh.memoryUsage);
        _expectLocalized(en.notAvailable, zh.notAvailable);
        _expectLocalized(
          en.autoDestroyAfter('sample'),
          zh.autoDestroyAfter('sample'),
        );
        _expectLocalized(
          en.autoDestroyAt('sample'),
          zh.autoDestroyAt('sample'),
        );
        _expectLocalized(en.durationMinutes(2), zh.durationMinutes(2));
        _expectLocalized(en.durationSeconds(2), zh.durationSeconds(2));
        _expectLocalized(en.connected, zh.connected);
        _expectLocalized(en.connecting, zh.connecting);
        _expectLocalized(en.connectionError, zh.connectionError);
        _expectLocalized(en.disconnected, zh.disconnected);
        _expectLocalized(
          en.closeWindowTitle('sample'),
          zh.closeWindowTitle('sample'),
        );
        _expectLocalized(en.closeTerminalWindow, zh.closeTerminalWindow);
        _expectLocalized(en.staleTmuxHint, zh.staleTmuxHint);
        _expectLocalized(en.copyCommand, zh.copyCommand);
        _expectLocalized(en.copiedCleanupCommand, zh.copiedCleanupCommand);
        _expectLocalized(
          en.closeSelectedContent(2),
          zh.closeSelectedContent(2),
        );
        _expectLocalized(en.developerLogs, zh.developerLogs);
        _expectLocalized(en.copyFilteredLogs, zh.copyFilteredLogs);
        _expectLocalized(en.clearLogs, zh.clearLogs);
        _expectLocalized(en.noLogs, zh.noLogs);
        _expectLocalized(en.noLogsForLevel, zh.noLogsForLevel);
        _expectLocalized(en.copiedFilteredLogs, zh.copiedFilteredLogs);
        _expectLocalized(en.logsCleared, zh.logsCleared);
        _expectLocalized(en.copySingleLog, zh.copySingleLog);
        _expectLocalized(en.expandFullLog, zh.expandFullLog);
        _expectLocalized(en.copiedSingleLog, zh.copiedSingleLog);
      },
    );
  });
}

void _expectLocalized(String english, String chinese) {
  expect(english, isNotEmpty);
  expect(chinese, isNotEmpty);
}
