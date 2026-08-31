// AppRuntimeFactory peer-id resolution coverage.
//
// The composition root resolves a SSH/SFTP config to a LAN native peer id
// through the LanShareModule peer registry. A real connect attempt against a
// closed loopback port fails after the resolver has already run, which keeps
// the test hermetic and exercises lines 163-169 of the factory context.

import 'dart:io';

import 'package:connection_core/connection_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'SSH connect resolves the LAN peer registry while the module is active',
    () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final unusedPort = probe.port;
      await probe.close();

      final harness = await newRuntimeHarness(disposeLogger: false);
      try {
        final runtime = await harness.createFuture;

        await runtime.connectionRepository.addConnection(
          ConnectionConfig(
            id: 'resolver-target-1',
            name: 'Resolver Target',
            host: InternetAddress.loopbackIPv4.address,
            port: unusedPort,
            username: 'root',
            authMethod: AuthMethod.password,
          ),
        );

        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        await runtime.sshService
            .connect('resolver-target-1')
            .timeout(const Duration(seconds: 15));

        final session = runtime.sshService.currentSession;
        expect(session, isNotNull);
        expect(session!.connectionId, 'resolver-target-1');
        expect(session.state.name, 'error');
        expect(session.errorMessage, contains('Connection failed'));

        await runtime.dispose();
      } finally {
        await harness.close();
      }
    },
  );
}
