// Coverage tests for every localized string in AppStrings.

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  const en = AppStrings(AppLanguage.en);
  const zh = AppStrings(AppLanguage.zh);

  group('AI, MCP, security, and feature settings strings', () {
    test(
      'every AppStrings AI, MCP, security, and feature settings string is localized',
      () {
        _expectLocalized(en.newChat, zh.newChat);
        _expectLocalized(en.branch, zh.branch);
        _expectLocalized(en.executeApprovedPlan, zh.executeApprovedPlan);
        _expectLocalized(en.copyReply, zh.copyReply);
        _expectLocalized(en.selectAndCopy, zh.selectAndCopy);
        _expectLocalized(en.editAndResend, zh.editAndResend);
        _expectLocalized(en.regenerate, zh.regenerate);
        _expectLocalized(en.createBranch, zh.createBranch);
        _expectLocalized(en.continue_, zh.continue_);
        _expectLocalized(en.replyCopied, zh.replyCopied);
        _expectLocalized(en.copyAll, zh.copyAll);
        _expectLocalized(en.appearance, zh.appearance);
        _expectLocalized(en.toolsAndAutomation, zh.toolsAndAutomation);
        _expectLocalized(en.aiSkillsHint, zh.aiSkillsHint);
        _expectLocalized(en.mcpServer, zh.mcpServer);
        _expectLocalized(en.mcpServerHint, zh.mcpServerHint);
        _expectLocalized(en.mcpHost, zh.mcpHost);
        _expectLocalized(en.mcpPort, zh.mcpPort);
        _expectLocalized(en.mcpServerToken, zh.mcpServerToken);
        _expectLocalized(en.mcpClientConfiguration, zh.mcpClientConfiguration);
        _expectLocalized(en.mcpCheckPort, zh.mcpCheckPort);
        _expectLocalized(en.mcpRestart, zh.mcpRestart);
        _expectLocalized(en.mcpRegenerateToken, zh.mcpRegenerateToken);
        _expectLocalized(en.mcpCopyCodex, zh.mcpCopyCodex);
        _expectLocalized(en.mcpCopyClaude, zh.mcpCopyClaude);
        _expectLocalized(en.mcpCopyGemini, zh.mcpCopyGemini);
        _expectLocalized(en.mcpApprovalMode, zh.mcpApprovalMode);
        _expectLocalized(
          en.mcpReviewConfiguredTools,
          zh.mcpReviewConfiguredTools,
        );
        _expectLocalized(
          en.mcpReviewConfiguredToolsHint,
          zh.mcpReviewConfiguredToolsHint,
        );
        _expectLocalized(en.mcpTrustedAgent, zh.mcpTrustedAgent);
        _expectLocalized(en.mcpTrustedAgentHint, zh.mcpTrustedAgentHint);
        _expectLocalized(en.mcpTrustedAgentActive, zh.mcpTrustedAgentActive);
        _expectLocalized(
          en.mcpTrustedAgentActiveHint,
          zh.mcpTrustedAgentActiveHint,
        );
        _expectLocalized(
          en.mcpTrustedAgentSafetyBoundary,
          zh.mcpTrustedAgentSafetyBoundary,
        );
        _expectLocalized(
          en.mcpSecondaryReviewTools,
          zh.mcpSecondaryReviewTools,
        );
        _expectLocalized(
          en.mcpSecondaryReviewToolsHint,
          zh.mcpSecondaryReviewToolsHint,
        );
        _expectLocalized(en.mcpNoReviewTools, zh.mcpNoReviewTools);
        _expectLocalized(
          en.mcpToolPolicyConsoleTitle,
          zh.mcpToolPolicyConsoleTitle,
        );
        _expectLocalized(
          en.mcpToolPolicyConsoleHint,
          zh.mcpToolPolicyConsoleHint,
        );
        _expectLocalized(
          en.mcpToolPolicyConsoleDetails,
          zh.mcpToolPolicyConsoleDetails,
        );
        _expectLocalized(en.mcpToolPolicyTitle, zh.mcpToolPolicyTitle);
        _expectLocalized(en.mcpToolPolicyHint, zh.mcpToolPolicyHint);
        _expectLocalized(en.mcpExposeExternally, zh.mcpExposeExternally);
        _expectLocalized(en.mcpSecondaryReview, zh.mcpSecondaryReview);
        _expectLocalized(en.mcpReviewRequired, zh.mcpReviewRequired);
        _expectLocalized(en.mcpExecutable, zh.mcpExecutable);
        _expectLocalized(en.mcpNoConfigurableTools, zh.mcpNoConfigurableTools);
        _expectLocalized(en.mcpNotExposed, zh.mcpNotExposed);
        _expectLocalized(en.mcpHidden, zh.mcpHidden);
        _expectLocalized(en.mcpHardHidden, zh.mcpHardHidden);
        _expectLocalized(en.mcpBlocked, zh.mcpBlocked);
        _expectLocalized(en.mcpReviewNotApplicable, zh.mcpReviewNotApplicable);
        _expectLocalized(en.mcpHardBoundaryHint, zh.mcpHardBoundaryHint);
        _expectLocalized(
          en.mcpTrustedAgentWarningTitle,
          zh.mcpTrustedAgentWarningTitle,
        );
        _expectLocalized(
          en.mcpTrustedAgentWarningBody,
          zh.mcpTrustedAgentWarningBody,
        );
        _expectLocalized(en.mcpEnableTrustedAgent, zh.mcpEnableTrustedAgent);
        _expectLocalized(en.mcpPortAvailable, zh.mcpPortAvailable);
        _expectLocalized(en.mcpPortOccupied, zh.mcpPortOccupied);
        _expectLocalized(en.mcpPortInvalidMessage, zh.mcpPortInvalidMessage);
        _expectLocalized(en.mcpPortRestartNeeded, zh.mcpPortRestartNeeded);
        _expectLocalized(en.mcpStopped, zh.mcpStopped);
        _expectLocalized(en.mcpCheckingPort, zh.mcpCheckingPort);
        _expectLocalized(en.mcpStarting, zh.mcpStarting);
        _expectLocalized(en.mcpRunningAt('sample'), zh.mcpRunningAt('sample'));
        _expectLocalized(en.mcpFailed, zh.mcpFailed);
        _expectLocalized(en.mcpTokenRegenerated, zh.mcpTokenRegenerated);
        _expectLocalized(en.mcpCopied, zh.mcpCopied);
        _expectLocalized(en.mcpApprovalQueueTitle, zh.mcpApprovalQueueTitle);
        _expectLocalized(
          en.mcpApprovalQueueSubtitle,
          zh.mcpApprovalQueueSubtitle,
        );
        _expectLocalized(en.mcpNoPendingApprovals, zh.mcpNoPendingApprovals);
        _expectLocalized(
          en.mcpApprovalQueueEmptyMessage,
          zh.mcpApprovalQueueEmptyMessage,
        );
        _expectLocalized(en.mcpApprovalTarget, zh.mcpApprovalTarget);
        _expectLocalized(en.mcpApprovalReason, zh.mcpApprovalReason);
        _expectLocalized(en.mcpApprovalRequested, zh.mcpApprovalRequested);
        _expectLocalized(en.mcpApprovalPath, zh.mcpApprovalPath);
        _expectLocalized(en.mcpApprovalBytes, zh.mcpApprovalBytes);
        _expectLocalized(en.mcpApprovalCommand, zh.mcpApprovalCommand);
        _expectLocalized(en.mcpApprovalPreview, zh.mcpApprovalPreview);
        _expectLocalized(en.mcpApprovalApprove, zh.mcpApprovalApprove);
        _expectLocalized(en.mcpApprovalExecuting, zh.mcpApprovalExecuting);
        _expectLocalized(en.mcpApprovalWaiting, zh.mcpApprovalWaiting);
        _expectLocalized(en.mcpRecentActivity, zh.mcpRecentActivity);
        _expectLocalized(en.mcpActivitySubtitle, zh.mcpActivitySubtitle);
        _expectLocalized(en.mcpActivityAll, zh.mcpActivityAll);
        _expectLocalized(en.mcpActivityClear, zh.mcpActivityClear);
        _expectLocalized(en.mcpActivityEmpty, zh.mcpActivityEmpty);
        _expectLocalized(en.mcpActivityClearTitle, zh.mcpActivityClearTitle);
        _expectLocalized(
          en.mcpActivityClearMessage,
          zh.mcpActivityClearMessage,
        );
        _expectLocalized(en.mcpActivitySuccess, zh.mcpActivitySuccess);
        _expectLocalized(en.mcpActivityDenied, zh.mcpActivityDenied);
        _expectLocalized(en.mcpActivityFailed, zh.mcpActivityFailed);
        _expectLocalized(en.security, zh.security);
        _expectLocalized(en.credentialCache, zh.credentialCache);
        _expectLocalized(en.credentialCacheHint, zh.credentialCacheHint);
        _expectLocalized(en.credentialCacheTimeout, zh.credentialCacheTimeout);
        _expectLocalized(
          en.notificationServerNames,
          zh.notificationServerNames,
        );
        _expectLocalized(
          en.notificationServerNamesHint,
          zh.notificationServerNamesHint,
        );
        _expectLocalized(en.dataBackup, zh.dataBackup);
        _expectLocalized(en.sftpLimits, zh.sftpLimits);
        _expectLocalized(en.sftpSettings, zh.sftpSettings);
        _expectLocalized(en.sftpLimitsHint, zh.sftpLimitsHint);
        _expectLocalized(en.sftpDownloadLimit, zh.sftpDownloadLimit);
        _expectLocalized(en.sftpTextPreviewLimit, zh.sftpTextPreviewLimit);
        _expectLocalized(en.sftpRichPreviewLimit, zh.sftpRichPreviewLimit);
        _expectLocalized(en.sftpEditLimit, zh.sftpEditLimit);
        _expectLocalized(en.sftpLimitDialogHint, zh.sftpLimitDialogHint);
        _expectLocalized(en.sftpLimitInvalid, zh.sftpLimitInvalid);
        _expectLocalized(
          en.sftpLimitRange('1 MB', '2 MB'),
          zh.sftpLimitRange('1 MB', '2 MB'),
        );
        _expectLocalized(en.terminalAppearance, zh.terminalAppearance);
        _expectLocalized(en.terminalAppearanceHint, zh.terminalAppearanceHint);
        _expectLocalized(en.lanShareSettings, zh.lanShareSettings);
        _expectLocalized(en.lanDeviceAlias, zh.lanDeviceAlias);
        _expectLocalized(en.lanDeviceId, zh.lanDeviceId);
        _expectLocalized(en.lanRelayServer, zh.lanRelayServer);
        _expectLocalized(en.lanRelayClear, zh.lanRelayClear);
        _expectLocalized(en.lanRelayConnect, zh.lanRelayConnect);
        _expectLocalized(en.lanRelayConnecting, zh.lanRelayConnecting);
        _expectLocalized(en.lanRelayDisconnect, zh.lanRelayDisconnect);
        _expectLocalized(
          en.lanRelayEnrollmentRequired,
          zh.lanRelayEnrollmentRequired,
        );
        _expectLocalized(
          en.lanRelayEnrollmentToken,
          zh.lanRelayEnrollmentToken,
        );
        _expectLocalized(
          en.lanRelayEnrollmentTokenHint,
          zh.lanRelayEnrollmentTokenHint,
        );
        _expectLocalized(en.lanRelayFailed, zh.lanRelayFailed);
        _expectLocalized(en.lanRouteDirect, zh.lanRouteDirect);
        _expectLocalized(en.lanRouteRelay, zh.lanRouteRelay);
        _expectLocalized(en.lanRouteUnknown, zh.lanRouteUnknown);
        _expectLocalized(en.lanPermissions, zh.lanPermissions);
        _expectLocalized(
          en.lanNotificationPermission,
          zh.lanNotificationPermission,
        );
        _expectLocalized(en.lanCameraPermission, zh.lanCameraPermission);
        _expectLocalized(en.openMcpSettings, zh.openMcpSettings);
        _expectLocalized(en.openMcpConsole, zh.openMcpConsole);
        _expectLocalized(en.openAiSkills, zh.openAiSkills);
        _expectLocalized(en.moreActions, zh.moreActions);
        _expectLocalized(en.featureSettings, zh.featureSettings);
        _expectLocalized(en.exportAppData, zh.exportAppData);
        _expectLocalized(en.importAppData, zh.importAppData);
        _expectLocalized(en.exportComplete, zh.exportComplete);
        _expectLocalized(en.importComplete, zh.importComplete);
        _expectLocalized(en.importAction, zh.importAction);
        _expectLocalized(en.importAppDataWarning, zh.importAppDataWarning);
        _expectLocalized(en.backupContainsSecrets, zh.backupContainsSecrets);
        _expectLocalized(en.exportFailed('sample'), zh.exportFailed('sample'));
        _expectLocalized(en.importFailed('sample'), zh.importFailed('sample'));
        _expectLocalized(en.developerMode, zh.developerMode);
        _expectLocalized(en.developerModeHint, zh.developerModeHint);
        _expectLocalized(en.developerPanel, zh.developerPanel);
        _expectLocalized(en.developerPanelFloating, zh.developerPanelFloating);
        _expectLocalized(
          en.developerPanelFloatingHint,
          zh.developerPanelFloatingHint,
        );
      },
    );
  });
}

void _expectLocalized(String english, String chinese) {
  expect(english, isNotEmpty);
  expect(chinese, isNotEmpty);
}
