// AppRuntime developer diagnostics coverage.
//
// The diagnostics snapshot reads the App Scope database descriptor closures
// installed by _prepareTelemetryResources(), including the module-owned
// database open checks that are only reachable through the public snapshot.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'developer diagnostics snapshot reads every App Scope database descriptor',
    () async {
      final harness = await newRuntimeHarness(disposeLogger: false);
      try {
        final runtime = await harness.createFuture;

        final snapshot = runtime.developerDiagnosticsPort.snapshot;

        expect(snapshot.modules, isNotEmpty);
        expect(
          snapshot.databases.map((database) => database.databaseName),
          containsAll(<String>[
            'connection.sqlite',
            'app_logs',
            'ai.db',
            'playbook.db',
            'rag.db',
            'mcp.db',
            'lan_share.db',
            'telemetry',
          ]),
        );
        // Opening the snapshot must evaluate every isOpen closure without
        // throwing and keep the descriptors alive for later reads.
        final secondSnapshot = runtime.developerDiagnosticsPort.snapshot;
        expect(secondSnapshot.databases, hasLength(8));
        expect(secondSnapshot.telemetry, isNotNull);

        await runtime.dispose();
      } finally {
        await harness.close();
      }
    },
  );
}
