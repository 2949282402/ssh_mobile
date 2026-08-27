import 'package:feature_developer/feature_developer.dart';
import 'package:feature_developer/src/presentation/developer_telemetry_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class TelemetryFakeDiagnostics extends ChangeNotifier
    implements DeveloperDiagnosticsPort {
  TelemetryFakeDiagnostics({required this.snapshot});

  @override
  final DeveloperDiagnosticsSnapshot snapshot;

  @override
  List<DeveloperComponentStatus> get componentStatuses => const [];

  @override
  Future<DeveloperNativeMemorySnapshot?> readNativeMemory() async => null;

  bool replayCalled = false;
  bool flushCalled = false;
  bool refreshCalled = false;

  @override
  Future<int> replayTelemetry() async {
    replayCalled = true;
    return 42;
  }

  @override
  Future<void> flushTelemetry() async {
    flushCalled = true;
  }

  @override
  Future<bool> refreshTelemetryPolicy() async {
    refreshCalled = true;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('DeveloperTelemetryCard renders metrics and handles replay button', (
    tester,
  ) async {
    final diagnostics = TelemetryFakeDiagnostics(
      snapshot: DeveloperDiagnosticsSnapshot(
        capturedAt: DateTime(2026, 8, 27),
        modules: const [],
        ssh: const DeveloperSshSnapshot(
          activeSessions: 0,
          idleSessions: 0,
          leaseCount: 0,
        ),
        network: const DeveloperNetworkSnapshot(
          activeConnections: 0,
          nativeHandles: 0,
        ),
        databases: const [],
        resources: const DeveloperResourceSnapshot(
          activeTimers: 0,
          activeSubscriptions: 0,
        ),
        telemetry: const DeveloperTelemetrySnapshot(
          localPendingCount: 5,
          localRejectedCount: 2,
          localSyncedCount: 10,
          totalCount: 17,
          cacheOverflow: true,
          uploadEnabled: true,
          policyVersion: 3,
          batchSizeThreshold: 20,
          timeIntervalSeconds: 30,
          isUploading: false,
        ),
      ),
    );
    addTearDown(diagnostics.dispose);

    final vm = DeveloperPanelViewModel(diagnostics: diagnostics);
    addTearDown(vm.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DeveloperTelemetryCard(
            telemetry: diagnostics.snapshot.telemetry,
            vm: vm,
          ),
        ),
      ),
    );
    await tester.pump();

    // Verify metrics rendered
    expect(find.text('Telemetry Diagnostics'), findsOneWidget);
    expect(find.text('Pending Records'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(find.text('Synced Records'), findsOneWidget);
    expect(find.text('10'), findsOneWidget);
    expect(find.text('Rejected Records'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('Total Database Rows'), findsOneWidget);
    expect(find.text('17'), findsOneWidget);

    // Verify Cache Overflow warning banner
    expect(find.textContaining('Cache Overflow: Non-loss invariant active'), findsOneWidget);

    // Test Replay button tap
    final replayBtn = find.text('Replay All Data');
    expect(replayBtn, findsOneWidget);
    await tester.tap(replayBtn);
    await tester.pumpAndSettle();

    expect(diagnostics.replayCalled, isTrue);
    expect(find.text('Replayed 42 records'), findsOneWidget);
  });
}
