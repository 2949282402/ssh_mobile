import 'package:app_core/app_core.dart' as app_core;
import 'package:connection_core/connection_core.dart';
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:feature_playbook/feature_playbook.dart' as playbook;
import 'package:feature_rag/feature_rag.dart' as rag;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ssh_mobile/app/monitoring_feature_adapters.dart';
import 'package:ssh_mobile/app/playbook_feature_adapters.dart';
import 'package:ssh_mobile/app/rag_feature_adapters.dart';
import 'package:ssh_mobile/app/webview_feature_adapters.dart';
import 'package:ssh_mobile/core/services/data_protection_service.dart';
import 'package:ssh_mobile/core/services/ssh_host_key_policy.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/connection_target_binding.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import '../test_utils/test_storage_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test(
    'RAG settings and capability adapters forward public contracts',
    () async {
      final settings = AppSettings();
      final storage = TestStorageAdapter();
      await storage.init();
      addTearDown(() async {
        settings.dispose();
        storage.dispose();
      });
      final adapter = AppRagSettingsAdapter(settings, storage.aiStorage);
      addTearDown(adapter.dispose);
      var notifications = 0;
      adapter.addListener(() => notifications++);
      await settings.toggleLanguage();
      expect(adapter.isEnglish, isTrue);
      expect(adapter.searchMode, rag.RagSearchMode.bm25);
      expect(notifications, greaterThan(0));
      await adapter.saveAliyunApiKey('dashscope-test-key');
      expect(await adapter.getAliyunApiKey(), 'dashscope-test-key');

      final delegate = _FakeRagCapability();
      final capability = AppAiRagCapabilityAdapter(delegate);
      final chunks = await capability.retrieve(
        const app_core.RagQuery(
          query: 'hello',
          limit: 2,
          searchMode: 'hybrid',
          apiKey: 'key',
        ),
      );
      expect(delegate.lastQuery, 'hello');
      expect(delegate.lastLimit, 2);
      expect(delegate.lastSearchMode, 'hybrid');
      expect(delegate.lastApiKey, 'key');
      expect(chunks, hasLength(1));
      expect(chunks.single.documentName, 'manual.md');
      expect(chunks.single.metadata['id'], 'chunk-1');
      expect(chunks.single.metadata['section'], 'intro');
      expect(() => chunks.add(chunks.single), throwsUnsupportedError);

      final logger = AppRagLoggerAdapter(AppLogService.instance);
      logger.info('rag info');
      logger.warning('rag warning', details: 'details');
      logger.error('rag error', error: StateError('failure'));
    },
  );

  test(
    'Playbook settings, catalog, logger and protection adapters are observable',
    () async {
      final settings = AppSettings();
      final storage = TestStorageAdapter();
      await storage.init();
      final connection = ConnectionConfig(
        id: 'playbook-connection',
        name: 'Playbook server',
        host: 'example.test',
        username: 'tester',
      );
      await storage.addConnection(connection);
      addTearDown(() async {
        settings.dispose();
        storage.dispose();
      });

      final settingsAdapter = AppPlaybookSettingsAdapter(settings);
      final catalog = AppPlaybookConnectionCatalogAdapter(
        storage.connectionRepository,
      );
      addTearDown(() {
        settingsAdapter.dispose();
        catalog.dispose();
      });
      var settingNotifications = 0;
      settingsAdapter.addListener(() => settingNotifications++);
      await settings.toggleLanguage();
      expect(settingsAdapter.language, playbook.PlaybookLanguage.en);
      expect(settingsAdapter.isEnglish, isTrue);
      expect(settingNotifications, 1);
      expect(catalog.isInitialized, isTrue);
      expect(catalog.connections.single.id, connection.id);
      expect(catalog.connectionById(connection.id), isNotNull);
      expect(catalog.connectionById('missing'), isNull);

      final protection = AppPlaybookDataProtectionAdapter(
        // The adapter only owns the public service contract; the singleton is
        // the app-level owner used by production wiring.
        DataProtectionService.instance,
      );
      expect(protection.isEncrypted('plain'), isFalse);
      final encrypted = await protection.encryptString('playbook');
      expect(await protection.decryptString(encrypted), 'playbook');

      final logger = AppPlaybookLoggerAdapter(AppLogService.instance);
      logger.info('playbook info');
      logger.warning('playbook warning');
      logger.error('playbook error', details: 'details');
    },
  );

  test(
    'Monitoring and WebView settings adapters forward state and validation',
    () async {
      final storage = TestStorageAdapter();
      await storage.init();
      final settings = AppSettings();
      final ssh = _FakeMonitoringSshService(storage);
      addTearDown(() async {
        settings.dispose();
        ssh.dispose();
        storage.dispose();
      });

      final monitorSsh = AppMonitoringSshAdapter(ssh);
      final binding = ssh_core.SshTargetBinding.fromConfig(
        ConnectionConfig(
          id: 'server',
          name: 'Server',
          host: 'example.test',
          username: 'tester',
        ),
      );
      final first = await monitorSsh.runOneShotCommand(
        connectionId: 'server',
        command: 'uptime',
        timeout: const Duration(seconds: 2),
      );
      final second = await monitorSsh.runOneShotCommandForBinding(
        binding: binding,
        command: 'uname',
        timeout: const Duration(seconds: 2),
      );
      expect(first.stdout, 'ok');
      expect(second.exitCode, 0);
      final third = await monitorSsh.runOneShotCommand(
        connectionId: 'server',
        command: 'blocked',
        timeout: const Duration(seconds: 2),
        priority: monitoring.MonitoringRequestPriority.low,
      );
      expect(third.stdout, 'ok');
      final prompted = <ssh_core.SshHostKeyPromptRequest>[];
      final callbackResult = await monitorSsh.runOneShotCommand(
        connectionId: 'server',
        command: 'with-callback',
        timeout: const Duration(seconds: 2),
        onUnknownHostKey: (request) {
          prompted.add(request);
          return true;
        },
      );
      expect(callbackResult.stdout, 'ok');
      expect(prompted.single.connectionId, 'server');
      expect(prompted.single.connectionName, 'Server');
      expect(prompted.single.host, 'example.test');
      expect(prompted.single.port, 22);
      expect(prompted.single.username, 'tester');
      expect(prompted.single.algorithm, 'ssh-ed25519');
      expect(prompted.single.fingerprint, 'MD5:00:11');
      final catalog = AppMonitoringConnectionCatalogAdapter(
        storage.connectionRepository,
      );
      expect(catalog.targetBindingFor('missing'), isNull);
      expect(catalog.serverPlatformFor('missing'), isNull);

      final logger = AppMonitoringLoggerAdapter(AppLogService.instance);
      logger.warning('monitoring warning', details: 'details');
      logger.error(
        'monitoring error',
        error: StateError('failure'),
        stackTrace: StackTrace.current,
      );
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = previousPlatform;
      });
      await AppMonitoringBackgroundAdapter(
        settings,
      ).start(connectionName: 'Server');

      final webSettings = AppWebViewSettingsAdapter(settings);
      addTearDown(webSettings.dispose);
      var notifications = 0;
      webSettings.addListener(() => notifications++);
      await settings.toggleLanguage();
      expect(webSettings.language, AppLanguage.en);
      expect(notifications, 1);
      catalog.hashCode; // keep the adapter alive through the assertion boundary
    },
  );
}

final class _FakeRagCapability extends ChangeNotifier
    implements rag.RagCapability {
  String? lastQuery;
  int? lastLimit;
  String? lastSearchMode;
  String? lastApiKey;

  @override
  Future<List<rag.RagChunk>> retrieve(
    String query, {
    int limit = 3,
    Set<String>? filterDocumentIds,
    String? searchMode,
    String? aliyunApiKey,
  }) async {
    lastQuery = query;
    lastLimit = limit;
    lastSearchMode = searchMode;
    lastApiKey = aliyunApiKey;
    return const [
      rag.RagChunk(
        id: 'chunk-1',
        documentId: 'doc-1',
        documentName: 'manual.md',
        text: 'hello',
        charStartIndex: 0,
        charEndIndex: 5,
        metadata: {'section': 'intro'},
      ),
    ];
  }
}

final class _FakeMonitoringSshService extends SshService {
  _FakeMonitoringSshService(TestStorageAdapter storage)
    : super(
        connectionRepository: storage.connectionRepository,
        credentialRepository: storage.credentialRepository,
        hostKeyRepository: storage.hostKeyRepository,
        terminalMetadataStore: storage.terminalMetadataStore,
      );

  Future<void> _invokeCallback(
    SshHostKeyConfirmation? callback,
  ) async {
    if (callback == null) return;
    await callback(
      const ssh_core.SshHostKeyPromptRequest(
        connectionId: 'server',
        connectionName: 'Server',
        host: 'example.test',
        port: 22,
        username: 'tester',
        algorithm: 'ssh-ed25519',
        fingerprint: 'MD5:00:11',
      ),
    );
  }

  @override
  Future<RemoteCommandResult> runOneShotCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 15),
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    await _invokeCallback(onUnknownHostKey);
    return const RemoteCommandResult(exitCode: 0, stdout: 'ok', stderr: '');
  }

  @override
  Future<RemoteCommandResult> runOneShotCommandForBinding({
    required ConnectionTargetBinding binding,
    required String command,
    Duration timeout = const Duration(seconds: 15),
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    await _invokeCallback(onUnknownHostKey);
    return const RemoteCommandResult(exitCode: 0, stdout: 'ok', stderr: '');
  }
}
