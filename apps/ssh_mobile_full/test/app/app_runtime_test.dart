import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connection_core/connection_core.dart';
import 'package:drift/native.dart';
import 'package:feature_lan_share/feature_lan_share.dart' as feature_lan_share;
import 'package:feature_mcp/feature_mcp.dart' as feature_mcp;
import 'package:feature_playbook/feature_playbook.dart' as feature_playbook;
import 'package:feature_rag/feature_rag.dart' as feature_rag;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile/app/app_runtime.dart';
import 'package:ssh_mobile/app/app_runtime_factory.dart';
import 'package:ssh_mobile/app/terminal_ssh_capability_adapter.dart';
import 'package:ssh_mobile/services/network/network_protocol_v2_codec.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

/// 可注入的 NetworkRuntime 替身：记录 dispose 次数，可配置 dispose 抛错，
/// 便于确定性地验证回滚顺序和错误隔离，而不触碰 native handle。
final class _FakeNetworkRuntime implements NetworkRuntime {
  Object? disposeError;
  int disposeCalls = 0;
  int ensureCapabilityCalls = 0;
  int openCommandGatewayCalls = 0;
  bool disposed = false;
  final _FakeCommandGateway gateway = _FakeCommandGateway();
  final Set<NetworkCapability> _readyCapabilities = <NetworkCapability>{};

  @override
  NetworkRuntimeState get state =>
      disposed ? NetworkRuntimeState.disposed : NetworkRuntimeState.idle;

  @override
  NetworkRuntimeDiagnostics get diagnostics => NetworkRuntimeDiagnostics(
    state: state,
    activeConnections: 0,
    nativeHandles: 0,
    readyCapabilities: const <NetworkCapability>[],
  );

  @override
  Future<void> ensureCapability(NetworkCapability capability) async {
    if (_readyCapabilities.contains(capability)) return;
    ensureCapabilityCalls++;
    _readyCapabilities.add(capability);
  }

  @override
  Future<NetworkCommandGateway> openCommandGateway() async {
    openCommandGatewayCalls++;
    return gateway;
  }

  @override
  Future<NetworkRealtimeGateway> openRealtimeGateway() async {
    throw UnimplementedError('openRealtimeGateway is not expected in tests');
  }

  @override
  bool isCapabilityReady(NetworkCapability capability) => false;

  @override
  Future<void> dispose() async {
    disposeCalls++;
    disposed = true;
    await gateway.close();
    final error = disposeError;
    if (error != null) throw error;
  }
}

final class _FakeCommandGateway implements NetworkCommandGateway {
  final StreamController<Uint8List> _events =
      StreamController<Uint8List>.broadcast();
  final List<Uint8List> commands = <Uint8List>[];
  final NetworkProtocolV2Codec _codec = const NetworkProtocolV2Codec();

  @override
  Stream<Uint8List> get events => _events.stream;

  @override
  TransportOperationStatus sendCommand(Uint8List command) {
    commands.add(command);
    final commandId = _codec.commandId(command);
    scheduleMicrotask(() {
      if (!_events.isClosed) _events.add(_commandResultFrame(commandId));
    });
    return TransportOperationStatus.success;
  }

  Future<void> close() => _events.close();
}

Uint8List _commandResultFrame(String commandId) => Uint8List.fromList(
  _eventFrame(13, <int>[
    ..._bytesField(1, utf8.encode(commandId)),
    ..._varintField(2, 1),
  ]),
);

List<int> _eventFrame(int eventField, List<int> payload) => <int>[
  ..._bytesField(1, utf8.encode('event-a')),
  ..._varintField(2, 1),
  ..._varintField(3, 2),
  ..._bytesField(eventField, payload),
];

List<int> _varintField(int fieldNumber, int value) => <int>[
  ..._varint(fieldNumber << 3),
  ..._varint(value),
];

List<int> _bytesField(int fieldNumber, List<int> value) => <int>[
  ..._varint((fieldNumber << 3) | 2),
  ..._varint(value.length),
  ...value,
];

List<int> _varint(int value) {
  final bytes = <int>[];
  var remaining = value;
  do {
    final next = remaining & 0x7f;
    remaining >>= 7;
    bytes.add(remaining == 0 ? next : next | 0x80);
  } while (remaining != 0);
  return bytes;
}

/// ConnectionRepository 替身：initialize 永久挂起，用于证明构造失败回滚
/// 不会被一个永远不完成的启动任务阻塞。
final class _HangingConnectionRepository implements ConnectionRepository {
  int initializeCalls = 0;

  @override
  List<ConnectionConfig> get connections => const <ConnectionConfig>[];

  @override
  Future<void> initialize() {
    initializeCalls++;
    return Completer<void>().future;
  }

  @override
  Future<List<ConnectionConfig>> loadConnections() async =>
      const <ConnectionConfig>[];

  @override
  Future<void> addConnection(ConnectionConfig config) async {}

  @override
  Future<void> updateConnection(ConnectionConfig config) async {}

  @override
  Future<void> deleteConnection(String id) async {}

  @override
  Future<void> deleteConnections(List<String> ids) async {}

  @override
  Future<void> reorderConnections(int oldIndex, int newIndex) async {}

  @override
  ConnectionConfig? getConnection(String id) => null;
}

/// HostKeyRepository 替身；仅用于让 [AppRuntimeFactory] 在注入自定义
/// ConnectionRepository 时通过 Host Key 解析。
final class _FakeHostKeyRepository implements HostKeyRepository {
  @override
  Future<void> trustHostKey(
    String connectionId, {
    required String? algorithm,
    required String? fingerprint,
    required DateTime? trustedAt,
  }) async {}
}

/// 一次工厂调用所需的隔离资源：独立内存 Connection 数据库 + 独立 RAG 缓存目录。
final class _RuntimeHarness {
  _RuntimeHarness._(this.connectionDatabase, this.ragCacheDirectory);

  final ConnectionDatabase connectionDatabase;
  final Directory ragCacheDirectory;
  late final Future<AppRuntime> createFuture;

  Future<void> close() async {
    // ConnectionDatabase.dispose 幂等，重复调用安全。
    await connectionDatabase.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
    try {
      await ragCacheDirectory.delete(recursive: true);
    } on FileSystemException {
      // 已经由回滚/释放清理。
    }
  }
}

/// 构造一次 Runtime 工厂调用；所有内存数据库按测试隔离创建。
///
/// [disposeLogger] 默认 true，测试可以关闭它避免销毁跨用例共享的
/// `AppLogService` 全局单例。
Future<_RuntimeHarness> _newHarness({
  ConnectionRepository? connectionRepository,
  HostKeyRepository? hostKeyRepository,
  NetworkRuntime? networkRuntime,
  feature_lan_share.LanShareDatabaseFactory? lanShareDatabaseFactory,
  bool disposeLogger = true,
  void Function(String event)? lifecycleObserver,
}) async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  final connectionDatabase = ConnectionDatabase.forTesting(
    NativeDatabase.memory(),
  );
  final ragCacheDirectory = await Directory.systemTemp.createTemp(
    'app-runtime-rag-',
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        _pathProviderChannel,
        (_) async => ragCacheDirectory.path,
      );
  final harness = _RuntimeHarness._(connectionDatabase, ragCacheDirectory);
  harness.createFuture = AppRuntimeFactory.create(
    connectionDatabase: connectionDatabase,
    connectionRepository: connectionRepository,
    credentialRepository: SecureCredentialRepository(),
    hostKeyRepository: hostKeyRepository,
    networkRuntime: networkRuntime,
    lanShareDatabaseFactory:
        lanShareDatabaseFactory ??
        () => feature_lan_share.LanShareDatabase.forTesting(
          NativeDatabase.memory(),
        ),
    lanShareReceiverEnabled: false,
    playbookDatabaseFactory: () =>
        feature_playbook.PlaybookDatabase.forTesting(NativeDatabase.memory()),
    ragDatabaseFactory: () =>
        feature_rag.RagDatabase.forTesting(NativeDatabase.memory()),
    ragCacheStoreFactory: () => feature_rag.RagCacheStore(
      directoryFactory: () async => ragCacheDirectory,
    ),
    mcpDatabaseFactory: () =>
        feature_mcp.McpDatabase.forTesting(NativeDatabase.memory()),
    disposeLogger: disposeLogger,
    lifecycleObserver: lifecycleObserver,
  );
  return harness;
}

/// 从 lifecycleObserver 事件中解析回滚优先级序列。
List<int> _rollbackPriorities(List<String> events) {
  const prefix = 'rollback.priority-';
  return events
      .where((event) => event.startsWith(prefix))
      .map((event) => int.parse(event.substring(prefix.length)))
      .toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });

  tearDownAll(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'AppRuntimeFactory creates one app scope and disposes idempotently',
    () async {
      final network = _FakeNetworkRuntime();
      final harness = await _newHarness(
        networkRuntime: network,
        disposeLogger: false,
      );
      try {
        final runtime = await harness.createFuture;

        expect(runtime.isDisposed, isFalse);
        expect(runtime.appLogService, isNotNull);
        expect(runtime.logger, same(runtime.appLogService));
        expect(runtime.aiStorageAdapter, isNotNull);
        expect(runtime.connectionDatabase, isNotNull);
        expect(runtime.connectionRepository, isNotNull);
        expect(runtime.credentialRepository, isNotNull);
        expect(runtime.hostKeyRepository, same(runtime.connectionRepository));
        expect(runtime.networkRuntime, isNotNull);
        expect(runtime.networkIdentityService, isNotNull);
        expect(runtime.realtimeClient, isA<RealtimeClient>());
        expect(runtime.networkFacade, isA<NetworkFacade>());
        expect(network.ensureCapabilityCalls, 1);
        expect(network.openCommandGatewayCalls, 1);
        expect(network.gateway.commands, hasLength(1));
        expect(runtime.sshService, isNotNull);
        expect(runtime.sshSessionManager, isA<AppTerminalSshSessionManager>());
        final terminalManager =
            runtime.sshSessionManager as AppTerminalSshSessionManager;
        expect(terminalManager.service, same(runtime.sshService));
        expect(
          runtime.sshSessionManager.terminalCapability,
          same(terminalManager.terminal),
        );
        expect(runtime.lanReceiverCoordinator, isNotNull);
        expect(runtime.ragModule.service, same(runtime.ragService));

        final firstDispose = runtime.dispose();
        final secondDispose = runtime.dispose();

        expect(identical(firstDispose, secondDispose), isTrue);
        await firstDispose;
        expect(runtime.isDisposed, isTrue);
        expect(network.disposeCalls, 1);
      } finally {
        await harness.close();
      }
    },
  );

  test(
    'construction failure does not start lazy pending initializers',
    () async {
      final events = <String>[];
      final repository = _HangingConnectionRepository();
      final harness = await _newHarness(
        connectionRepository: repository,
        hostKeyRepository: _FakeHostKeyRepository(),
        lanShareDatabaseFactory: () =>
            throw StateError('injected lan share failure'),
        disposeLogger: false,
        lifecycleObserver: events.add,
      );
      try {
        // Initializers start only after ownership transfers to a valid Runtime,
        // so a construction failure cannot leave a DB task behind cleanup.
        await expectLater(
          harness.createFuture.timeout(const Duration(seconds: 10)),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('injected lan share failure'),
            ),
          ),
        );
        // 回滚必须跑完整个优先级图，至少到达数据库(20)清理。
        final priorities = _rollbackPriorities(events);
        expect(priorities, containsAll(<int>[80, 70, 60, 50, 40, 30, 20]));
        expect(repository.initializeCalls, 0);
      } finally {
        await harness.close();
      }
    },
  );

  test('construction failure rolls back in reverse priority order', () async {
    final events = <String>[];
    final harness = await _newHarness(
      lanShareDatabaseFactory: () =>
          throw StateError('injected lan share failure'),
      disposeLogger: false,
      lifecycleObserver: events.add,
    );
    try {
      await expectLater(harness.createFuture, throwsA(isA<StateError>()));

      final priorities = _rollbackPriorities(events);
      expect(priorities, isNotEmpty);
      // 适配器(80) → Module(70) → Realtime(60) → SFTP(50) → SSH(40) →
      // metadata(35) → Network(30) → database(20) → settings(10)。
      expect(
        priorities.toSet(),
        containsAll(<int>[80, 70, 60, 50, 40, 35, 30, 20, 10]),
      );
      for (var i = 1; i < priorities.length; i++) {
        expect(
          priorities[i],
          lessThanOrEqualTo(priorities[i - 1]),
          reason: 'rollback must run in reverse priority order',
        );
      }
    } finally {
      await harness.close();
    }
  });

  test(
    'a throwing cleanup does not prevent later cleanups from running',
    () async {
      final events = <String>[];
      final network = _FakeNetworkRuntime()
        ..disposeError = StateError('network dispose failed');
      final harness = await _newHarness(
        networkRuntime: network,
        lanShareDatabaseFactory: () =>
            throw StateError('injected lan share failure'),
        disposeLogger: false,
        lifecycleObserver: events.add,
      );
      try {
        await expectLater(harness.createFuture, throwsA(isA<StateError>()));

        // Network(30) dispose 抛错后，database(20)/settings(10) 仍被尝试。
        expect(network.disposeCalls, 1);
        final priorities = _rollbackPriorities(events);
        expect(priorities, containsAll(<int>[20, 10]));
        // 后续优先级仍保持非递增，说明清理没有被 Network 的异常打断。
        final networkIndex = priorities.lastIndexOf(30);
        final databaseIndex = priorities.indexOf(20);
        expect(databaseIndex, greaterThan(networkIndex));
      } finally {
        await harness.close();
      }
    },
  );

  test(
    'original construction error is preserved over a cleanup error',
    () async {
      final network = _FakeNetworkRuntime()
        ..disposeError = StateError('network dispose failed');
      final harness = await _newHarness(
        networkRuntime: network,
        lanShareDatabaseFactory: () =>
            throw StateError('injected construction failure'),
        disposeLogger: false,
      );
      try {
        await expectLater(
          harness.createFuture,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'injected construction failure',
            ),
          ),
        );
      } finally {
        await harness.close();
      }
    },
  );

  test('dispose releases resources in Module → Realtime → SFTP → SSH → '
      'Network → Database → Logger order', () async {
    final events = <String>[];
    final harness = await _newHarness(
      disposeLogger: true,
      lifecycleObserver: events.add,
    );
    try {
      final runtime = await harness.createFuture;
      await runtime.dispose();

      final starts = <String>[
        for (final event in events)
          if (event.endsWith('.start'))
            event.substring(0, event.length - '.start'.length),
      ];
      int indexOf(String name) {
        final index = starts.indexOf(name);
        expect(
          index,
          isNot(-1),
          reason: 'expected lifecycle start event $name in $starts',
        );
        return index;
      }

      final moduleIndex = indexOf('mcp-module.dispose');
      final realtimeIndex = indexOf('realtime.dispose');
      final sftpIndex = indexOf('sftp.dispose');
      final sshIndex = indexOf('ssh.close');
      final networkIndex = indexOf('network.dispose');
      final databaseIndex = indexOf('connection-database.dispose');
      final loggerIndex = indexOf('app-log.dispose');

      expect(moduleIndex, lessThan(realtimeIndex));
      expect(realtimeIndex, lessThan(sftpIndex));
      expect(sftpIndex, lessThan(sshIndex));
      expect(sshIndex, lessThan(networkIndex));
      expect(networkIndex, lessThan(databaseIndex));
      expect(databaseIndex, lessThan(loggerIndex));
    } finally {
      await harness.close();
    }
  });
}
