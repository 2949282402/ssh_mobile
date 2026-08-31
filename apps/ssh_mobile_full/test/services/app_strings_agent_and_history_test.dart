// Coverage tests for every localized string in AppStrings.

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  const en = AppStrings(AppLanguage.en);
  const zh = AppStrings(AppLanguage.zh);

  group('agent trace, history, and background permission strings', () {
    test(
      'every AppStrings agent trace, history, and background string is localized',
      () {
        _expectLocalized(en.agentTraceTitle, zh.agentTraceTitle);
        _expectLocalized(
          en.agentTraceLoadFailedTitle,
          zh.agentTraceLoadFailedTitle,
        );
        _expectLocalized(
          en.agentTraceLoadFailedMessage,
          zh.agentTraceLoadFailedMessage,
        );
        _expectLocalized(en.agentTraceOverview, zh.agentTraceOverview);
        _expectLocalized(
          en.agentTraceEventCount(2),
          zh.agentTraceEventCount(2),
        );
        _expectLocalized(
          en.agentTraceNoMatchingTitle,
          zh.agentTraceNoMatchingTitle,
        );
        _expectLocalized(
          en.agentTraceNoMatchingMessage,
          zh.agentTraceNoMatchingMessage,
        );
        _expectLocalized(en.agentTraceEmptyTitle, zh.agentTraceEmptyTitle);
        _expectLocalized(en.agentTraceFilterAll, zh.agentTraceFilterAll);
        _expectLocalized(en.agentTraceFilterTools, zh.agentTraceFilterTools);
        _expectLocalized(
          en.agentTraceFilterApprovals,
          zh.agentTraceFilterApprovals,
        );
        _expectLocalized(
          en.agentTraceFilterBlocked,
          zh.agentTraceFilterBlocked,
        );
        _expectLocalized(en.agentTraceFilterErrors, zh.agentTraceFilterErrors);
        _expectLocalized(en.agentTraceMetricStatus, zh.agentTraceMetricStatus);
        _expectLocalized(en.agentTraceMetricRun, zh.agentTraceMetricRun);
        _expectLocalized(en.agentTraceMetricModel, zh.agentTraceMetricModel);
        _expectLocalized(en.agentTraceMetricHelper, zh.agentTraceMetricHelper);
        _expectLocalized(en.agentTraceMetricAudit, zh.agentTraceMetricAudit);
        _expectLocalized(
          en.agentTraceMetricElapsed,
          zh.agentTraceMetricElapsed,
        );
        _expectLocalized(en.agentTraceMetricPrompt, zh.agentTraceMetricPrompt);
        _expectLocalized(
          en.agentTraceMetricCompletion,
          zh.agentTraceMetricCompletion,
        );
        _expectLocalized(en.agentTraceMetricTotal, zh.agentTraceMetricTotal);
        _expectLocalized(en.agentTraceMetricTools, zh.agentTraceMetricTools);
        _expectLocalized(
          en.agentTraceMetricCacheHits,
          zh.agentTraceMetricCacheHits,
        );
        _expectLocalized(
          en.agentTraceMetricDedupBlocked,
          zh.agentTraceMetricDedupBlocked,
        );
        _expectLocalized(
          en.agentTraceMetricApprovals,
          zh.agentTraceMetricApprovals,
        );
        _expectLocalized(
          en.agentTraceMetricApproved,
          zh.agentTraceMetricApproved,
        );
        _expectLocalized(en.agentTraceMetricAudits, zh.agentTraceMetricAudits);
        _expectLocalized(
          en.agentTraceMetricHelperFanout,
          zh.agentTraceMetricHelperFanout,
        );
        _expectLocalized(
          en.agentTraceSelectedTools,
          zh.agentTraceSelectedTools,
        );
        _expectLocalized(
          en.agentTraceMemorySources,
          zh.agentTraceMemorySources,
        );
        _expectLocalized(en.agentTraceFinalReason, zh.agentTraceFinalReason);
        _expectLocalized(en.agentTraceCopyRaw, zh.agentTraceCopyRaw);
        _expectLocalized(en.agentTraceCopied, zh.agentTraceCopied);
        _expectLocalized(en.agentTraceTruncated, zh.agentTraceTruncated);
        _expectLocalized(
          en.agentTraceStatusSuccess,
          zh.agentTraceStatusSuccess,
        );
        _expectLocalized(en.agentTraceStatusFailed, zh.agentTraceStatusFailed);
        _expectLocalized(en.agentRunCompleted, zh.agentRunCompleted);
        _expectLocalized(en.agentRunNeedsAttention, zh.agentRunNeedsAttention);
        _expectLocalized(en.agentRunTools(1), zh.agentRunTools(1));
        _expectLocalized(en.agentRunTools(2), zh.agentRunTools(2));
        _expectLocalized(
          en.agentRunApprovals(2, 2),
          zh.agentRunApprovals(2, 2),
        );
        _expectLocalized(en.agentRunBlocked(2), zh.agentRunBlocked(2));
        _expectLocalized(
          en.agentTraceOutcomeCancelled,
          zh.agentTraceOutcomeCancelled,
        );
        _expectLocalized(
          en.agentTraceOutcomeModelError,
          zh.agentTraceOutcomeModelError,
        );
        _expectLocalized(
          en.agentTraceOutcomeToolError,
          zh.agentTraceOutcomeToolError,
        );
        _expectLocalized(
          en.agentTraceOutcomeApprovalRejected,
          zh.agentTraceOutcomeApprovalRejected,
        );
        _expectLocalized(
          en.agentTraceOutcomeApprovalUnavailable,
          zh.agentTraceOutcomeApprovalUnavailable,
        );
        _expectLocalized(
          en.agentTraceOutcomeBudgetAuditRejected,
          zh.agentTraceOutcomeBudgetAuditRejected,
        );
        _expectLocalized(
          en.agentTraceOutcomeLoopGuardBlocked,
          zh.agentTraceOutcomeLoopGuardBlocked,
        );
        _expectLocalized(
          en.agentTraceOutcomePlanModeBlocked,
          zh.agentTraceOutcomePlanModeBlocked,
        );
        _expectLocalized(
          en.agentTraceOutcomePlanExecutionBlocked,
          zh.agentTraceOutcomePlanExecutionBlocked,
        );
        _expectLocalized(
          en.agentTraceOutcomeAgentLoopStopped,
          zh.agentTraceOutcomeAgentLoopStopped,
        );
        _expectLocalized(
          en.agentTraceOutcomeUnknown,
          zh.agentTraceOutcomeUnknown,
        );
        _expectLocalized(
          en.agentTraceOutcomeLabel('success'),
          zh.agentTraceOutcomeLabel('success'),
        );
        _expectLocalized(
          en.agentTraceOutcomeLabel('completed'),
          zh.agentTraceOutcomeLabel('completed'),
        );
        _expectLocalized(
          en.agentTraceOutcomeLabel('cancelled'),
          zh.agentTraceOutcomeLabel('cancelled'),
        );
        _expectLocalized(
          en.agentTraceOutcomeLabel('modelError'),
          zh.agentTraceOutcomeLabel('modelError'),
        );
        _expectLocalized(
          en.agentTraceOutcomeLabel('toolError'),
          zh.agentTraceOutcomeLabel('toolError'),
        );
        _expectLocalized(
          en.agentTraceOutcomeLabel('approvalRejected'),
          zh.agentTraceOutcomeLabel('approvalRejected'),
        );
        _expectLocalized(
          en.agentTraceOutcomeLabel('approvalUnavailable'),
          zh.agentTraceOutcomeLabel('approvalUnavailable'),
        );
        _expectLocalized(
          en.agentTraceOutcomeLabel('budgetAuditRejected'),
          zh.agentTraceOutcomeLabel('budgetAuditRejected'),
        );
        _expectLocalized(
          en.agentTraceOutcomeLabel('loopGuardBlocked'),
          zh.agentTraceOutcomeLabel('loopGuardBlocked'),
        );
        _expectLocalized(
          en.agentTraceOutcomeLabel('planModeBlocked'),
          zh.agentTraceOutcomeLabel('planModeBlocked'),
        );
        _expectLocalized(
          en.agentTraceOutcomeLabel('planExecutionBlocked'),
          zh.agentTraceOutcomeLabel('planExecutionBlocked'),
        );
        _expectLocalized(
          en.agentTraceOutcomeLabel('agentLoopStopped'),
          zh.agentTraceOutcomeLabel('agentLoopStopped'),
        );
        _expectLocalized(
          en.agentTraceOutcomeLabel('unknown-other'),
          zh.agentTraceOutcomeLabel('unknown-other'),
        );
        _expectLocalized(en.connectionHistoryHint, zh.connectionHistoryHint);
        _expectLocalized(
          en.connectionHistoryCount(2),
          zh.connectionHistoryCount(2),
        );
        _expectLocalized(
          en.loadingConnectionHistory,
          zh.loadingConnectionHistory,
        );
        _expectLocalized(
          en.connectionHistoryLoadFailed,
          zh.connectionHistoryLoadFailed,
        );
        _expectLocalized(
          en.connectionHistoryLoadFailedHint,
          zh.connectionHistoryLoadFailedHint,
        );
        _expectLocalized(en.noConnectionHistory, zh.noConnectionHistory);
        _expectLocalized(
          en.noConnectionHistoryHint,
          zh.noConnectionHistoryHint,
        );
        _expectLocalized(
          en.historyUpdatedAt('sample'),
          zh.historyUpdatedAt('sample'),
        );
        _expectLocalized(en.deleteHistoryRecord, zh.deleteHistoryRecord);
        _expectLocalized(
          en.deleteHistoryRecordFailed,
          zh.deleteHistoryRecordFailed,
        );
        _expectLocalized(
          en.copyCleanupCommandFailed,
          zh.copyCleanupCommandFailed,
        );
        _expectLocalized(
          en.backgroundConnectionSettings,
          zh.backgroundConnectionSettings,
        );
        _expectLocalized(
          en.enableBackgroundPermission,
          zh.enableBackgroundPermission,
        );
        _expectLocalized(
          en.backgroundPermissionGuide,
          zh.backgroundPermissionGuide,
        );
        _expectLocalized(
          en.backgroundChecklistTitle,
          zh.backgroundChecklistTitle,
        );
        _expectLocalized(
          en.allowBackgroundActivity,
          zh.allowBackgroundActivity,
        );
        _expectLocalized(en.allowNotifications, zh.allowNotifications);
        _expectLocalized(
          en.relaxBatteryRestrictions,
          zh.relaxBatteryRestrictions,
        );
        _expectLocalized(en.adjustPowerLimit, zh.adjustPowerLimit);
        _expectLocalized(en.openAppSettings, zh.openAppSettings);
        _expectLocalized(en.settings, zh.settings);
        _expectLocalized(en.backgroundGuideNote, zh.backgroundGuideNote);
        _expectLocalized(en.enterApp, zh.enterApp);
        _expectLocalized(en.continueToApp, zh.continueToApp);
        _expectLocalized(en.powerLimitExempt, zh.powerLimitExempt);
        _expectLocalized(en.powerLimitUnknown, zh.powerLimitUnknown);
      },
    );
  });
}

void _expectLocalized(String english, String chinese) {
  expect(english, isNotEmpty);
  expect(chinese, isNotEmpty);
}
