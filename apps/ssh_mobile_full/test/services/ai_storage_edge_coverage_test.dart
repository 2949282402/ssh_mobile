import 'dart:convert';

import 'package:feature_ai/feature_ai.dart' as ai;
import 'package:feature_playbook/feature_playbook.dart' as playbook;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/services/ai_storage_adapter.dart';

import '../test_utils/ai_port_adapters.dart';
import '../test_utils/test_storage_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStorageAdapter storage;
  var storageCreated = false;

  setUp(() {
    storageCreated = false;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  tearDown(() async {
    if (!storageCreated) return;
    await storage.shutdown();
    storage.dispose();
  });

  Future<void> initialize() async {
    storage = TestStorageAdapter();
    storageCreated = true;
    attachTestAiRepository(storage);
    await storage.init();
  }

  test('secret cache settings normalize, toggle, and clear', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'secret_cache_enabled': false,
      'secret_cache_ttl_seconds': 301,
    });
    await initialize();

    expect(storage.isSecretCacheEnabled, isFalse);
    expect(storage.secretCacheTtlMinutes, 5);
    expect(storage.secretCacheTtlOptionsMinutes, [1, 5, 15, 30, 60]);

    await storage.setSecretCacheEnabled(false);
    await storage.setSecretCacheTtl(const Duration(minutes: 1));
    expect(storage.secretCacheTtlMinutes, 1);
    await storage.setSecretCacheEnabled(true);
    await storage.setSecretCacheTtl(const Duration(minutes: 121));
    expect(storage.secretCacheTtlMinutes, 60);
    storage.clearSecretCache();
  });

  test(
    'AI settings persist optional prompts, API keys, and normalized values',
    () async {
      await initialize();
      await storage.saveAiConnectionSettings(
        baseUrl: ' https://api.example.test/v1/ ',
        model: ' gpt-5 ',
        helperModel: ' helper ',
        auditModel: ' auditor ',
        modelFallbackPolicy: 'invalid-policy',
        contextWindowTokens: 512000,
        timeoutSeconds: 300,
        deepSeekThinkingEnabled: false,
        deepSeekReasoningEffort: 'max',
        openAiReasoningEffort: 'xhigh',
        webSearchEnabled: false,
        webSearchMaxResults: 20,
        webSearchEngine: 'brave',
        multiAgentEnabled: false,
        multiAgentMaxAgents: 5,
        postToolReviewEnabled: false,
        toolCallBudget: 40,
        agentLoopMode: 'deep',
        maxImageSizeBytes: 20 * 1024 * 1024,
        maxFileSizeBytes: 100 * 1024 * 1024,
        apiKey: ' sk-api-key ',
        quarkSearchEndpoint: ' https://search.example.test ',
        quarkApiKey: ' quark-secret ',
        useCustomPrompts: true,
        customSystemPrompt: 'system',
        customPlannerPrompt: 'planner',
        customOperatorPrompt: 'operator',
        customExplorePrompt: 'explore',
        customReviewerPrompt: 'reviewer',
        customSummarizerPrompt: 'summarizer',
        customCoordinatorPrompt: 'coordinator',
        apiFormat: ai.LlmApiFormat.anthropicMessages,
      );

      final settings = await storage.loadAiConnectionSettings();
      expect(settings.baseUrl, 'https://api.example.test/v1/');
      expect(settings.model, 'gpt-5');
      expect(settings.helperModel, 'helper');
      expect(settings.auditModel, 'auditor');
      expect(settings.timeoutSeconds, 300);
      expect(settings.deepSeekThinkingEnabled, isFalse);
      expect(settings.deepSeekReasoningEffort, 'max');
      expect(settings.openAiReasoningEffort, 'xhigh');
      expect(settings.webSearchEnabled, isFalse);
      expect(settings.multiAgentEnabled, isFalse);
      expect(settings.postToolReviewEnabled, isFalse);
      expect(settings.toolCallBudget, 40);
      expect(settings.agentLoopMode, 'deep');
      expect(settings.hasApiKey, isTrue);
      expect(settings.activeApiKeyMasked, 'sk-a****ey');
      expect(settings.hasQuarkApiKey, isTrue);
      expect(settings.useCustomPrompts, isTrue);
      expect(settings.customCoordinatorPrompt, 'coordinator');
      expect(settings.apiFormat, ai.LlmApiFormat.anthropicMessages);
      expect(await storage.getQuarkApiKey(), 'quark-secret');
      await storage.saveQuarkApiKey('');
      expect(await storage.getQuarkApiKey(), isNull);
      await storage.saveAliyunApiKey(' aliyun-secret ');
      expect(await storage.getAliyunApiKey(), 'aliyun-secret');
      await storage.saveAliyunApiKey('');
      expect(await storage.getAliyunApiKey(), isNull);
    },
  );

  test(
    'model cache handles malformed data, normalization, and selective clearing',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'ai_models_cache': jsonEncode(<String, dynamic>{
          ' https://bad.example/// ': 'not-a-list',
          'https://good.example/': [' zeta ', '', 'alpha', 'alpha'],
        }),
      });
      await initialize();
      expect(
        await storage.loadCachedAiModels(baseUrl: 'https://good.example'),
        ['alpha', 'zeta'],
      );
      expect(
        await storage.loadCachedAiModels(baseUrl: 'https://bad.example'),
        isEmpty,
      );

      await storage.saveCachedAiModels(
        baseUrl: 'https://other.example/',
        models: ['model-b', 'model-a'],
      );
      await storage.aiStorage.clearCachedAiModels(
        baseUrl: 'https://good.example/',
      );
      expect(
        await storage.loadCachedAiModels(baseUrl: 'https://good.example'),
        isEmpty,
      );
      expect(
        await storage.loadCachedAiModels(baseUrl: 'https://other.example'),
        ['model-a', 'model-b'],
      );
      await storage.aiStorage.clearCachedAiModels(
        baseUrl: 'https://other.example',
      );
      expect(
        await storage.loadCachedAiModels(baseUrl: 'https://other.example'),
        isEmpty,
      );
      await storage.aiStorage.clearCachedAiModels(baseUrl: '///');
    },
  );

  test('legacy and stale API key entries migrate and fail closed', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'ai_api_key': ' sk-legacy ',
    });
    await initialize();
    expect(await storage.getAiApiKey(), 'sk-legacy');
    final migrated = await storage.loadAiApiKeyHistory();
    expect(migrated, hasLength(1));
    expect(await storage.getAiApiKeyById(''), isNull);
    expect(await storage.getAiApiKeyById(migrated.single.id), 'sk-legacy');
    await storage.selectAiApiKey('missing-id');
    expect(await storage.getSelectedAiApiKeyId(), migrated.single.id);
    await storage.removeAiApiKeyHistoryEntry('missing-id');

    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.test',
      model: 'model',
      apiKey: 'sk-new',
    );
    final history = await storage.aiStorage.getAiApiKeyHistory();
    await storage.deleteAiApiKey(history.first.id);
    expect(await storage.getAiApiKey(), 'sk-legacy');
  });

  test('invalid legacy and stale stored keys are removed', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ai_api_key_refs': jsonEncode(['stale']),
      'ai_selected_api_key_id': 'stale',
    });
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'ai_api_key': 'bad\nkey',
      'ai_api_key_entry_stale': 'bad\tkey',
    });
    await initialize();
    expect(await storage.getAiApiKey(), isNull);
    expect(await storage.loadAiApiKeyHistory(), isEmpty);
    expect(await storage.getSelectedAiApiKeyId(), isNull);
  });

  test(
    'AI skills use encrypted buffered persistence and CAS semantics',
    () async {
      await initialize();
      final older = _skill('skill-a', updatedAt: DateTime.utc(2026, 1, 1));
      final newer = _skill('skill-b', updatedAt: DateTime.utc(2026, 1, 2));
      await storage.saveAiSkill(older);
      await storage.saveAiSkill(newer);
      await storage.aiStorage.flushPendingWrites();
      expect((await storage.loadAiSkills()).map((item) => item.id), [
        'skill-b',
        'skill-a',
      ]);

      final replacement = newer.copyWith(
        name: 'Updated',
        updatedAt: DateTime.utc(2026, 1, 3),
      );
      expect(await storage.saveAiSkillIfUnchanged(newer, replacement), isTrue);
      expect((await storage.loadAiSkills()).first.name, 'Updated');
      expect(
        await storage.saveAiSkillIfUnchanged(
          newer,
          newer.copyWith(name: 'stale expected'),
        ),
        isFalse,
      );
      expect(
        () => storage.saveAiSkillIfUnchanged(older, replacement),
        throwsArgumentError,
      );
      await storage.deleteAiSkill('skill-a');
      expect((await storage.loadAiSkills()).map((item) => item.id), [
        'skill-b',
      ]);
    },
  );

  test(
    'AI skills reload from encrypted preferences and import flushes pending data',
    () async {
      await initialize();
      final pending = _skill(
        'pending-skill',
        updatedAt: DateTime.utc(2026, 2, 1),
      );
      await storage.saveAiSkill(pending);

      // Import uses the immediate path while the debounced write is still
      // pending.  The imported record must win and be durably available after
      // recreating the adapter.
      final imported = _skill(
        'imported-skill',
        updatedAt: DateTime.utc(2026, 2, 2),
      );
      await storage.importAppDataJson(
        jsonEncode({
          'format': 'ssh_mobile_backup',
          'version': 1,
          'connections': const [],
          'aiSkills': [imported.toJson()],
        }),
      );
      expect((await storage.loadAiSkills()).map((item) => item.id), [
        'imported-skill',
      ]);

      await storage.shutdown();
      storage.dispose();
      storage = TestStorageAdapter();
      attachTestAiRepository(storage);
      await storage.init();
      expect((await storage.loadAiSkills()).map((item) => item.id), [
        'imported-skill',
      ]);

      // A subsequent import has no debounced write to replace, so the
      // immediate path writes directly and leaves the adapter in a clean
      // empty state.
      await storage.importAppDataJson(
        jsonEncode({
          'format': 'ssh_mobile_backup',
          'version': 1,
          'connections': const [],
        }),
      );
      expect(await storage.loadAiSkills(), isEmpty);
    },
  );

  test('malformed skill preference falls back to an empty list', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ai_skills': '{not-json',
    });
    await initialize();
    expect(await storage.loadAiSkills(), isEmpty);
  });

  test(
    'ordering helpers replace duplicate records without leaking stale values',
    () {
      final base = DateTime.utc(2026, 1, 1);
      final chatA = _chat('a', base);
      final chatB = _chat('b', base.add(const Duration(minutes: 1)));
      final chatAUpdated = _chat('a', base.add(const Duration(minutes: 2)));
      expect(
        upsertAiChatRecordsByUpdatedAt([
          chatA,
          chatB,
        ], chatAUpdated).map((item) => item.id),
        ['a', 'b'],
      );
      expect(
        upsertAiChatRecordsByUpdatedAt(
          [chatA, chatB],
          _chat('c', base),
          limit: 2,
        ).map((item) => item.id),
        ['c', 'a'],
      );

      final skillA = _skill('a', updatedAt: base);
      final skillB = _skill(
        'b',
        updatedAt: base.add(const Duration(minutes: 1)),
      );
      expect(
        upsertAiSkillRecordsByUpdatedAt(
          [skillA, skillB],
          _skill('a', updatedAt: base.add(const Duration(minutes: 2))),
        ).map((item) => item.id),
        ['a', 'b'],
      );
      final playbookA = _playbook('a', base);
      final playbookB = _playbook('b', base.add(const Duration(minutes: 1)));
      expect(
        upsertPlaybooksByUpdatedAt([
          playbookA,
          playbookB,
        ], _playbook('c', base)).map((item) => item.id),
        ['c', 'a', 'b'],
      );
    },
  );
}

ai.AiChatRecord _chat(String id, DateTime updatedAt) => ai.AiChatRecord(
  id: id,
  title: id,
  model: 'model',
  messages: const [],
  createdAt: updatedAt,
  updatedAt: updatedAt,
);

ai.AiSkillRecord _skill(String id, {required DateTime updatedAt}) =>
    ai.AiSkillRecord(
      id: id,
      name: id,
      description: 'description',
      content: 'content',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: updatedAt,
    );

playbook.Playbook _playbook(String id, DateTime updatedAt) => playbook.Playbook(
  id: id,
  name: id,
  description: 'description',
  steps: [
    playbook.PlaybookStep(
      id: 'step-$id',
      name: 'step',
      command: 'true',
      description: 'step',
    ),
  ],
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: updatedAt,
);
