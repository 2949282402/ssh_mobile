import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/models/connection.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storage;

  Future<StorageService> initializedStorage() async {
    final service = StorageService();
    await service.init();
    return service;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() {
    storage.dispose();
  });

  test('blank API key preserves secure storage and memory cache', () async {
    storage = await initializedStorage();

    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'demo-model',
      apiKey: 'sk-existing',
    );
    expect(await storage.getAiApiKey(), 'sk-existing');

    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'demo-model',
      apiKey: '',
    );

    expect(await storage.getAiApiKey(), 'sk-existing');
  });

  test('clearApiKey clears secure storage and memory cache', () async {
    storage = await initializedStorage();

    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'demo-model',
      apiKey: 'sk-existing',
    );
    expect(await storage.getAiApiKey(), 'sk-existing');

    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'demo-model',
      clearApiKey: true,
    );

    expect(await storage.getAiApiKey(), isNull);
  });

  test('multi-agent settings default and normalize on save', () async {
    storage = await initializedStorage();

    var settings = await storage.loadAiConnectionSettings();
    expect(settings.multiAgentEnabled, isTrue);
    expect(settings.multiAgentMaxAgents, 3);

    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'demo-model',
      multiAgentEnabled: false,
      multiAgentMaxAgents: 99,
    );
    settings = await storage.loadAiConnectionSettings();
    expect(settings.multiAgentEnabled, isFalse);
    expect(settings.multiAgentMaxAgents, 4);

    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'demo-model',
      multiAgentEnabled: true,
      multiAgentMaxAgents: 1,
    );
    settings = await storage.loadAiConnectionSettings();
    expect(settings.multiAgentEnabled, isTrue);
    expect(settings.multiAgentMaxAgents, 2);
  });

  test('base URL history keeps newest first and deduplicated', () async {
    storage = await initializedStorage();

    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com/v1/',
      model: 'demo-model',
    );
    await storage.saveAiConnectionSettings(
      baseUrl: 'https://openai.example.com',
      model: 'demo-model',
    );
    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com/v1',
      model: 'demo-model',
    );

    expect(
      await storage.loadAiBaseUrlHistory(),
      const ['https://api.example.com/v1', 'https://openai.example.com'],
    );
  });

  test('API key history supports switching between multiple saved keys',
      () async {
    storage = await initializedStorage();

    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'demo-model',
      apiKey: 'sk-first-secret',
    );
    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'demo-model',
      apiKey: 'sk-second-secret',
    );

    final history = await storage.loadAiApiKeyHistory();

    expect(history.map((entry) => entry.maskedValue), [
      maskAiApiKey('sk-second-secret'),
      maskAiApiKey('sk-first-secret'),
    ]);
    expect(history.first.isSelected, isTrue);
    expect(await storage.getAiApiKey(), 'sk-second-secret');

    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'demo-model',
      selectedApiKeyId: history.last.id,
    );

    expect(await storage.getAiApiKey(), 'sk-first-secret');
    expect(
      (await storage.loadAiConnectionSettings()).activeApiKeyMasked,
      maskAiApiKey('sk-first-secret'),
    );
  });

  test('AI model cache is stored per base URL', () async {
    storage = await initializedStorage();

    await storage.saveCachedAiModels(
      baseUrl: 'https://api.example.com/v1/',
      models: const ['gpt-4o', 'gpt-4.1', 'gpt-4o'],
    );
    await storage.saveCachedAiModels(
      baseUrl: 'https://api.another.com',
      models: const ['claude-sonnet'],
    );

    expect(
      await storage.loadCachedAiModels(baseUrl: 'https://api.example.com/v1'),
      const ['gpt-4.1', 'gpt-4o'],
    );
    expect(
      await storage.loadCachedAiModels(baseUrl: 'https://api.another.com/'),
      const ['claude-sonnet'],
    );
  });

  test('import clears cached AI model lists', () async {
    storage = await initializedStorage();

    await storage.saveCachedAiModels(
      baseUrl: 'https://api.example.com',
      models: const ['gpt-4o'],
    );
    expect(
      await storage.loadCachedAiModels(baseUrl: 'https://api.example.com'),
      const ['gpt-4o'],
    );

    final backup = jsonEncode({
      'format': 'ssh_mobile_backup',
      'version': 1,
      'connections': const [],
      'aiSettings': {
        'baseUrl': 'https://api.example.com',
        'model': 'demo-model',
      },
    });

    await storage.importAppDataJson(backup);

    expect(
      await storage.loadCachedAiModels(baseUrl: 'https://api.example.com'),
      isEmpty,
    );
  });

  test('export keeps connection and AI credentials empty', () async {
    storage = await initializedStorage();

    await storage.addConnection(
      ConnectionConfig(
        id: 'server-1',
        name: 'Prod',
        host: 'prod.example.com',
        username: 'root',
        password: 'server-password',
        privateKey: 'private-key-body',
        authMethod: AuthMethod.both,
      ),
    );
    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'demo-model',
      apiKey: 'sk-secret',
      multiAgentEnabled: false,
      multiAgentMaxAgents: 4,
    );

    final jsonText = await storage.exportAppDataJson();
    final decoded = jsonDecode(jsonText) as Map<String, dynamic>;
    final connection = (decoded['connections'] as List<dynamic>).single
        as Map<String, dynamic>;
    final aiSettings = decoded['aiSettings'] as Map<String, dynamic>;

    expect(jsonText, isNot(contains('server-password')));
    expect(jsonText, isNot(contains('private-key-body')));
    expect(jsonText, isNot(contains('sk-secret')));
    expect(connection['password'], '');
    expect(connection['privateKey'], '');
    expect(aiSettings['apiKey'], '');
    expect(aiSettings['multiAgentEnabled'], isFalse);
    expect(aiSettings['multiAgentMaxAgents'], 4);
  });

  test('import ignores credential fields and clears existing AI key', () async {
    storage = await initializedStorage();
    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'demo-model',
      apiKey: 'sk-existing',
    );
    expect(await storage.getAiApiKey(), 'sk-existing');

    final backup = jsonEncode({
      'format': 'ssh_mobile_backup',
      'version': 1,
      'connections': [
        {
          'id': 'server-1',
          'name': 'Imported',
          'host': 'imported.example.com',
          'username': 'admin',
          'password': 'imported-password',
          'privateKey': 'imported-private-key',
          'authMethod': 'both',
        },
      ],
      'aiSettings': {
        'baseUrl': 'https://api.example.com',
        'model': 'demo-model',
        'apiKey': 'sk-imported',
        'multiAgentEnabled': false,
        'multiAgentMaxAgents': 4,
      },
    });

    await storage.importAppDataJson(backup);

    expect(await storage.getAiApiKey(), isNull);
    expect(storage.connections.single.id, 'server-1');
    expect(storage.connections.single.password, isNull);
    expect(storage.connections.single.privateKey, isNull);
    expect(await storage.getPassword('server-1'), isNull);
    expect(await storage.getPrivateKey('server-1'), isNull);
    final settings = await storage.loadAiConnectionSettings();
    expect(settings.multiAgentEnabled, isFalse);
    expect(settings.multiAgentMaxAgents, 4);
  });

  test('web search engine settings persist, export, and import', () async {
    storage = await initializedStorage();

    // 1. Verify default value is duckduckgo
    var settings = await storage.loadAiConnectionSettings();
    expect(settings.webSearchEngine, 'duckduckgo');

    // 2. Save custom search engine
    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'demo-model',
      webSearchEngine: 'baidu',
    );
    settings = await storage.loadAiConnectionSettings();
    expect(settings.webSearchEngine, 'baidu');

    // 3. Normalize invalid search engine
    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'demo-model',
      webSearchEngine: 'invalid-engine-name',
    );
    settings = await storage.loadAiConnectionSettings();
    expect(settings.webSearchEngine, 'duckduckgo');

    // 4. Export verifies webSearchEngine is present
    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'demo-model',
      webSearchEngine: 'google',
    );
    final jsonText = await storage.exportAppDataJson();
    final decoded = jsonDecode(jsonText) as Map<String, dynamic>;
    final aiSettings = decoded['aiSettings'] as Map<String, dynamic>;
    expect(aiSettings['webSearchEngine'], 'google');

    // 5. Import restores search engine setting
    final backup = jsonEncode({
      'format': 'ssh_mobile_backup',
      'version': 1,
      'connections': const [],
      'aiSettings': {
        'baseUrl': 'https://api.example.com',
        'model': 'demo-model',
        'webSearchEngine': 'bing',
      },
    });
    await storage.importAppDataJson(backup);
    settings = await storage.loadAiConnectionSettings();
    expect(settings.webSearchEngine, 'bing');
  });
}
