import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/core/services/ssh_host_key_policy.dart';
import 'package:connection_core/connection_core.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:ssh_mobile/services/connection_target_binding.dart';
import 'package:ssh_mobile/services/remote_target_scope.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import '../test_utils/test_storage_adapter.dart';

class _BoundMonitorSshService extends SshService {
  final TestStorageAdapter storage;
  int remoteCallCount = 0;

  _BoundMonitorSshService(this.storage)
    : super(
        connectionRepository: storage.connectionRepository,
        credentialRepository: storage.credentialRepository,
        hostKeyRepository: storage.hostKeyRepository,
        terminalMetadataStore: storage.terminalMetadataStore,
      );

  @override
  Future<RemoteCommandResult> runOneShotCommandForBinding({
    required ConnectionTargetBinding binding,
    required String command,
    Duration timeout = const Duration(seconds: 15),
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    final target = await storage.resolveConnectionTarget(binding);
    if (target == null) {
      throw RemoteTargetScopeException.targetChanged(binding.id);
    }
    remoteCallCount += 1;
    return const RemoteCommandResult(
      exitCode: 1,
      stdout: '',
      stderr: 'probe unavailable in test',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'approved monitor retries never drift to a replacement target',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final storage = TestStorageAdapter();
      await storage.init();
      final connection = ConnectionConfig(
        id: 'monitor-target',
        name: 'Monitor target',
        host: 'old.example.com',
        username: 'ops',
        serverPlatform: ServerPlatform.linux,
      );
      await storage.addConnection(connection);
      final ssh = _BoundMonitorSshService(storage);
      final monitor = createTestPerformanceMonitorService(ssh, storage);
      monitor.toggleSelection(connection.id);
      final binding = ssh_core.SshTargetBinding.fromConfig(connection);

      await monitor.startMonitoring(targetBindings: {connection.id: binding});
      final callsBeforeEdit = ssh.remoteCallCount;
      expect(callsBeforeEdit, greaterThan(0));

      await storage.updateConnection(
        connection.copyWith(host: 'replacement.example.com', port: 2222),
      );
      await monitor.sampleNow();

      expect(ssh.remoteCallCount, callsBeforeEdit);
      expect(monitor.errorsByConnection[connection.id], isNotNull);

      monitor.dispose();
      ssh.dispose();
      storage.dispose();
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
