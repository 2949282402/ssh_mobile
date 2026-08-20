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
}

McpServerController _createController(
  McpSettingsPort settings,
  McpToolExecutor Function() factory, {
  McpApprovalQueue? approvalQueue,
  McpPortProbe? portProbe,
  McpHttpServerFactory? serverFactory,
  McpSelfTestTransport? selfTestTransport,
}) {
  return McpServerController(
    settings: settings,
    toolServiceFactory: factory,
    activityRepository: _MemoryActivityRepository(),
    logger: const _FakeLogger(),
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
  _FakeSettings({McpServerSettings? value})
    : _value = value ?? const McpServerSettings();

  McpServerSettings _value;

  @override
  McpServerSettings get mcpSettings => _value;

  @override
  bool get isEnglish => false;

  @override
  Future<void> ensureCoreLoaded() async {}

  @override
  Future<String> ensureMcpServerToken() async {
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

class _FakePortReservation implements McpPortReservation {
  @override
  Future<void> close() async {}
}

class _FakeHttpServerHandle implements McpHttpServerHandle {
  var closed = false;

  @override
  Future<void> close({bool force = true}) async {
    closed = true;
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
