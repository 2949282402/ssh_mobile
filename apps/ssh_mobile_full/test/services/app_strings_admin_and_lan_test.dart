// Coverage tests for every localized string in AppStrings.

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  const en = AppStrings(AppLanguage.en);
  const zh = AppStrings(AppLanguage.zh);

  group('system admin and LAN share strings', () {
    test('every AppStrings system admin and LAN share string is localized', () {
      _expectLocalized(en.systemAdmin, zh.systemAdmin);
      _expectLocalized(en.selectConnectedServer, zh.selectConnectedServer);
      _expectLocalized(en.noConnectedServers, zh.noConnectedServers);
      _expectLocalized(en.rootRequiredMsg, zh.rootRequiredMsg);
      _expectLocalized(en.nonLinuxMsg, zh.nonLinuxMsg);
      _expectLocalized(en.activeSessions, zh.activeSessions);
      _expectLocalized(en.userAccounts, zh.userAccounts);
      _expectLocalized(en.systemServices, zh.systemServices);
      _expectLocalized(en.listeningPorts, zh.listeningPorts);
      _expectLocalized(en.applications, zh.applications);
      _expectLocalized(en.systemPower, zh.systemPower);
      _expectLocalized(en.lockUser, zh.lockUser);
      _expectLocalized(en.unlockUser, zh.unlockUser);
      _expectLocalized(en.statusLocked, zh.statusLocked);
      _expectLocalized(en.changePassword, zh.changePassword);
      _expectLocalized(en.viewHomeDir, zh.viewHomeDir);
      _expectLocalized(en.usageStats, zh.usageStats);
      _expectLocalized(en.storageUsed, zh.storageUsed);
      _expectLocalized(en.memoryUsed, zh.memoryUsed);
      _expectLocalized(en.activeProcesses, zh.activeProcesses);
      _expectLocalized(en.changePasswordTitle, zh.changePasswordTitle);
      _expectLocalized(en.enterNewPassword, zh.enterNewPassword);
      _expectLocalized(en.passwordChangedSuccess, zh.passwordChangedSuccess);
      _expectLocalized(en.actionConfirm, zh.actionConfirm);
      _expectLocalized(en.serviceStart, zh.serviceStart);
      _expectLocalized(en.serviceStop, zh.serviceStop);
      _expectLocalized(en.serviceRestart, zh.serviceRestart);
      _expectLocalized(en.serviceEnable, zh.serviceEnable);
      _expectLocalized(en.serviceDisable, zh.serviceDisable);
      _expectLocalized(en.rebootServer, zh.rebootServer);
      _expectLocalized(en.shutdownServer, zh.shutdownServer);
      _expectLocalized(en.powerConfirmContent, zh.powerConfirmContent);
      _expectLocalized(en.createUser, zh.createUser);
      _expectLocalized(en.grantSudo, zh.grantSudo);
      _expectLocalized(en.revokeSudo, zh.revokeSudo);
      _expectLocalized(en.loginShell, zh.loginShell);
      _expectLocalized(en.userCreatedSuccess, zh.userCreatedSuccess);
      _expectLocalized(en.sudoStatus, zh.sudoStatus);
      _expectLocalized(en.normalUser, zh.normalUser);
      _expectLocalized(en.administrator, zh.administrator);
      _expectLocalized(en.refreshAll, zh.refreshAll);
      _expectLocalized(en.verifyingPrivilege, zh.verifyingPrivilege);
      _expectLocalized(en.reconnectAsRootMsg, zh.reconnectAsRootMsg);
      _expectLocalized(en.systemOmAdmin, zh.systemOmAdmin);
      _expectLocalized(en.adminRootAccess, zh.adminRootAccess);
      _expectLocalized(en.adminSnapshotAccess, zh.adminSnapshotAccess);
      _expectLocalized(en.adminConnectionFailed, zh.adminConnectionFailed);
      _expectLocalized(en.adminSelectServer, zh.adminSelectServer);
      _expectLocalized(
        en.adminLinuxManagementHint,
        zh.adminLinuxManagementHint,
      );
      _expectLocalized(en.adminConnectAsRoot, zh.adminConnectAsRoot);
      _expectLocalized(en.selectServerToManage, zh.selectServerToManage);
      _expectLocalized(en.backToHome, zh.backToHome);
      _expectLocalized(en.systemPowerHint, zh.systemPowerHint);
      _expectLocalized(en.confirm, zh.confirm);
      _expectLocalized(en.searchService, zh.searchService);
      _expectLocalized(en.searchPort, zh.searchPort);
      _expectLocalized(en.searchSessions, zh.searchSessions);
      _expectLocalized(en.searchAccounts, zh.searchAccounts);
      _expectLocalized(en.killSession, zh.killSession);
      _expectLocalized(en.killAction, zh.killAction);
      _expectLocalized(
        en.killSessionConfirm('alice', 'pts/0'),
        zh.killSessionConfirm('alice', 'pts/0'),
      );
      _expectLocalized(en.omServers, zh.omServers);
      _expectLocalized(en.notConnected, zh.notConnected);
      _expectLocalized(en.connectingEllipsis, zh.connectingEllipsis);
      _expectLocalized(en.lanShare, zh.lanShare);
      _expectLocalized(
        en.networkIncomingTransferTitle,
        zh.networkIncomingTransferTitle,
      );
      _expectLocalized(
        en.networkIncomingTransferDescription('device-1', 'photo.png', '2 MB'),
        zh.networkIncomingTransferDescription('device-1', 'photo.png', '2 MB'),
      );
      _expectLocalized(en.accept, zh.accept);
      _expectLocalized(en.reject, zh.reject);
      _expectLocalized(en.clear, zh.clear);
      _expectLocalized(en.lanShareScan, zh.lanShareScan);
      _expectLocalized(en.lanShareScanning, zh.lanShareScanning);
      _expectLocalized(en.lanShareRadarHint, zh.lanShareRadarHint);
      _expectLocalized(
        en.lanShareRadarStoppedHint,
        zh.lanShareRadarStoppedHint,
      );
      _expectLocalized(en.lanShareNoDevices, zh.lanShareNoDevices);
      _expectLocalized(
        en.lanShareNoDevicesRefreshHint,
        zh.lanShareNoDevicesRefreshHint,
      );
      _expectLocalized(
        en.lanShareInitializationFailed,
        zh.lanShareInitializationFailed,
      );
      _expectLocalized(en.lanShareWebShare, zh.lanShareWebShare);
      _expectLocalized(en.lanShareWebShareHint, zh.lanShareWebShareHint);
      _expectLocalized(en.lanSharePinPairing, zh.lanSharePinPairing);
      _expectLocalized(en.lanSharePinPrompt, zh.lanSharePinPrompt);
      _expectLocalized(en.lanSharePinMismatch, zh.lanSharePinMismatch);
      _expectLocalized(en.lanSharePinLocked, zh.lanSharePinLocked);
      _expectLocalized(en.lanShareTrustDevice, zh.lanShareTrustDevice);
      _expectLocalized(en.lanShareTrusted, zh.lanShareTrusted);
      _expectLocalized(en.lanShareSendClipboard, zh.lanShareSendClipboard);
      _expectLocalized(en.lanShareSendFiles, zh.lanShareSendFiles);
      _expectLocalized(en.lanShareSelectImage, zh.lanShareSelectImage);
      _expectLocalized(en.lanShareSelectVideo, zh.lanShareSelectVideo);
      _expectLocalized(en.lanShareSelectFile, zh.lanShareSelectFile);
      _expectLocalized(en.lanShareClipboard, zh.lanShareClipboard);
      _expectLocalized(en.lanShareSendFolder, zh.lanShareSendFolder);
      _expectLocalized(en.lanShareSendText, zh.lanShareSendText);
      _expectLocalized(en.lanShareSending, zh.lanShareSending);
      _expectLocalized(en.lanShareReceiving, zh.lanShareReceiving);
      _expectLocalized(en.lanShareCompleted, zh.lanShareCompleted);
      _expectLocalized(en.lanShareFailed, zh.lanShareFailed);
      _expectLocalized(en.lanShareCancelled, zh.lanShareCancelled);
      _expectLocalized(en.lanShareRecall, zh.lanShareRecall);
      _expectLocalized(en.lanShareRecalled, zh.lanShareRecalled);
      _expectLocalized(en.lanShareRecallSuccess, zh.lanShareRecallSuccess);
      _expectLocalized(en.lanShareSavedToGallery, zh.lanShareSavedToGallery);
      _expectLocalized(
        en.lanShareSavedToDownloads,
        zh.lanShareSavedToDownloads,
      );
      _expectLocalized(en.lanShareSaveFailed, zh.lanShareSaveFailed);
      _expectLocalized(en.lanShareOpenBrowser, zh.lanShareOpenBrowser);
      _expectLocalized(en.lanShareConnectServer, zh.lanShareConnectServer);
      _expectLocalized(en.lanShareCopyText, zh.lanShareCopyText);
      _expectLocalized(en.lanShareCopyAll, zh.lanShareCopyAll);
      _expectLocalized(en.lanShareSelectToCopy, zh.lanShareSelectToCopy);
      _expectLocalized(en.lanShareSendToNearby, zh.lanShareSendToNearby);
      _expectLocalized(en.lanShareTransferHistory, zh.lanShareTransferHistory);
      _expectLocalized(en.lanShareNoHistory, zh.lanShareNoHistory);
      _expectLocalized(en.lanShareClearHistory, zh.lanShareClearHistory);
      _expectLocalized(en.lanShareFileExpired, zh.lanShareFileExpired);
      _expectLocalized(en.lanShareDragDropHint, zh.lanShareDragDropHint);
      _expectLocalized(en.lanShareStorageFull, zh.lanShareStorageFull);
      _expectLocalized(en.lanShareExport, zh.lanShareExport);
      _expectLocalized(en.lanShareOffline, zh.lanShareOffline);
      _expectLocalized(en.lanShareOnline, zh.lanShareOnline);
      _expectLocalized(
        en.lanShareDeviceOfflineHint,
        zh.lanShareDeviceOfflineHint,
      );
      _expectLocalized(
        en.lanShareClearChatHistory,
        zh.lanShareClearChatHistory,
      );
      _expectLocalized(en.lanShareForgetDevice, zh.lanShareForgetDevice);
      _expectLocalized(en.lanShareForgetConfirm, zh.lanShareForgetConfirm);
      _expectLocalized(
        en.lanShareForgetConfirmMessage,
        zh.lanShareForgetConfirmMessage,
      );
      _expectLocalized(en.lanShareReauthenticate, zh.lanShareReauthenticate);
      _expectLocalized(
        en.lanShareOfflineReauthHint,
        zh.lanShareOfflineReauthHint,
      );
      _expectLocalized(en.lanShareDeleteMessage, zh.lanShareDeleteMessage);
      _expectLocalized(en.lanShareChatInputHint, zh.lanShareChatInputHint);
      _expectLocalized(
        en.lanShareMessageSummaryRecalled,
        zh.lanShareMessageSummaryRecalled,
      );
      _expectLocalized(
        en.lanShareMessageSummaryImage,
        zh.lanShareMessageSummaryImage,
      );
      _expectLocalized(
        en.lanShareMessageSummaryVideo,
        zh.lanShareMessageSummaryVideo,
      );
      _expectLocalized(
        en.lanShareMessageSummaryAudio,
        zh.lanShareMessageSummaryAudio,
      );
      _expectLocalized(
        en.lanShareMessageSummaryFile,
        zh.lanShareMessageSummaryFile,
      );
      _expectLocalized(en.lanShareScanOrAdd, zh.lanShareScanOrAdd);
      _expectLocalized(en.lanShareManualConnect, zh.lanShareManualConnect);
      _expectLocalized(en.lanShareInputIpPort, zh.lanShareInputIpPort);
      _expectLocalized(en.lanShareConnect, zh.lanShareConnect);
      _expectLocalized(en.lanShareScanQrCode, zh.lanShareScanQrCode);
      _expectLocalized(en.lanShareInvalidAddress, zh.lanShareInvalidAddress);
      _expectLocalized(
        en.lanShareCameraPermissionDenied,
        zh.lanShareCameraPermissionDenied,
      );
      _expectLocalized(en.lanShareDeviceList, zh.lanShareDeviceList);
    });
  });
}

void _expectLocalized(String english, String chinese) {
  expect(english, isNotEmpty);
  expect(chinese, isNotEmpty);
}
