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

  test('quark search settings and API key persist, export, and import',
      () async {
    storage = await initializedStorage();

    // 1. Verify default values
    var settings = await storage.loadAiConnectionSettings();
    expect(settings.quarkSearchEndpoint,
        'https://dashscope.aliyuncs.com/api/v1/services/search/quark');
    expect(settings.hasQuarkApiKey, isFalse);
    expect(await storage.getQuarkApiKey(), isNull);

    // 2. Save custom endpoint and API Key
    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'demo-model',
      quarkSearchEndpoint: 'https://custom-quark.example.com/api',
      quarkApiKey: 'quark-secret-key-123',
    );

    settings = await storage.loadAiConnectionSettings();
    expect(
        settings.quarkSearchEndpoint, 'https://custom-quark.example.com/api');
    expect(settings.hasQuarkApiKey, isTrue);
    expect(await storage.getQuarkApiKey(), 'quark-secret-key-123');

    // 3. Export verifies endpoint is present but key is omitted/empty
    final jsonText = await storage.exportAppDataJson();
    final decoded = jsonDecode(jsonText) as Map<String, dynamic>;
    final aiSettings = decoded['aiSettings'] as Map<String, dynamic>;
    expect(aiSettings['quarkSearchEndpoint'],
        'https://custom-quark.example.com/api');
    expect(jsonText, isNot(contains('quark-secret-key-123')));

    // 4. Import restores endpoint and clears existing key
    final backup = jsonEncode({
      'format': 'ssh_mobile_backup',
      'version': 1,
      'connections': const [],
      'aiSettings': {
        'baseUrl': 'https://api.example.com',
        'model': 'demo-model',
        'quarkSearchEndpoint': 'https://imported-quark.example.com',
        'quarkApiKey': 'quark-secret-imported-should-be-ignored',
      },
    });

    await storage.importAppDataJson(backup);
    settings = await storage.loadAiConnectionSettings();
    expect(settings.quarkSearchEndpoint, 'https://imported-quark.example.com');
    // Secret key is ignored during import (should be null / cleared)
    expect(settings.hasQuarkApiKey, isFalse);
    expect(await storage.getQuarkApiKey(), isNull);

    // 5. Clear API key explicitly
    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'demo-model',
      quarkApiKey: 'quark-secret-key-456',
    );
    expect(await storage.getQuarkApiKey(), 'quark-secret-key-456');

    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'demo-model',
      clearQuarkApiKey: true,
    );
    expect(await storage.getQuarkApiKey(), isNull);
  });

  test('custom settings, shortcuts, and secret cache persist, export, and import',
      () async {
    storage = await initializedStorage();

    // 1. Setup mock initial settings in SharedPreferences directly
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_language', 'en');
    await prefs.setString('theme_mode', 'dark');
    await prefs.setBool('dark_mode', true);
    await prefs.setString('font_family', 'Roboto');
    await prefs.setInt('sftp_download_limit_bytes', 1024 * 1024);
    await prefs.setInt('sftp_text_preview_limit_bytes', 2048);
    await prefs.setInt('sftp_rich_preview_limit_bytes', 4096);
    await prefs.setInt('sftp_text_edit_limit_bytes', 512);

    await prefs.setString('shortcut_command_usage', '{"cmd1": 5}');
    await prefs.setString('custom_shortcut_commands', '[{"id":"c1","label":"Custom","code":"ls","custom":true}]');
    await prefs.setString('shortcut_command_order', '["c1"]');

    await storage.setSecretCacheEnabled(false);
    await storage.setSecretCacheTtl(const Duration(minutes: 5));

    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'demo-model',
      maxImageSizeBytes: 5 * 1024 * 1024,
      maxFileSizeBytes: 50 * 1024 * 1024,
    );

    // 2. Verify settings are correctly exported
    final jsonText = await storage.exportAppDataJson();
    final decoded = jsonDecode(jsonText) as Map<String, dynamic>;

    expect(decoded['version'], 2);

    final appSettings = decoded['appSettings'] as Map<String, dynamic>;
    expect(appSettings['language'], 'en');
    expect(appSettings['themeMode'], 'dark');
    expect(appSettings['darkMode'], isTrue);
    expect(appSettings['fontFamily'], 'Roboto');
    expect(appSettings['sftpDownloadLimitBytes'], 1024 * 1024);
    expect(appSettings['sftpTextPreviewLimitBytes'], 2048);
    expect(appSettings['sftpRichPreviewLimitBytes'], 4096);
    expect(appSettings['sftpTextEditLimitBytes'], 512);

    final shortcutCommands = decoded['shortcutCommands'] as Map<String, dynamic>;
    expect(shortcutCommands['usage'], '{"cmd1": 5}');
    expect(shortcutCommands['customCommands'], '[{"id":"c1","label":"Custom","code":"ls","custom":true}]');
    expect(shortcutCommands['order'], '["c1"]');

    final secretCache = decoded['secretCache'] as Map<String, dynamic>;
    expect(secretCache['enabled'], isFalse);
    expect(secretCache['ttlSeconds'], 300);

    final aiSettings = decoded['aiSettings'] as Map<String, dynamic>;
    expect(aiSettings['maxImageSizeBytes'], 5 * 1024 * 1024);
    expect(aiSettings['maxFileSizeBytes'], 50 * 1024 * 1024);

    // 3. Clear settings/create a fresh storage and verify import and callback
    final newStorage = await initializedStorage();

    // Register import callback
    var callbackTriggered = false;
    newStorage.registerOnImportCallback(() {
      callbackTriggered = true;
    });

    await newStorage.importAppDataJson(jsonText);

    expect(callbackTriggered, isTrue);

    // Verify imported values in new storage
    final newPrefs = await SharedPreferences.getInstance();
    expect(newPrefs.getString('app_language'), 'en');
    expect(newPrefs.getString('theme_mode'), 'dark');
    expect(newPrefs.getBool('dark_mode'), isTrue);
    expect(newPrefs.getString('font_family'), 'Roboto');
    expect(newPrefs.getInt('sftp_download_limit_bytes'), 1024 * 1024);
    expect(newPrefs.getInt('sftp_text_preview_limit_bytes'), 2048);
    expect(newPrefs.getInt('sftp_rich_preview_limit_bytes'), 4096);
    expect(newPrefs.getInt('sftp_text_edit_limit_bytes'), 512);

    expect(newPrefs.getString('shortcut_command_usage'), '{"cmd1": 5}');
    expect(newPrefs.getString('custom_shortcut_commands'), '[{"id":"c1","label":"Custom","code":"ls","custom":true}]');
    expect(newPrefs.getString('shortcut_command_order'), '["c1"]');

    expect(newStorage.isSecretCacheEnabled, isFalse);
    expect(newStorage.secretCacheTtlMinutes, 5);

    final newAiSettings = await newStorage.loadAiConnectionSettings();
    expect(newAiSettings.maxImageSizeBytes, 5 * 1024 * 1024);
    expect(newAiSettings.maxFileSizeBytes, 50 * 1024 * 1024);

    newStorage.dispose();
  });
}
