import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:feature_mcp/feature_mcp.dart';

import '../../../support/mcp_test_fakes.dart';

void main() {
  late FakeMcpSettingsPort settings;
  late McpServerController controller;
  late McpConsoleViewModel viewModel;
  late McpApprovalQueue queue;

  setUp(() {
    settings = FakeMcpSettingsPort();
    controller = createTestMcpController(settings, FakeMcpToolExecutor.new);
    viewModel = McpConsoleViewModel(controller, settings);
    queue = controller.approvalQueue;
  });

  tearDown(() {
    viewModel.dispose();
    controller.dispose();
    settings.dispose();
  });

  Widget buildSubject() {
    return ChangeNotifierProvider.value(
      value: viewModel,
      child: const MaterialApp(home: McpApprovalQueueScreen()),
    );
  }

  McpApprovalRequest request() {
    return const McpApprovalRequest(
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
