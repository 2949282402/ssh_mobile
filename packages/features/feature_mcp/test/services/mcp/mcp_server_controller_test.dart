import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_mcp/feature_mcp.dart';

void main() {
  test(
    'self-test checks initialize and tools/list without executing tools',
    () async {
      final server = _FakeHttpServerHandle();
      final selfTestTransport = _FakeSelfTestTransport([
        const McpSelfTestResponse(
          reachable: true,
          statusCode: 200,
          succeeded: true,
        ),
        const McpSelfTestResponse(
          reachable: true,
          statusCode: 200,
          succeeded: true,
        ),
      ]);
      final settings = _FakeSettings(
        value: const McpServerSettings(
          enabled: true,
          host: '127.0.0.1',
          port: 38321,
          token: 'test-token',
        ),
      );
      final executor = _FakeToolExecutor();
      final controller = _createController(
        settings,
        () => executor,
        serverFactory:
            ({
              required host,
              required port,
              required token,
              required router,
              required activityRecorder,
              required logger,
            }) async => server,
        selfTestTransport: selfTestTransport,
      );
      addTearDown(() {
        controller.dispose();
        settings.dispose();
      });

      await controller.start();
      final result = await controller.runSelfTest();

      expect(result.succeeded, isTrue);
      expect(result.serverReachable, isTrue);
      expect(result.authenticated, isTrue);
      expect(result.initialized, isTrue);
      expect(result.toolsListed, isTrue);
      expect(executor.executedTools, isEmpty);
      expect(selfTestTransport.requests, 2);
      expect(server.closed, isFalse);
    },
  );

  test('self-test never starts a stopped server', () async {
    final settings = _FakeSettings();
    final controller = _createController(settings, _FakeToolExecutor.new);
    addTearDown(() {
      controller.dispose();
      settings.dispose();
    });

    final result = await controller.runSelfTest();

    expect(result.succeeded, isFalse);
    expect(result.failureCode, 'server_not_running');
    expect(controller.running, isFalse);
  });

  test('stop invalidates a start waiting for the port probe', () async {
    final probeEntered = Completer<void>();
    final releaseProbe = Completer<void>();
    final settings = _FakeSettings(
      value: const McpServerSettings(token: 'test-token'),
    );
    var serverFactoryCalls = 0;
    final controller = _createController(
      settings,
      _FakeToolExecutor.new,
      portProbe: McpPortProbe(
        bind: (host, port) async {
          probeEntered.complete();
          await releaseProbe.future;
          return _FakePortReservation();
        },
      ),
      serverFactory:
          ({
            required host,
            required port,
            required token,
            required router,
            required activityRecorder,
            required logger,
          }) async {
            serverFactoryCalls += 1;
            return _FakeHttpServerHandle();
          },
    );
    addTearDown(() {
      controller.dispose();
      settings.dispose();
    });

    final start = controller.start();
    await probeEntered.future;
    final stop = controller.stop();
    releaseProbe.complete();
    await start;
    await stop;

    expect(controller.running, isFalse);
    expect(controller.status, McpServerRunStatus.stopped);
    expect(serverFactoryCalls, 0);
  });

  test('dispose closes a server handle returned by a late start', () async {
    final factoryEntered = Completer<void>();
    final releaseFactory = Completer<void>();
    final server = _FakeHttpServerHandle();
    final settings = _FakeSettings(
      value: const McpServerSettings(token: 'test-token'),
    );
    final controller = _createController(
      settings,
      _FakeToolExecutor.new,
      serverFactory:
          ({
            required host,
            required port,
            required token,
            required router,
            required activityRecorder,
            required logger,
          }) async {
            factoryEntered.complete();
            await releaseFactory.future;
            return server;
          },
    );
    addTearDown(settings.dispose);

    final start = controller.start();
    await factoryEntered.future;
    controller.dispose();
    releaseFactory.complete();
    await start;

    expect(server.closed, isTrue);
    expect(controller.running, isFalse);
    expect(controller.status, McpServerRunStatus.stopped);
  });

  test('close waits for the active HTTP server shutdown barrier', () async {
    final closeGate = Completer<void>();
    final server = _FakeHttpServerHandle(closeGate: closeGate);
    final settings = _FakeSettings(
      value: const McpServerSettings(token: 'test-token'),
    );
    final controller = _createController(
      settings,
      _FakeToolExecutor.new,
      serverFactory:
          ({
            required host,
            required port,
            required token,
            required router,
            required activityRecorder,
            required logger,
          }) async => server,
    );
    addTearDown(() {
      controller.dispose();
      settings.dispose();
    });
    await controller.start();

    var closeCompleted = false;
    final closing = controller.close().whenComplete(
      () => closeCompleted = true,
    );
    await Future<void>.delayed(Duration.zero);

    expect(server.closed, isTrue);
    expect(closeCompleted, isFalse);
    closeGate.complete();
    await closing;
    expect(controller.running, isFalse);
  });

  test('policy changes reject pending external approvals', () async {
    final settings = _FakeSettings();
    final queue = McpApprovalQueue();
    final controller = _createController(
      settings,
      _FakeToolExecutor.new,
      approvalQueue: queue,
    );
    addTearDown(() {
      controller.dispose();
      settings.dispose();
    });

    var executed = false;
    final pending = queue.enqueue(
      request: _request(),
      executeApproved: () async {
        executed = true;
        return 'executed';
      },
    );
    await _waitFor(() => queue.pending.isNotEmpty);

    final approvalId = queue.pending.single.id;
    final modeChange = settings.setMcpApprovalMode(
      McpApprovalMode.trustedAgent,
    );
    await queue.approve(approvalId);
    await modeChange;

    expect(await pending, contains('approval_rejected'));
    expect(executed, isFalse);
    expect(queue.pending, isEmpty);
  });

  test('token regeneration rejects pending external approvals', () async {
    final settings = _FakeSettings();
    final queue = McpApprovalQueue();
    final controller = _createController(
      settings,
      _FakeToolExecutor.new,
      approvalQueue: queue,
    );
    addTearDown(() {
      controller.dispose();
      settings.dispose();
    });

    var executed = false;
    final pending = queue.enqueue(
      request: _request(),
      executeApproved: () async {
        executed = true;
        return 'executed';
      },
    );
    await _waitFor(() => queue.pending.isNotEmpty);

    final approvalId = queue.pending.single.id;
    await settings.regenerateMcpServerToken();
    await queue.approve(approvalId);

    expect(await pending, contains('approval_rejected'));
    expect(executed, isFalse);
    expect(queue.pending, isEmpty);
  });

  test('exposure changes reject pending external approvals', () async {
    final settings = _FakeSettings();
    final queue = McpApprovalQueue();
    final controller = _createController(
      settings,
      _FakeToolExecutor.new,
      approvalQueue: queue,
    );
    addTearDown(() {
      controller.dispose();
      settings.dispose();
    });

    var executed = false;
    final pending = queue.enqueue(
      request: _request(),
      executeApproved: () async {
        executed = true;
        return 'executed';
      },
    );
    await _waitFor(() => queue.pending.isNotEmpty);

    final approvalId = queue.pending.single.id;
    final exposureChange = settings.setMcpToolExposure(
      'run_command',
      false,
      availableToolNames: const {'run_command', 'list_servers'},
    );
    await queue.approve(approvalId);
    await exposureChange;

    expect(await pending, contains('approval_rejected'));
    expect(executed, isFalse);
    expect(queue.pending, isEmpty);
  });

  test('server startup failures expose only a stable error code', () async {
    const secret = 'MCP_STARTUP_SECRET_20260824';
    final settings = _FakeSettings(
      value: const McpServerSettings(token: 'test-token'),
    );
    final logger = _RecordingLogger();
    final controller = _createController(
      settings,
      _FakeToolExecutor.new,
      logger: logger,
      serverFactory:
          ({
            required host,
            required port,
            required token,
            required router,
            required activityRecorder,
            required logger,
          }) async {
            throw StateError('Authorization: Bearer $secret');
          },
    );
    addTearDown(() {
      controller.dispose();
      settings.dispose();
    });

    await controller.start();

    expect(controller.status, McpServerRunStatus.failed);
    expect(controller.lastError, 'server_start_failed');
    final logText = logger.entries.join('\n');
    expect(logText, contains('errorCode=server_start_failed'));
    expect(logText, contains('errorType=StateError'));
    expect(logText, isNot(contains(secret)));
  });

  test('settings and token startup failures remain redacted', () async {
    const secret = 'MCP_SETTINGS_SECRET_20260824';
    final loadLogger = _RecordingLogger();
    final loadSettings = _FakeSettings(
      value: const McpServerSettings(enabled: true),
      loadError: StateError('Authorization: Bearer $secret'),
    );
    final loadController = _createController(
      loadSettings,
      _FakeToolExecutor.new,
      logger: loadLogger,
    );
    final tokenLogger = _RecordingLogger();
    final tokenSettings = _FakeSettings(
      tokenError: StateError('Authorization: Bearer $secret'),
    );
    final tokenController = _createController(
      tokenSettings,
      _FakeToolExecutor.new,
      logger: tokenLogger,
    );
    addTearDown(() {
      loadController.dispose();
      loadSettings.dispose();
      tokenController.dispose();
      tokenSettings.dispose();
    });

    await loadController.startIfEnabled();
    await tokenController.start();

    expect(loadController.lastError, 'settings_load_failed');
    expect(tokenController.lastError, 'server_start_failed');
    expect(loadLogger.entries.join('\n'), isNot(contains(secret)));
    expect(tokenLogger.entries.join('\n'), isNot(contains(secret)));
  });
}

McpServerController _createController(
  McpSettingsPort settings,
  McpToolExecutor Function() factory, {
  McpApprovalQueue? approvalQueue,
  McpPortProbe? portProbe,
  McpHttpServerFactory? serverFactory,
  McpSelfTestTransport? selfTestTransport,
  McpLoggerPort logger = const _FakeLogger(),
}) {
  return McpServerController(
    settings: settings,
    toolServiceFactory: factory,
    activityRepository: _MemoryActivityRepository(),
    logger: logger,
    approvalQueue: approvalQueue,
    portProbe:
        portProbe ??
        McpPortProbe(bind: (host, port) async => _FakePortReservation()),
    serverFactory:
        serverFactory ??
        ({
          required host,
          required port,
          required token,
          required router,
          required activityRecorder,
          required logger,
        }) async => _FakeHttpServerHandle(),
    selfTestTransport: selfTestTransport ?? _FakeSelfTestTransport([]),
  );
}

McpApprovalRequest _request() => const McpApprovalRequest(
  toolName: 'run_command',
  approvalType: 'remote_write',
  connectionId: 'server-1',
  connectionName: 'Test server',
  command: 'uptime',
  reason: 'test',
);

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Timed out waiting for approval queue update.');
}

class _FakeSettings extends ChangeNotifier implements McpSettingsPort {
  _FakeSettings({McpServerSettings? value, this.loadError, this.tokenError})
    : _value = value ?? const McpServerSettings();

  McpServerSettings _value;
  final Object? loadError;
  final Object? tokenError;

  @override
  McpServerSettings get mcpSettings => _value;

  @override
  bool get isEnglish => false;

  @override
  Future<void> ensureCoreLoaded() async {
    if (loadError != null) throw loadError!;
  }

  @override
  Future<String> ensureMcpServerToken() async {
    if (tokenError != null) throw tokenError!;
    if (_value.hasToken) return _value.token;
    _value = _value.copyWith(token: 'test-token');
    notifyListeners();
    return _value.token;
  }

  @override
  Future<void> setMcpServerEnabled(bool value) async {
    _update(_value.copyWith(enabled: value));
  }

  @override
  Future<void> setMcpServerPort(int port) async {
    _update(_value.copyWith(port: port));
  }

  @override
  Future<void> setMcpApprovalMode(McpApprovalMode mode) async {
    _update(_value.copyWith(approvalMode: mode));
  }

  @override
  Future<void> setMcpToolExposure(
    String toolName,
    bool exposed, {
    required Set<String> availableToolNames,
  }) async {
    final tools = {..._value.exposedTools};
    if (exposed) {
      tools.add(toolName);
    } else {
      tools.remove(toolName);
    }
    _update(
      _value.copyWith(exposedTools: tools, exposureToolsConfigured: true),
    );
  }

  @override
  Future<void> setMcpToolSecondaryReview(String toolName, bool enabled) async {
    final tools = {..._value.secondaryReviewTools};
    if (enabled) {
      tools.add(toolName);
    } else {
      tools.remove(toolName);
    }
    _update(_value.copyWith(secondaryReviewTools: tools));
  }

  @override
  Future<void> setMcpSecondaryReviewTools(Set<String> tools) async {
    _update(_value.copyWith(secondaryReviewTools: tools));
  }

  @override
  Future<String> regenerateMcpServerToken() async {
    _update(_value.copyWith(token: 'regenerated-token'));
    return _value.token;
  }

  void _update(McpServerSettings value) {
    _value = value;
    notifyListeners();
  }
}

class _MemoryActivityRepository implements McpActivityRepository {
  final records = <McpActivityRecord>[];

  @override
  Future<List<McpActivityRecord>> loadMcpActivityRecords({int limit = 500}) {
    return Future.value(records.reversed.take(limit).toList(growable: false));
  }

  @override
  Future<void> recordMcpActivity(McpActivityRecord record) async {
    records.add(record);
  }

  @override
  Future<void> clearMcpActivityRecords() async {
    records.clear();
  }
}

class _FakeLogger implements McpLoggerPort {
  const _FakeLogger();

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

class _RecordingLogger implements McpLoggerPort {
  final entries = <String>[];

  @override
  void info(String message, {String? details}) {
    entries.add('$message|$details');
  }

  @override
  void warning(String message, {String? details}) {
    entries.add('$message|$details');
  }

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {
    entries.add('$message|$error|$stackTrace|$details');
  }
}

class _FakePortReservation implements McpPortReservation {
  @override
  Future<void> close() async {}
}

class _FakeHttpServerHandle implements McpHttpServerHandle {
  _FakeHttpServerHandle({this.closeGate});

  final Completer<void>? closeGate;
  var closed = false;

  @override
  Future<void> close({bool force = true}) async {
    closed = true;
    await closeGate?.future;
  }
}

class _FakeSelfTestTransport implements McpSelfTestTransport {
  _FakeSelfTestTransport(this._responses);

  final List<McpSelfTestResponse> _responses;
  var requests = 0;

  @override
  Future<McpSelfTestResponse> postJson({
    required Uri url,
    required String token,
    required Map<String, dynamic> body,
  }) async {
    requests++;
    if (_responses.isEmpty) {
      return const McpSelfTestResponse(
        reachable: false,
        statusCode: null,
        succeeded: false,
      );
    }
    return _responses.removeAt(0);
  }
}

class _FakeToolExecutor implements McpToolExecutor {
  final executedTools = <String>[];

  @override
  Future<List<McpTool>> tools() async => const [
    McpTool(
      name: 'list_servers',
      description: 'List saved servers.',
      properties: {},
    ),
  ];

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async {
    const adapter = McpAiToolAdapter();
    return (await tools()).map(adapter.toMcpTool).toList();
  }

  @override
  Future<McpApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async => null;

  @override
  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async {
    executedTools.add(name);
    return jsonEncode({'servers': []});
  }
}
