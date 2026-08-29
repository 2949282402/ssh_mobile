// App Developer Feature adapter coverage.
//
// Exercises the three adapters at the public Developer ports boundary with
// deterministic service fakes: settings forwarding, log snapshot conversion,
// diagnostics status/snapshot, telemetry control forwarding, and native
// memory reads through a mocked platform channel.

import 'dart:async';

import 'package:app_core/app_core.dart' as app_core;
import 'package:feature_developer/feature_developer.dart' as developer;
import 'package:feature_mcp/feature_mcp.dart' as feature_mcp;
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:feature_rag/feature_rag.dart' as feature_rag;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile/app/developer_feature_adapters.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/ssh_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const memoryChannel = MethodChannel('ssh_mobile/native_memory');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(memoryChannel, null);
  });

  group('AppDeveloperSettingsAdapter', () {
    test('forwards values and relays settings notifications', () {
      final settings = _FakeSettings();
      final adapter = AppDeveloperSettingsAdapter(settings);
      var notifications = 0;
      adapter.addListener(() => notifications++);

      expect(adapter.language, AppLanguage.en);
      expect(adapter.developerMode, isFalse);
      expect(adapter.floatingPanelEnabled, isFalse);

      settings
        ..language = AppLanguage.zh
        ..developerMode = true
        ..developerPanelFloating = true;
      settings.emitChange();

      expect(notifications, 1);
      expect(adapter.language, AppLanguage.zh);
      expect(adapter.developerMode, isTrue);
      expect(adapter.floatingPanelEnabled, isTrue);

      adapter.dispose();
      settings.emitChange();
      expect(notifications, 1);
    });
  });

  group('AppDeveloperLogAdapter', () {
    test('maps every log level and forwards entry snapshots', () {
      final log = AppLogService.instance;
      log.clear();
      for (final level in AppLogLevel.values) {
        log.add(
          level.name,
          'message ${level.name}',
          captureSource: false,
          sourceLocation: 'developer_feature_adapters_test.dart',
        );
      }
      addTearDown(() async {
        log.clear();
        await log.pendingWrites;
      });
      final adapter = AppDeveloperLogAdapter(log);
      addTearDown(adapter.dispose);

      final entries = adapter.entries;
      expect(entries, hasLength(AppLogLevel.values.length));
      for (final entry in entries) {
        expect(entry.text, contains('message'));
      }
      expect(
        adapter.levelCounts[developer.DeveloperLogLevel.info],
        log.levelCounts[AppLogLevel.info],
      );

      final filtered = adapter.entriesForLevel(
        developer.DeveloperLogLevel.warning,
      );
      expect(filtered.single.level, developer.DeveloperLogLevel.warning);
      expect(adapter.entryIds, isNotEmpty);

      final idsToDelete = adapter.entryIds.take(2).toSet();
      adapter.deleteEntriesById(idsToDelete);
      expect(log.entryIds, isNot(containsAll(idsToDelete)));
      adapter.clear();
      expect(log.entries, isEmpty);
    });

    test('maps all levels in both directions and relays notifications', () {
      final log = _FakeLogService();
      final adapter = AppDeveloperLogAdapter(log);
      var notifications = 0;
      adapter.addListener(() => notifications++);

      expect(
        adapter.levelCounts.keys,
        containsAll(developer.DeveloperLogLevel.values),
      );
      for (final level in developer.DeveloperLogLevel.values) {
        adapter.entriesForLevel(level);
      }
      expect(log.filteredLevels, containsAll(AppLogLevel.values));

      log.emitChange();
      expect(notifications, 1);

      adapter.dispose();
      log.emitChange();
      expect(notifications, 1);
    });
  });

  group('AppDeveloperDiagnosticsAdapter', () {
    test('reports component statuses for every state branch', () async {
      final telemetry = _FakeTelemetryClient();
      final ssh = _FakeSshService();
      final log = _FakeLogService()
        ..entries.addAll([
          _entryForLevel(AppLogLevel.info),
          _entryForLevel(AppLogLevel.warning),
        ]);
      final rag = _newRagService();
      await rag.init();
      addTearDown(rag.close);
      final adapter = _adapter(
        ssh: ssh,
        rag: rag,
        log: log,
        telemetry: telemetry,
      );
      addTearDown(adapter.dispose);

      ssh
        ..sessions = List<SshSession>.generate(
          3,
          (index) => _diagnosticSession('diag-$index'),
        )
        ..isConnected = true;
      final statuses = adapter.componentStatuses;
      expect(
        statuses
            .singleWhere((s) => s.id == developer.DeveloperComponentId.ssh)
            .state,
        '3 sessions · connected',
      );
      expect(
        statuses
            .singleWhere((s) => s.id == developer.DeveloperComponentId.rag)
            .state,
        'index loaded',
      );
      expect(
        statuses
            .singleWhere(
              (s) => s.id == developer.DeveloperComponentId.mcpServer,
            )
            .state,
        'running',
      );
      expect(
        statuses
            .singleWhere(
              (s) => s.id == developer.DeveloperComponentId.performanceMonitor,
            )
            .state,
        'sampling',
      );
      expect(
        statuses
            .singleWhere(
              (s) => s.id == developer.DeveloperComponentId.logBuffer,
            )
            .state,
        '2 entries',
      );
      expect(
        statuses
            .singleWhere(
              (s) => s.id == developer.DeveloperComponentId.telemetry,
            )
            .state,
        'v7 · active',
      );
    });

    test(
      'covers idle, loading, running and disabled telemetry branches',
      () async {
        final telemetry = _FakeTelemetryClient()
          ..policy = const app_core.TelemetryUploadPolicy(
            uploadEnabled: false,
            batchSizeThreshold: 50,
            timeIntervalSeconds: 60,
            maxBatchSize: 100,
            clientMaxLocalRecords: 10000,
            specialTriggers: [
              'highPriorityError',
              'appBackground',
              'networkRecovered',
              'appForegroundWithBacklog',
            ],
            policyVersion: 3,
          );
        final repository = _FakeRagRepository(
          snapshotCompleter: Completer<feature_rag.RagRepositorySnapshot>(),
        );
        final rag = _newRagService(repository: repository);
        final initialization = rag.init();
        await Future<void>.delayed(Duration.zero);
        addTearDown(() async {
          if (!repository.snapshotCompleter!.isCompleted) {
            repository.snapshotCompleter!.complete(
              const feature_rag.RagRepositorySnapshot(
                documents: [],
                index: null,
                cacheEntries: [],
              ),
            );
          }
          await initialization;
          await rag.close();
        });
        final performance = _FakeMonitoringService()..isRunning = true;
        final ssh = _FakeSshService();
        final adapter = _adapter(
          ssh: ssh,
          rag: rag,
          performance: performance,
          telemetry: telemetry,
        );
        addTearDown(adapter.dispose);

        final statuses = adapter.componentStatuses;
        expect(
          statuses
              .singleWhere((s) => s.id == developer.DeveloperComponentId.rag)
              .state,
          'indexing…',
        );
        expect(
          statuses
              .singleWhere(
                (s) =>
                    s.id == developer.DeveloperComponentId.performanceMonitor,
              )
              .state,
          'running',
        );
        expect(
          statuses
              .singleWhere(
                (s) => s.id == developer.DeveloperComponentId.telemetry,
              )
              .state,
          'v3 · disabled',
        );
      },
    );

    test('snapshot reads modules, services, databases and resources', () {
      final ssh = _FakeSshService()
        ..activeSessionCount = 2
        ..idleSessionCount = 1
        ..leaseCount = 3
        ..activeTimerCount = 3
        ..activeSubscriptionCount = 4;
      final log = _FakeLogService()..activeTimerCount = 2;
      final performance = _FakeMonitoringService()..isRunning = true;
      final network = _FakeNetworkRuntime()
        ..activeConnections = 5
        ..nativeHandles = 2;
      final telemetry = _FakeTelemetryClient();
      final adapter = _adapter(
        ssh: ssh,
        log: log,
        performance: performance,
        network: network,
        telemetry: telemetry,
      );

      final snapshot = adapter.snapshot;
      expect(snapshot.modules, hasLength(2));
      expect(snapshot.modules[0].id, 'ai');
      expect(snapshot.modules[1].state, app_core.ModuleState.inactive);
      expect(snapshot.ssh.activeSessions, 2);
      expect(snapshot.ssh.idleSessions, 1);
      expect(snapshot.ssh.leaseCount, 3);
      expect(snapshot.network.activeConnections, 5);
      expect(snapshot.network.nativeHandles, 2);
      expect(snapshot.databases.map((database) => database.opened), [
        true,
        false,
      ]);
      expect(snapshot.resources.activeTimers, 2 + 1 + 3);
      expect(snapshot.resources.activeSubscriptions, 5 + 4);
      expect(snapshot.telemetry!.uploadEnabled, isTrue);
      expect(snapshot.telemetry!.policyVersion, 7);
      expect(snapshot.telemetry!.isUploading, isTrue);
    });

    test(
      'telemetry control methods return defaults without a client',
      () async {
        final adapter = _adapter();

        expect(await adapter.replayTelemetry(), 0);
        expect(await adapter.refreshTelemetryPolicy(), isFalse);
        await adapter.flushTelemetry();
        expect(adapter.snapshot.telemetry, isNull);
        expect(await adapter.readNativeMemory(), isNull);
      },
    );

    test('telemetry controls forward to the injected client', () async {
      final telemetry = _FakeTelemetryClient();
      final adapter = _adapter(telemetry: telemetry);

      expect(await adapter.replayTelemetry(), 7);
      expect(await adapter.refreshTelemetryPolicy(), isTrue);
      await adapter.flushTelemetry();
      expect(telemetry.replayCount, 1);
      expect(telemetry.flushCount, 1);
      expect(telemetry.refreshCount, 1);
    });

    test('readNativeMemory maps the platform snapshot', () async {
      messenger.setMockMethodCallHandler(memoryChannel, (call) async {
        expect(call.method, 'getMemoryStats');
        return <String, Object?>{
          'available': true,
          'javaHeap': 917504,
          'nativeHeap': 524288,
          'graphics': 262144,
          'code': 131072,
          'totalPss': 2000000,
        };
      });
      final adapter = _adapter();

      final snapshot = await adapter.readNativeMemory();
      expect(snapshot, isNotNull);
      expect(snapshot!.available, isTrue);
      expect(snapshot.javaHeapBytes, 917504);
      expect(snapshot.nativeHeapBytes, 524288);
      expect(snapshot.graphicsBytes, 262144);
      expect(snapshot.codeBytes, 131072);
      expect(snapshot.totalPssBytes, 2000000);
    });

    test(
      'relays source changes, disposes idempotently and asserts release',
      () {
        final ssh = _FakeSshService();
        final adapter = _adapter(ssh: ssh);
        var notifications = 0;
        adapter.addListener(() => notifications++);
        expect(adapter.activeSubscriptionCount, 5);
        expect(adapter.debugAssertReleased, throwsStateError);

        ssh.emitChange();
        expect(notifications, 1);

        adapter.dispose();
        adapter.dispose();
        expect(adapter.activeSubscriptionCount, 0);
        expect(adapter.debugAssertReleased, returnsNormally);

        ssh.emitChange();
        expect(notifications, 1);
      },
    );
  });
}

AppLogEntry _entryForLevel(AppLogLevel level) {
  return AppLogEntry(
    id: _levelIndex(level),
    time: DateTime(2026, 1, _levelIndex(level)),
    level: level.name,
    message: 'message ${level.name}',
    sourceLocation: 'developer_feature_adapters_test.dart',
    stackTrace: null,
    details: null,
  );
}

AppDeveloperDiagnosticsAdapter _adapter({
  _FakeSshService? ssh,
  feature_rag.RagService? rag,
  _FakeMcpController? mcp,
  _FakeMonitoringService? performance,
  _FakeLogService? log,
  _FakeNetworkRuntime? network,
  app_core.TelemetryClient? telemetry,
}) {
  return AppDeveloperDiagnosticsAdapter(
    sshService: ssh ?? _FakeSshService(),
    ragService: rag ?? _newRagService(),
    mcpServer: mcp ?? (_FakeMcpController()..running = true),
    performanceMonitor:
        performance ?? (_FakeMonitoringService()..isSampling = true),
    logService: log ?? _FakeLogService(),
    modules: [
      _FakeAppModule('ai', app_core.ModuleState.active),
      _FakeAppModule('rag', app_core.ModuleState.inactive),
    ],
    networkRuntime: network ?? _FakeNetworkRuntime(),
    databaseDescriptors: [
      const developer.DeveloperDatabaseDescriptor(
        moduleId: 'ai',
        databaseName: 'ai.db',
        isOpen: _isOpenTrue,
      ),
      const developer.DeveloperDatabaseDescriptor(
        moduleId: 'rag',
        databaseName: 'rag.db',
        isOpen: _isOpenFalse,
      ),
    ],
    telemetryClient: telemetry,
  );
}

bool _isOpenTrue() => true;
bool _isOpenFalse() => false;

final class _FakeSettings extends Fake implements AppSettings {
  @override
  AppLanguage language = AppLanguage.en;
  @override
  bool developerMode = false;
  @override
  bool developerPanelFloating = false;

  final List<VoidCallback> _listeners = <VoidCallback>[];

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void emitChange() {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }
}

final class _FakeLogService extends Fake implements AppLogService {
  @override
  final List<AppLogEntry> entries = <AppLogEntry>[];
  @override
  Map<AppLogLevel, int> levelCounts = {
    for (final level in AppLogLevel.values) level: 1,
  };
  @override
  Set<int> entryIds = {1, 2, 3};
  final List<AppLogLevel> filteredLevels = <AppLogLevel>[];
  Set<int> deletedIds = <int>{};
  bool cleared = false;
  @override
  int activeTimerCount = 0;

  final List<VoidCallback> _listeners = <VoidCallback>[];

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void emitChange() {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  @override
  List<AppLogEntry> entriesForLevel(AppLogLevel level) {
    filteredLevels.add(level);
    if (level == AppLogLevel.all) {
      return List<AppLogEntry>.of(entries);
    }
    return entries
        .where((entry) => entry.normalizedLevel == level)
        .toList(growable: false);
  }

  void deleteEntriesById(Set<int> ids) => deletedIds = Set<int>.of(ids);

  void clear() => cleared = true;
}

final class _FakeSshService extends Fake implements SshService {
  @override
  List<SshSession> sessions = const <SshSession>[];
  @override
  bool isConnected = false;
  @override
  int activeSessionCount = 0;
  @override
  int idleSessionCount = 0;
  @override
  int leaseCount = 0;
  @override
  int activeTimerCount = 0;
  @override
  int activeSubscriptionCount = 0;

  final List<VoidCallback> _listeners = <VoidCallback>[];

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void emitChange() {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }
}

final class _FakeMcpController extends Fake
    implements feature_mcp.McpServerController {
  @override
  bool running = true;

  final List<VoidCallback> _listeners = <VoidCallback>[];

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);
}

final class _FakeMonitoringService extends Fake
    implements monitoring.MonitoringService {
  @override
  bool isRunning = false;
  @override
  bool isSampling = false;

  final List<VoidCallback> _listeners = <VoidCallback>[];

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);
}

final class _FakeNetworkRuntime implements NetworkRuntime {
  int activeConnections = 0;
  int nativeHandles = 0;

  @override
  NetworkRuntimeState get state => NetworkRuntimeState.idle;

  @override
  NetworkRuntimeDiagnostics get diagnostics => NetworkRuntimeDiagnostics(
    state: state,
    activeConnections: activeConnections,
    nativeHandles: nativeHandles,
    readyCapabilities: const <NetworkCapability>[],
  );

  @override
  Future<void> ensureCapability(NetworkCapability capability) async {}

  @override
  Future<NetworkCommandGateway> openCommandGateway() async {
    throw UnimplementedError('not used by Developer diagnostics');
  }

  @override
  Future<NetworkRealtimeGateway> openRealtimeGateway() async {
    throw UnimplementedError('not used by Developer diagnostics');
  }

  @override
  bool isCapabilityReady(NetworkCapability capability) => false;

  @override
  Future<void> dispose() async {}
}

final class _FakeAppModule extends Fake implements app_core.AppModule {
  _FakeAppModule(this.id, this.state);

  @override
  final String id;

  @override
  final app_core.ModuleState state;
}

final class _FakeTelemetryClient extends Fake
    implements app_core.TelemetryClient {
  app_core.TelemetryUploadPolicy policy = const app_core.TelemetryUploadPolicy(
    uploadEnabled: true,
    batchSizeThreshold: 50,
    timeIntervalSeconds: 60,
    maxBatchSize: 100,
    clientMaxLocalRecords: 10000,
    specialTriggers: [
      'highPriorityError',
      'appBackground',
      'networkRecovered',
      'appForegroundWithBacklog',
    ],
    policyVersion: 7,
  );
  app_core.TelemetryDiagnosticsSnapshot diagnostics =
      const app_core.TelemetryDiagnosticsSnapshot(
        localPendingCount: 4,
        localRejectedCount: 1,
        localSyncedCount: 10,
        totalCount: 15,
        cacheOverflow: false,
        uploadEnabled: true,
        policyVersion: 7,
        batchSizeThreshold: 50,
        timeIntervalSeconds: 60,
        maxBatchSize: 100,
        clientMaxLocalRecords: 10000,
        isUploading: true,
      );
  int replayCount = 0;
  int flushCount = 0;
  int refreshCount = 0;

  @override
  app_core.TelemetryUploadPolicy get activePolicy => policy;

  @override
  app_core.TelemetryDiagnosticsSnapshot get latestDiagnostics => diagnostics;

  @override
  Future<int> replayAllLocalRecords() async {
    replayCount++;
    return 7;
  }

  @override
  Future<void> flush() async {
    flushCount++;
  }

  @override
  Future<bool> refreshPolicy() async {
    refreshCount++;
    return true;
  }
}

int _levelIndex(AppLogLevel level) => AppLogLevel.values.indexOf(level) + 1;

SshSession _diagnosticSession(String id) => SshSession(
  id: id,
  connectionId: 'diagnostics',
  connectionName: 'Diagnostics',
  outputController: StreamController<String>.broadcast(),
);

feature_rag.RagService _newRagService({_FakeRagRepository? repository}) {
  return feature_rag.RagService(
    repository: repository ?? _FakeRagRepository(),
    settings: _FakeRagSettings(),
    logger: const _FakeRagLogger(),
  );
}

final class _FakeRagRepository implements feature_rag.RagRepository {
  _FakeRagRepository({this.snapshotCompleter});

  final Completer<feature_rag.RagRepositorySnapshot>? snapshotCompleter;

  @override
  Future<feature_rag.RagRepositorySnapshot> loadSnapshot() {
    return snapshotCompleter?.future ??
        Future<feature_rag.RagRepositorySnapshot>.value(
          const feature_rag.RagRepositorySnapshot(
            documents: [],
            index: null,
            cacheEntries: [],
          ),
        );
  }

  @override
  Future<void> saveState({
    required List<feature_rag.RagDocumentMetadata> documents,
    required feature_rag.RagIndexMetadata index,
    required List<feature_rag.RagCacheMetadata> cacheEntries,
  }) async {}

  @override
  Future<void> updateCacheEntry(feature_rag.RagCacheMetadata entry) async {}

  @override
  Future<void> deleteCacheEntry(String documentId) async {}
}

final class _FakeRagSettings extends ChangeNotifier
    implements feature_rag.RagSettingsPort {
  @override
  bool isEnglish = true;

  @override
  feature_rag.RagSearchMode searchMode = feature_rag.RagSearchMode.bm25;

  @override
  Future<String?> getAliyunApiKey() async => null;

  @override
  Future<void> saveAliyunApiKey(String key) async {}
}

final class _FakeRagLogger implements feature_rag.RagLoggerPort {
  const _FakeRagLogger();

  @override
  void info(String message, {String? details}) {}

  @override
  void warning(String message, {String? details}) {}

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {}
}
