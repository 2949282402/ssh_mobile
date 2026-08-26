import 'dart:async';

import 'package:feature_lan_share/src/domain/lan_share_ports.dart';
import 'package:feature_lan_share/src/features/lan_share/views/network_incoming_transfer_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:provider/provider.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildDialogHost({
    required Widget dialog,
    required FakeLanShareSettings settings,
    required LanShareLoggerPort logger,
  }) {
    return MultiProvider(
      providers: [
        ListenableProvider<AppSettings>.value(value: settings),
        Provider<LanShareLoggerPort>.value(value: logger),
      ],
      child: MaterialApp(home: Scaffold(body: dialog)),
    );
  }

  testWidgets(
    'IncomingApprovalDialog: retryable failure keeps dialog open, shows error, and allows Retry',
    (tester) async {
      final settings = FakeLanShareSettings();
      final logger = FakeLanShareLogger();
      int acceptCalls = 0;
      NetworkResult<void> nextResult = const NetworkFailure<void>(
        NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'Socket write failed',
          operation: NetworkOperation.respondToIncoming,
        ),
      );

      final request = IncomingApprovalRequest(
        sessionId: 'tx-1',
        senderId: 'peer-test',
        fileName: 'test.pdf',
        totalBytes: 1024,
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
        accept: () async {
          acceptCalls++;
          return nextResult;
        },
        reject: () async => const NetworkSuccess<void>(null),
      );

      await tester.pumpWidget(
        buildDialogHost(
          dialog: IncomingApprovalDialog(request: request),
          settings: settings,
          logger: logger,
        ),
      );

      // Initial state: shows Accept and Reject buttons
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Reject'), findsOneWidget);
      expect(find.text('Socket write failed'), findsNothing);

      // Tap Accept -> fails with retryable error
      await tester.tap(find.text('Accept'));
      await tester.pump();

      expect(acceptCalls, 1);
      // Dialog remains open, error message is shown, button changed to Retry
      expect(find.text('Socket write failed'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      // Setup success for second attempt
      nextResult = const NetworkSuccess<void>(null);

      // Tap Retry -> succeeds
      await tester.tap(find.text('Retry'));
      await tester.pump();

      expect(acceptCalls, 2);
    },
  );

  testWidgets(
    'IncomingApprovalDialog: non-retryable failure triggers failure SnackBar',
    (tester) async {
      final settings = FakeLanShareSettings();
      final logger = FakeLanShareLogger();
      int acceptCalls = 0;

      final request = IncomingApprovalRequest(
        sessionId: 'tx-2',
        senderId: 'peer-test',
        fileName: 'huge.iso',
        totalBytes: 1024 * 1024 * 1024,
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
        accept: () async {
          acceptCalls++;
          return const NetworkFailure<void>(
            NetworkError(
              code: NetworkErrorCode.resourceLimit,
              message: 'Insufficient storage space',
              operation: NetworkOperation.respondToIncoming,
            ),
          );
        },
        reject: () async => const NetworkSuccess<void>(null),
      );

      await tester.pumpWidget(
        buildDialogHost(
          dialog: IncomingApprovalDialog(request: request),
          settings: settings,
          logger: logger,
        ),
      );

      expect(find.text('Accept'), findsOneWidget);

      // Tap Accept -> fails non-retryable
      await tester.tap(find.text('Accept'));
      await tester.pump();

      expect(acceptCalls, 1);
      // SnackBar shown with resourceLimit message
      expect(find.byType(SnackBar), findsOneWidget);
      expect(
        find.text('Insufficient storage space for incoming transfer.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'IncomingApprovalDialog: double click is disabled while submitting',
    (tester) async {
      final settings = FakeLanShareSettings();
      final logger = FakeLanShareLogger();
      int acceptCalls = 0;
      final completer = Completer<NetworkResult<void>>();

      final request = IncomingApprovalRequest(
        sessionId: 'tx-3',
        senderId: 'peer-test',
        fileName: 'test.bin',
        totalBytes: 100,
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
        accept: () async {
          acceptCalls++;
          return completer.future;
        },
        reject: () async => const NetworkSuccess<void>(null),
      );

      await tester.pumpWidget(
        buildDialogHost(
          dialog: IncomingApprovalDialog(request: request),
          settings: settings,
          logger: logger,
        ),
      );

      // First tap starts accept
      await tester.tap(find.text('Accept'));
      await tester.pump();
      expect(acceptCalls, 1);

      // In-flight: progress indicator is visible and buttons are disabled
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Completing the future finishes the accept
      completer.complete(const NetworkSuccess<void>(null));
      await tester.pump();
      expect(acceptCalls, 1);
    },
  );
}
