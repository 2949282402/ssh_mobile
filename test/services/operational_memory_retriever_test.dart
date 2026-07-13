import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/services/operational_memory_retriever.dart';
import 'package:ssh_mobile/services/rag_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/skill/skill_index_service.dart';
import 'package:ssh_mobile/utils/text_chunker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storage;
  late OperationalMemoryRetriever retriever;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storage = StorageService();
    await storage.init();
    retriever = OperationalMemoryRetriever(storageService: storage);
  });

  tearDown(() {
    storage.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  test('Skill hits recall with frontmatter metadata fallback', () async {
    final skill = AiSkillRecord(
      id: 'skill-fm-test',
      name: '',
      description: '',
      content: '''---
name: Nginx Deploy Guide
description: Steps to setup reverse proxy and static sites
---

This is the main body that mentions proxying.''',
      enabled: true,
      references: const [],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await storage.saveAiSkill(skill);

    // 1. 尝试用 frontmatter 的 description 检索
    final resultDesc = await retriever.retrieve(query: 'reverse proxy');
    expect(resultDesc.hits, isNotEmpty);
    expect(resultDesc.hits.first.title, equals('Nginx Deploy Guide'));

    // 2. 尝试用 frontmatter 的 name 检索
    final resultName = await retriever.retrieve(query: 'Nginx Deploy');
    expect(resultName.hits, isNotEmpty);
    expect(resultName.hits.first.title, equals('Nginx Deploy Guide'));
  });

  test(
    'Skill hits recall with references title or content and clips matches',
    () async {
      final skill = AiSkillRecord(
        id: 'skill-ref-test',
        name: 'Docker Management',
        description: 'How to manage docker containers',
        content: 'Main docker instructions...',
        enabled: true,
        references: const [
          SkillReferenceItem(
            title: 'Docker Prune Command',
            content: 'Run docker system prune -a to clean up resources.',
          ),
          SkillReferenceItem(
            title: 'Kubernetes Apply Guide',
            content: 'Use kubectl apply -f manifest.yaml for deployments.',
          ),
        ],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await storage.saveAiSkill(skill);

      // 1. 通过 reference title 检索
      final resultTitle = await retriever.retrieve(query: 'Prune Command');
      expect(resultTitle.hits, isNotEmpty);
      expect(
        resultTitle.hits.first.content,
        contains('### Reference: Docker Prune Command'),
      );
      expect(
        resultTitle.hits.first.content,
        isNot(contains('Kubernetes Apply Guide')),
      );

      // 2. 通过 reference content 检索
      final resultCont = await retriever.retrieve(query: 'kubectl apply');
      expect(resultCont.hits, isNotEmpty);
      expect(
        resultCont.hits.first.content,
        contains('### Reference: Kubernetes Apply Guide'),
      );
      expect(
        resultCont.hits.first.content,
        isNot(contains('Docker Prune Command')),
      );
    },
  );

  test('Chinese text tokenization and recall for skills', () async {
    final skill = AiSkillRecord(
      id: 'skill-zh-test',
      name: '部署Nginx服务器',
      description: '配置反向代理与静态资源服务器的指南',
      content: '一些关于运维的记录。',
      enabled: true,
      references: const [],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await storage.saveAiSkill(skill);

    // 1. 通过中文短语词检索（分词优化）
    final resultZh = await retriever.retrieve(query: '部署反向代理');
    expect(resultZh.hits, isNotEmpty);
    expect(resultZh.hits.first.title, equals('部署Nginx服务器'));
  });

  test(
    'Legacy Skill JSON import handles missing name/description and fallbacks properly',
    () async {
      final legacyJson = <String, dynamic>{
        'id': 'legacy-skill-1',
        'content': '''---
name: Legacy Imported Title
description: Legacy Imported Desc
---
body instructions here''',
        'enabled': true,
        'createdAt': DateTime.now().toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
      };

      final record = AiSkillRecord.fromJson(legacyJson);

      expect(record.name, isEmpty);
      expect(record.description, isEmpty);
      expect(record.displayName, equals('Legacy Imported Title'));
      expect(record.displayDescription, equals('Legacy Imported Desc'));

      await storage.saveAiSkill(record);

      final result = await retriever.retrieve(query: 'Imported Title');
      expect(result.hits, isNotEmpty);
      expect(result.hits.first.title, equals('Legacy Imported Title'));
      expect(result.hits.first.content, contains('body instructions here'));
    },
  );

  test(
    'fallbacks to legacy search when SkillIndexService throws Exception',
    () async {
      final brokenRetriever = OperationalMemoryRetriever(
        storageService: storage,
        skillIndexService: _MockBrokenSkillIndexService(),
      );

      final skill = AiSkillRecord(
        id: 'skill-fallback-test',
        name: 'Nginx Service',
        description: 'Setup nginx service web',
        content: 'Nginx commands...',
        enabled: true,
        references: const [],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await storage.saveAiSkill(skill);

      // Should successfully retrieve and fallback to legacy search without throwing exception
      final result = await brokenRetriever.retrieve(query: 'nginx service web');
      expect(result.hits, isNotEmpty);
      expect(result.hits.first.title, equals('Nginx Service'));
    },
  );

  test('forwards the turn-scoped RAG mode, limit, and key', () async {
    final recordingRag = _RecordingRagService(storage: storage);
    final scopedRetriever = OperationalMemoryRetriever(
      storageService: storage,
      ragService: recordingRag,
    );

    await scopedRetriever.retrieve(
      query: 'nginx status',
      ragEnabled: true,
      ragLimit: 8,
      ragSearchMode: 'hybrid',
      ragAliyunApiKey: 'turn-key',
    );

    expect(recordingRag.receivedLimit, 8);
    expect(recordingRag.receivedSearchMode, 'hybrid');
    expect(recordingRag.receivedExpectedKey, isTrue);
  });
}

class _RecordingRagService extends RagService {
  int? receivedLimit;
  String? receivedSearchMode;
  bool receivedExpectedKey = false;

  _RecordingRagService({required StorageService storage})
    : super(storageService: storage);

  @override
  Future<List<RagChunk>> retrieve(
    String query, {
    int limit = 3,
    Set<String>? filterDocumentIds,
    String? searchMode,
    String? aliyunApiKey,
  }) async {
    receivedLimit = limit;
    receivedSearchMode = searchMode;
    receivedExpectedKey = aliyunApiKey == 'turn-key';
    return const [];
  }
}

class _MockBrokenSkillIndexService extends SkillIndexService {
  @override
  void updateIndex(List<AiSkillRecord> skills) {
    throw StateError('Mock index error');
  }
}
