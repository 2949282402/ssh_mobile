import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connection_core/connection_core.dart';
import 'package:drift/native.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/app/app_runtime_factory.dart';
import 'package:ssh_mobile/app/terminal_ssh_capability_adapter.dart';

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
      SharedPreferences.setMockInitialValues({});

      final connectionDatabase = ConnectionDatabase.forTesting(
        NativeDatabase.memory(),
      );
      final connectionRepository = DriftConnectionRepository(
        database: connectionDatabase,
      );
      final runtime = await AppRuntimeFactory.create(
        connectionDatabase: connectionDatabase,
        connectionRepository: connectionRepository,
        credentialRepository: SecureCredentialRepository(),
        hostKeyRepository: connectionRepository,
      );

      expect(runtime.isDisposed, isFalse);
      expect(runtime.appLogService, isNotNull);
      expect(runtime.logger, same(runtime.appLogService));
      expect(runtime.storageService, isNotNull);
      expect(runtime.connectionDatabase, isNotNull);
      expect(runtime.connectionRepository, isNotNull);
      expect(runtime.credentialRepository, isNotNull);
      expect(runtime.hostKeyRepository, same(runtime.connectionRepository));
      expect(runtime.networkRuntime, isNotNull);
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

      final firstDispose = runtime.dispose();
      final secondDispose = runtime.dispose();

      expect(identical(firstDispose, secondDispose), isTrue);
      await firstDispose;
      expect(runtime.isDisposed, isTrue);
    },
  );
}
