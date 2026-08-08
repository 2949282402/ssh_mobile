import 'package:flutter_test/flutter_test.dart';
import 'package:feature_ai/ai_chat.dart';
import 'package:feature_ai/feature_ai.dart' as ai;
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  const warningReport = ai.AiRuntimeHealthReport(
    status: ai.AiRuntimeHealthStatus.warning,
    issues: [],
    raw: {},
  );
  const blockedReport = ai.AiRuntimeHealthReport(
    status: ai.AiRuntimeHealthStatus.blocking,
    issues: [],
    raw: {},
  );
  const strings = AiStrings(AppLanguage.en);

  test('warning confirmation dispatches the forced approval result', () async {
    final attempts = <bool>[];
    final feedback = <String>[];
    final dialogs = <bool>[];

    await runPlanApprovalUiFlow(
      strings: strings,
      approve: (forceAfterWarning) async {
        attempts.add(forceAfterWarning);
        return forceAfterWarning
            ? const ApprovePlanExecutionPlanChanged()
            : const ApprovePlanExecutionWarning(warningReport);
      },
      showRuntimeHealth: (report, allowContinue) async {
        dialogs.add(allowContinue);
        return true;
      },
      openLlmSettings: () async {},
      showFeedback: feedback.add,
    );

    expect(attempts, [false, true]);
    expect(dialogs, [true]);
    expect(feedback, [strings.planApprovalPlanChanged]);
  });

  test('cancelling a warning does not force approval', () async {
    final attempts = <bool>[];
    final feedback = <String>[];

    await runPlanApprovalUiFlow(
      strings: strings,
      approve: (forceAfterWarning) async {
        attempts.add(forceAfterWarning);
        return const ApprovePlanExecutionWarning(warningReport);
      },
      showRuntimeHealth: (report, allowContinue) async => false,
      openLlmSettings: () async {},
      showFeedback: feedback.add,
    );

    expect(attempts, [false]);
    expect(feedback, isEmpty);
  });

  test('blocked approval opens a non-continuable health dialog', () async {
    bool? allowContinue;
    await runPlanApprovalUiFlow(
      strings: strings,
      approve: (_) async => const ApprovePlanExecutionBlocked(blockedReport),
      showRuntimeHealth: (report, allow) async {
        expect(identical(report, blockedReport), isTrue);
        allowContinue = allow;
        return false;
      },
      openLlmSettings: () async {},
      showFeedback: (_) {},
    );
    expect(allowContinue, isFalse);
  });

  test('missing API key gives feedback and opens LLM settings', () async {
    var settingsOpenCount = 0;
    final feedback = <String>[];
    await runPlanApprovalUiFlow(
      strings: strings,
      approve: (_) async => const ApprovePlanExecutionApiKeyMissing(),
      showRuntimeHealth: (_, _) async => false,
      openLlmSettings: () async => settingsOpenCount += 1,
      showFeedback: feedback.add,
    );
    expect(settingsOpenCount, 1);
    expect(feedback, [strings.planApprovalApiKeyMissing]);
  });

  test(
    'non-dialog approval results have explicit localized feedback',
    () async {
      final cases = <ApprovePlanExecutionResult, String>{
        const ApprovePlanExecutionStarted(): strings.planApprovalStarting,
        const ApprovePlanExecutionNoPlan(): strings.planApprovalNoPlan,
        const ApprovePlanExecutionAlreadySending(): strings.aiActionInProgress,
        const ApprovePlanExecutionPlanChanged():
            strings.planApprovalPlanChanged,
        const ApprovePlanExecutionFailed(): strings.planApprovalFailed,
        const ApprovePlanExecutionCancelled(): strings.planApprovalCancelled,
      };

      for (final entry in cases.entries) {
        final feedback = <String>[];
        await runPlanApprovalUiFlow(
          strings: strings,
          approve: (_) async => entry.key,
          showRuntimeHealth: (_, _) async => false,
          openLlmSettings: () async {},
          showFeedback: feedback.add,
        );
        expect(feedback, [
          entry.value,
        ], reason: entry.key.runtimeType.toString());
      }
    },
  );
}
