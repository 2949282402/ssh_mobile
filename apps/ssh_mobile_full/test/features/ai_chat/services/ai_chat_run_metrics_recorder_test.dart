import 'package:flutter/foundation.dart';
import '../../../test_utils/ai_port_adapters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:feature_ai/ai_chat.dart';
import 'package:feature_ai/ai_agent.dart';
import '../../../test_utils/test_storage_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStorageAdapter storageService;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storageService = TestStorageAdapter();
    await storageService.init();
    attachTestAiRepository(storageService);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    storageService.dispose();
  });

  group('AiChatRunMetricsRecorder Tests', () {
    test('record saves metrics correctly on success', () async {
      final recorder = AiChatRunMetricsRecorder(aiStoragePort(storageService));
      final modelProfile = AgentModelProfile(
        mainModel: 'gpt-4o',
        helperModel: 'gpt-4o-mini',
        auditModel: 'gpt-4o',
      );

      final startedAt = DateTime.now();
      final finishedAt = startedAt.add(const Duration(seconds: 2));

      const stats = LlmRunStats(
        promptTokens: 15,
        completionTokens: 25,
        totalTokens: 40,
        elapsedMs: 2000,
        toolCalls: 2,
        cacheHits: 1,
        dedupBlockedCalls: 0,
        approvalCount: 1,
        approvedCount: 1,
        auditEscalationLevel: 0,
        helperFanout: 0,
        selectedToolSet: ['run_command'],
        memorySources: ['memory_key'],
        usageFromProvider: true,
        contextTokensBeforeCompression: 15,
        contextWindowTokens: 16384,
        compressed: false,
      );

      await recorder.record(
        modelProfile: modelProfile,
        model: 'gpt-4o',
        startedAt: startedAt,
        finishedAt: finishedAt,
        ragHits: 3,
        success: true,
        runStats: stats,
      );

      final metricsList = await storageService.loadAgentRunMetrics();
      expect(metricsList, hasLength(1));

      final metric = metricsList.first;
      expect(metric.model, 'gpt-4o');
      // helperModel 与 mainModel 不同，保留 'gpt-4o-mini'
      expect(metric.helperModel, 'gpt-4o-mini');
      // auditModel 与 mainModel 相同，被压缩映射为空字符串
      expect(metric.auditModel, '');
      expect(metric.promptTokens, 15);
      expect(metric.completionTokens, 25);
      expect(metric.totalTokens, 40);
      expect(metric.toolCalls, 2);
      expect(metric.cacheHits, 1);
      expect(metric.ragHits, 3);
      expect(metric.success, isTrue);
      expect(metric.selectedToolSet, contains('run_command'));
      expect(metric.memorySources, contains('memory_key'));
    });

    test(
      'record handles success false and missing runStats gracefully',
      () async {
        final recorder = AiChatRunMetricsRecorder(
          aiStoragePort(storageService),
        );
        final modelProfile = AgentModelProfile(
          mainModel: 'gpt-4o',
          helperModel: 'gpt-4o',
          auditModel: 'gpt-4o',
        );

        final startedAt = DateTime.now();
        final finishedAt = startedAt.add(const Duration(seconds: 1));

        await recorder.record(
          modelProfile: modelProfile,
          model: 'gpt-4o',
          startedAt: startedAt,
          finishedAt: finishedAt,
          ragHits: 0,
          success: false,
          runStats: null,
        );

        final metricsList = await storageService.loadAgentRunMetrics();
        expect(metricsList, hasLength(1));

        final metric = metricsList.first;
        expect(metric.model, 'gpt-4o');
        expect(metric.helperModel, ''); // 相同则为空串
        expect(metric.auditModel, '');
        expect(metric.promptTokens, 0);
        expect(metric.completionTokens, 0);
        expect(metric.success, isFalse);
        expect(metric.elapsedMs, 1000); // 降级差值判定
      },
    );
  });
}
