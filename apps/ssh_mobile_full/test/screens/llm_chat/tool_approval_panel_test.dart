import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/ai_chat/viewmodels/ai_chat_viewmodel.dart';
import 'package:ssh_mobile/features/ai_chat/views/llm_chat_screen.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  testWidgets(
    'compact approval panel scrolls complete risk details with fixed actions',
    (tester) async {
      var approved = false;
      var rejected = false;
      const longReason =
          'The requested operation removes a production configuration file '
          'and may stop the service. Review the target, command, and preview '
          'before deciding whether this action should continue.';
      final pending = PendingToolApproval(
        chatId: 'chat-1',
        request: const AiToolApprovalRequest(
          toolName: 'delete_remote_file',
          approvalType: 'remote_delete',
          connectionId: 'server-1',
          connectionName: 'production-server-with-a-long-name',
          command:
              'rm --force /srv/application/config/production-settings.json',
          reason: longReason,
          targetPath:
              '/srv/application/config/production-settings.json.backup.long',
          byteLength: 4096,
          contentPreview:
              '{"service":"critical","environment":"production","enabled":true}',
          destructive: true,
        ),
        completer: Completer<AiToolApprovalDecision>(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 411,
                height: 240,
                child: ToolApprovalPanel(
                  pending: pending,
                  strings: const AiStrings(AppLanguage.en),
                  onApprove: () => approved = true,
                  onReject: () => rejected = true,
                ),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      final description = tester.widget<Text>(
        find.byKey(const ValueKey<String>('tool-approval-description')),
      );
      expect(description.data, contains(longReason));
      expect(description.maxLines, isNull);

      final rejectFinder = find.byKey(
        const ValueKey<String>('tool-approval-reject'),
      );
      final approveFinder = find.byKey(
        const ValueKey<String>('tool-approval-approve'),
      );
      expect(tester.getSize(rejectFinder).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(approveFinder).height, greaterThanOrEqualTo(48));
      final approveRectBefore = tester.getRect(approveFinder);

      await tester.drag(
        find.byKey(const ValueKey<String>('tool-approval-details')),
        const Offset(0, -180),
      );
      await tester.pumpAndSettle();

      expect(tester.getRect(approveFinder), approveRectBefore);
      expect(find.text('Preview'), findsOneWidget);
      await tester.tap(rejectFinder);
      await tester.tap(approveFinder);
      expect(rejected, isTrue);
      expect(approved, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
