import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/features/mcp_console/viewmodels/mcp_console_viewmodel.dart';
import 'package:ssh_mobile/features/mcp_console/views/mcp_approval_queue_screen.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/mcp/mcp_approval_queue.dart';
import 'package:ssh_mobile/services/mcp/mcp_server_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppSettings appSettings;
  late McpServerController controller;
  late McpConsoleViewModel viewModel;
  late McpApprovalQueue queue;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    appSettings = AppSettings();
    await appSettings.init();
    controller = McpServerController(
      appSettings: appSettings,
      toolServiceFactory: _FakeToolExecutor.new,
    );
    viewModel = McpConsoleViewModel(controller, appSettings);
    queue = controller.approvalQueue;
  });

  tearDown(() {
    viewModel.dispose();
    controller.dispose();
    appSettings.dispose();
  });

  Widget buildSubject() {
    return ChangeNotifierProvider.value(
      value: viewModel,
      child: const MaterialApp(home: McpApprovalQueueScreen()),
    );
  }

  AiToolApprovalRequest request() {
    return const AiToolApprovalRequest(
      toolName: 'run_command',
      approvalType: 'remote_write',
      connectionId: 'server-1',
      connectionName: 'Test server',
      command: 'uptime',
      reason: 'test approval',
    );
  }

  testWidgets('shows the empty state when no approvals are pending', (
    tester,
  ) async {
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.verified_user_outlined), findsOneWidget);
  });

  testWidgets('approve executes the approved closure and removes the card', (
    tester,
  ) async {
    var executed = false;
    final pending = queue.enqueue(
      request: request(),
      executeApproved: () async {
        executed = true;
        return 'ok';
      },
    );
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    expect(find.text('run_command'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.check_rounded));
    await tester.pumpAndSettle();

    expect(executed, isTrue);
    expect(await pending, 'ok');
    expect(find.text('run_command'), findsNothing);
  });

  testWidgets('reject completes the request without executing', (tester) async {
    var executed = false;
    final pending = queue.enqueue(
      request: request(),
      executeApproved: () async {
        executed = true;
        return 'ok';
      },
    );
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    expect(executed, isFalse);
    expect(jsonDecode(await pending)['error'], 'approval_rejected');
    expect(find.text('run_command'), findsNothing);
  });

  testWidgets('a processing request shows the executing state', (tester) async {
    final gate = Completer<String>();
    final pending = queue.enqueue(
      request: request(),
      executeApproved: () async => gate.future,
    );
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.check_rounded));
    await tester.pump();
    await tester.pump();

    // Approve and Reject controls are hidden while the closure is running.
    expect(find.byIcon(Icons.check_rounded), findsNothing);
    expect(find.byIcon(Icons.close_rounded), findsNothing);

    gate.complete('ok');
    expect(await pending, 'ok');
    await tester.pumpAndSettle();
  });
}

class _FakeToolExecutor implements AiToolExecutor {
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
  }) async => jsonEncode({'servers': []});

  @override
  AiCommandReview reviewCommand(String command, {ServerPlatform? platform}) {
    return const AiCommandReview.readOnly();
  }
}
