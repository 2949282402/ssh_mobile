import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connection_core/connection_core.dart';
import 'package:drift/native.dart';
import 'package:feature_lan_share/feature_lan_share.dart' as feature_lan_share;
import 'package:feature_mcp/feature_mcp.dart' as feature_mcp;
import 'package:feature_playbook/feature_playbook.dart' as feature_playbook;
import 'package:feature_rag/feature_rag.dart' as feature_rag;
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
      final ragCacheDirectory = await Directory.systemTemp.createTemp(
        'app-runtime-rag-',
      );
      final runtime = await AppRuntimeFactory.create(
        connectionDatabase: connectionDatabase,
        connectionRepository: connectionRepository,
        credentialRepository: SecureCredentialRepository(),
        hostKeyRepository: connectionRepository,
        lanShareDatabaseFactory: () =>
            feature_lan_share.LanShareDatabase.forTesting(
              NativeDatabase.memory(),
            ),
        lanShareReceiverEnabled: false,
        playbookDatabaseFactory: () =>
            feature_playbook.PlaybookDatabase.forTesting(
              NativeDatabase.memory(),
            ),
        ragDatabaseFactory: () =>
            feature_rag.RagDatabase.forTesting(NativeDatabase.memory()),
        ragCacheStoreFactory: () => feature_rag.RagCacheStore(
          directoryFactory: () async => ragCacheDirectory,
        ),
        mcpDatabaseFactory: () =>
            feature_mcp.McpDatabase.forTesting(NativeDatabase.memory()),
      );

      expect(runtime.isDisposed, isFalse);
      expect(runtime.appLogService, isNotNull);
      expect(runtime.logger, same(runtime.appLogService));
      expect(runtime.aiStorageAdapter, isNotNull);
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
      expect(runtime.ragModule.service, same(runtime.ragService));

      final firstDispose = runtime.dispose();
      final secondDispose = runtime.dispose();

      expect(identical(firstDispose, secondDispose), isTrue);
      await firstDispose;
      expect(runtime.isDisposed, isTrue);
      await ragCacheDirectory.delete(recursive: true);
    },
  );
}
