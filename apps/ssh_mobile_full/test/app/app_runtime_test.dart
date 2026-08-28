import 'package:app_core/app_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:ssh_mobile/app/app_runtime.dart';
import 'package:ssh_mobile/app/terminal_ssh_capability_adapter.dart';
import 'package:ssh_mobile/services/telemetry/app_crash_telemetry_bridge.dart';

import 'support/app_runtime_test_support.dart';

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
      final network = FakeNetworkRuntime();
      final harness = await newRuntimeHarness(
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
    'telemetry disposal still runs when its flush cannot read storage',
    () async {
      final events = <String>[];
      final harness = await newRuntimeHarness(
        disposeLogger: false,
        lifecycleObserver: events.add,
      );
      try {
        final runtime = await harness.createFuture;
        final telemetryStorage = runtime.telemetryClient!.storage;
        // Close the owned store early to force the flush read to fail while
        // leaving the Runtime's normal disposal path under test.
        await telemetryStorage.close();

        await expectLater(runtime.dispose(), completes);

        expect(events, contains('telemetry.flush.start'));
        expect(events, contains('telemetry.flush.end'));
        expect(events, contains('telemetry.dispose.start'));
        expect(events, contains('telemetry.dispose.end'));
      } finally {
        await harness.close();
      }
    },
  );

  test('late zone errors after Runtime disposal are ignored', () async {
    late AppRuntime runtime;
    Future<void>? lateReport;
    Future<List<TelemetryEventRecord>>? storageSnapshot;
    final events = <String>[];
    final harness = await newRuntimeHarness(
      disposeLogger: false,
      lifecycleObserver: (event) {
        events.add(event);
        if (event == 'crash-telemetry-bridge.dispose.start') {
          lateReport = reportUncaughtErrorToRuntime(
            runtime,
            error: StateError('late zone error'),
            stackTrace: StackTrace.current,
          );
        }
        if (event == 'telemetry.dispose.start') {
          storageSnapshot = runtime.telemetryClient!.storage
              .fetchAllForReplay();
        }
      },
    );
    try {
      runtime = await harness.createFuture;
      await runtime.dispose();
      await lateReport;

      final records = await storageSnapshot;
      expect(
        records!.where(
          (record) => record.eventName == TelemetryEvents.appErrorCaptured.name,
        ),
        isEmpty,
      );
    } finally {
      await harness.close();
    }
  });
}
