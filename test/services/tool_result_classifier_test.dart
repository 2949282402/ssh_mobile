import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/llm_chat_service.dart';

void main() {
  group('ToolResultClassifier tests', () {
    test('classifies empty results correctly', () {
      final qEmptyString = ToolResultClassifier.classify(
        toolName: 'cmd',
        resultJson: '',
        outcome: 'success',
        approvalRequired: false,
        approved: false,
        cacheHit: false,
        dedupBlocked: false,
      );
      final qEmptyMap = ToolResultClassifier.classify(
        toolName: 'cmd',
        resultJson: '{}',
        outcome: 'success',
        approvalRequired: false,
        approved: false,
        cacheHit: false,
        dedupBlocked: false,
      );
      final qEmptyList = ToolResultClassifier.classify(
        toolName: 'cmd',
        resultJson: '[]',
        outcome: 'success',
        approvalRequired: false,
        approved: false,
        cacheHit: false,
        dedupBlocked: false,
      );

      expect(qEmptyString, ToolResultQuality.empty);
      expect(qEmptyMap, ToolResultQuality.empty);
      expect(qEmptyList, ToolResultQuality.empty);

      final hintEn = ToolResultClassifier.getSystemHint(
          'cmd', ToolResultQuality.empty, AppLanguage.en);
      final hintZh = ToolResultClassifier.getSystemHint(
          'cmd', ToolResultQuality.empty, AppLanguage.zh);

      expect(hintEn, contains('returned an empty result'));
      expect(hintZh, contains('返回了空结果'));
    });

    test('classifies error results correctly', () {
      final qErrorOutcome = ToolResultClassifier.classify(
        toolName: 'cmd',
        resultJson: '{"other":"val"}',
        outcome: 'tool_error',
        approvalRequired: false,
        approved: false,
        cacheHit: false,
        dedupBlocked: false,
      );
      final qErrorJson = ToolResultClassifier.classify(
        toolName: 'cmd',
        resultJson: '{"error":"something went wrong"}',
        outcome: 'success',
        approvalRequired: false,
        approved: false,
        cacheHit: false,
        dedupBlocked: false,
      );

      expect(qErrorOutcome, ToolResultQuality.error);
      expect(qErrorJson, ToolResultQuality.error);

      final hintEn = ToolResultClassifier.getSystemHint(
          'cmd', ToolResultQuality.error, AppLanguage.en);
      final hintZh = ToolResultClassifier.getSystemHint(
          'cmd', ToolResultQuality.error, AppLanguage.zh);

      expect(hintEn, contains('failed with an error'));
      expect(hintZh, contains('执行发生错误'));
    });

    test('classifies permissionDenied results correctly', () {
      final qPermissionDenied = ToolResultClassifier.classify(
        toolName: 'cmd',
        resultJson: '{"error":"permission denied: cannot write to root"}',
        outcome: 'success',
        approvalRequired: false,
        approved: false,
        cacheHit: false,
        dedupBlocked: false,
      );

      expect(qPermissionDenied, ToolResultQuality.permissionDenied);

      final hintEn = ToolResultClassifier.getSystemHint(
          'cmd', ToolResultQuality.permissionDenied, AppLanguage.en);
      final hintZh = ToolResultClassifier.getSystemHint(
          'cmd', ToolResultQuality.permissionDenied, AppLanguage.zh);

      expect(hintEn, contains('Permission denied'));
      expect(hintZh, contains('权限不足'));
    });

    test('classifies loopBlocked results correctly', () {
      final qLoopBlocked = ToolResultClassifier.classify(
        toolName: 'cmd',
        resultJson: '{"error":"blocked"}',
        outcome: 'loop_guard_blocked',
        approvalRequired: false,
        approved: false,
        cacheHit: false,
        dedupBlocked: false,
      );

      expect(qLoopBlocked, ToolResultQuality.loopBlocked);

      final hintEn = ToolResultClassifier.getSystemHint(
          'cmd', ToolResultQuality.loopBlocked, AppLanguage.en);
      final hintZh = ToolResultClassifier.getSystemHint(
          'cmd', ToolResultQuality.loopBlocked, AppLanguage.zh);

      expect(hintEn, contains('blocked this repeating tool call'));
      expect(hintZh, contains('阻断了此重复工具调用'));
    });

    test('classifies useful results correctly', () {
      final qUsefulString = ToolResultClassifier.classify(
        toolName: 'cmd',
        resultJson: 'standard raw shell output text',
        outcome: 'success',
        approvalRequired: false,
        approved: false,
        cacheHit: false,
        dedupBlocked: false,
      );
      final qUsefulJson = ToolResultClassifier.classify(
        toolName: 'cmd',
        resultJson: '{"status":"ok", "data":"useful fields"}',
        outcome: 'success',
        approvalRequired: false,
        approved: false,
        cacheHit: false,
        dedupBlocked: false,
      );

      expect(qUsefulString, ToolResultQuality.useful);
      expect(qUsefulJson, ToolResultQuality.useful);

      final hint = ToolResultClassifier.getSystemHint(
          'cmd', ToolResultQuality.useful, AppLanguage.zh);
      expect(hint, isNull);
    });
  });
}
