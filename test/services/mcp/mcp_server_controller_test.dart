import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/mcp/mcp_server_controller.dart';
import 'package:ssh_mobile/services/mcp/mcp_approval_queue.dart';
import 'package:ssh_mobile/services/mcp/mcp_server_settings.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({
      'mcp_server_token': 'test-token',
    });
  });

  test(
    'self-test checks initialize and tools/list without executing tools',
    () async {
      final reservation = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = reservation.port;
      await reservation.close();
      SharedPreferences.setMockInitialValues({
        'mcp_server_enabled': true,
        'mcp_server_host': '127.0.0.1',
        'mcp_server_port': port,
        'lan_device_id': 'test-device',
        'lan_device_alias': 'Test device',
      });
      final settings = AppSettings();
      await settings.init();
      final executor = _FakeToolExecutor();
      final controller = McpServerController(
        appSettings: settings,
        toolServiceFactory: () => executor,
      );
      addTearDown(() async {
        await controller.stop();
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
    },
  );

  test('self-test never starts a stopped server', () async {
    SharedPreferences.setMockInitialValues({
      'lan_device_id': 'test-device',
      'lan_device_alias': 'Test device',
    });
    final settings = AppSettings();
    await settings.init();
    final controller = McpServerController(
      appSettings: settings,
      toolServiceFactory: _FakeToolExecutor.new,
    );
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
    SharedPreferences.setMockInitialValues({
      'lan_device_id': 'test-device',
      'lan_device_alias': 'Test device',
    });
    final settings = AppSettings();
    await settings.init();
    final queue = McpApprovalQueue();
    final controller = McpServerController(
      appSettings: settings,
      toolServiceFactory: _FakeToolExecutor.new,
      approvalQueue: queue,
    );
    addTearDown(() {
      controller.dispose();
      settings.dispose();
    });

    var executed = false;
    final pending = queue.enqueue(
      request: const AiToolApprovalRequest(
        toolName: 'run_command',
        approvalType: 'remote_write',
        connectionId: 'server-1',
        connectionName: 'Test server',
        command: 'uptime',
        reason: 'test',
      ),
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
    SharedPreferences.setMockInitialValues({
      'lan_device_id': 'test-device',
      'lan_device_alias': 'Test device',
    });
    final settings = AppSettings();
    await settings.init();
    final queue = McpApprovalQueue();
    final controller = McpServerController(
      appSettings: settings,
      toolServiceFactory: _FakeToolExecutor.new,
      approvalQueue: queue,
    );
    addTearDown(() {
      controller.dispose();
      settings.dispose();
    });

    var executed = false;
    final pending = queue.enqueue(
      request: const AiToolApprovalRequest(
        toolName: 'run_command',
        approvalType: 'remote_write',
        connectionId: 'server-1',
        connectionName: 'Test server',
        command: 'uptime',
        reason: 'test',
      ),
      executeApproved: () async {
        executed = true;
        return 'executed';
      },
    );
    await _waitFor(() => queue.pending.isNotEmpty);

    // regenerateMcpServerToken notifies after the secure-storage write, so wait
    // for it before approving; the controller must reject the stale approval.
    await settings.regenerateMcpServerToken();
    await queue.approve(queue.pending.single.id);

    expect(await pending, contains('approval_rejected'));
    expect(executed, isFalse);
    expect(queue.pending, isEmpty);
  });

  test('exposure changes reject pending external approvals', () async {
    SharedPreferences.setMockInitialValues({
      'lan_device_id': 'test-device',
      'lan_device_alias': 'Test device',
    });
    final settings = AppSettings();
    await settings.init();
    final queue = McpApprovalQueue();
    final controller = McpServerController(
      appSettings: settings,
      toolServiceFactory: _FakeToolExecutor.new,
      approvalQueue: queue,
    );
    addTearDown(() {
      controller.dispose();
      settings.dispose();
    });

    var executed = false;
    final pending = queue.enqueue(
      request: const AiToolApprovalRequest(
        toolName: 'run_command',
        approvalType: 'remote_write',
        connectionId: 'server-1',
        connectionName: 'Test server',
        command: 'uptime',
        reason: 'test',
      ),
      executeApproved: () async {
        executed = true;
        return 'executed';
      },
    );
    await _waitFor(() => queue.pending.isNotEmpty);

    final exposureChange = settings.setMcpExposedTools({'list_servers'});
    await queue.approve(queue.pending.single.id);
    await exposureChange;

    expect(await pending, contains('approval_rejected'));
    expect(executed, isFalse);
    expect(queue.pending, isEmpty);
  });
}

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Timed out waiting for approval queue update.');
}

class _FakeToolExecutor implements AiToolExecutor {
  final executedTools = <String>[];

  @override
  Future<List<AiTool>> tools() async => [
    AiTool(
      name: 'list_servers',
      description: 'List saved servers.',
      properties: const {},
      handler: (_) async => jsonEncode({'servers': []}),
    ),
  ];

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async =>
      (await tools()).map((tool) => tool.definition).toList();

  @override
  Future<AiToolApprovalRequest?> approvalRequestFor(
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

  @override
  AiCommandReview reviewCommand(String command, {ServerPlatform? platform}) {
    return const AiCommandReview.readOnly();
  }
}
