// SSH 会话生命周期遥测生产者测试。
//
// 覆盖：started -> failed 共享同一 traceId；错误码映射（认证失败 / 超时）；
// disconnectSession 对已登记会话输出 terminated 事件。
// 使用可抛异常的 SshNativeStreamConnector 在桌面本地连接路径上快速触发
// 确定性失败，避免真实 TCP 连接。

import 'package:connection_core/connection_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/telemetry/app_telemetry_contract.dart';

import '../../test_utils/test_storage_adapter.dart';
import 'telemetry_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SSH session telemetry producers', () {
    late TelemetryTestHarness harness;
    late TestStorageAdapter storage;
    late SshService sshService;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      harness = TelemetryTestHarness();
      storage = TestStorageAdapter();
      await _addPasswordConnection(storage, id: 'server-1');

      sshService = createTestSshService(
        storage,
        telemetryClient: harness.client,
        nativeStreamConnector: _ThrowingSshConnector('Authentication failed'),
        peerIdResolver: _enrolledPeerId,
      );
    });

    tearDown(() async {
      await sshService.close();
      await harness.dispose();
      await storage.shutdown();
      storage.dispose();
      debugDefaultTargetPlatformOverride = null;
    });

    test('started and failed share traceId with mapped error code', () async {
      // connect() 失败不向外抛出：失败通过 session state + telemetry 呈现。
      await sshService.connect('server-1');

      final records = await harness.recordsByName();
      final started = records[AppTelemetryEvents.sshSessionStarted.name];
      final failed = records[AppTelemetryEvents.sshSessionFailed.name];

      expect(started, hasLength(1));
      expect(failed, hasLength(1));

      final startedRecord = started!.single;
      final failedRecord = failed!.single;

      expect(startedRecord.traceId, isNotEmpty);
      expect(failedRecord.traceId, startedRecord.traceId);
      expect(failedRecord.sessionId, startedRecord.sessionId);

      expect(
        startedRecord.properties,
        containsPair('auth_method', AuthMethod.password.name),
      );
      expect(startedRecord.properties, containsPair('session_type', 'terminal'));

      expect(failedRecord.properties, containsPair('stage', 'connect'));
      expect(
        failedRecord.error?.errorCode,
        AppTelemetryErrorCodes.sshAuthFailed.code,
      );
      expect(failedRecord.error?.category, 'ssh');
    });

    test('timeout connect maps to SSH_TIMEOUT error code', () async {
      sshService = createTestSshService(
        storage,
        telemetryClient: harness.client,
        nativeStreamConnector: _ThrowingSshConnector('Connection timed out'),
        peerIdResolver: _enrolledPeerId,
      );

      await sshService.connect('server-1');

      final failed = (await harness.recordsByName())[
        AppTelemetryEvents.sshSessionFailed.name
      ];
      expect(failed, hasLength(1));
      expect(
        failed!.single.error?.errorCode,
        AppTelemetryErrorCodes.sshTimeout.code,
      );
    });

    test('disconnect terminates a registered session with duration', () async {
      // 先触发一次连接失败，拿到注册的 sessionId（started 事件属性）。
      await sshService.connect('server-1');
      final started = (await harness.recordsByName())[
        AppTelemetryEvents.sshSessionStarted.name
      ]!.single;
      final sessionId = started.sessionId;

      // 失败路径结束后 session 仍在 registry 中；断开应输出 terminated。
      final existed = sshService.sessions.any((s) => s.id == sessionId);
      expect(existed, isTrue);

      await sshService.disconnectSession(sessionId);

      final terminated = (await harness.recordsByName())[
        AppTelemetryEvents.sshSessionTerminated.name
      ];
      expect(terminated, hasLength(1));
      final terminatedRecord = terminated!.single;
      expect(terminatedRecord.sessionId, sessionId);
      expect(terminatedRecord.properties, containsPair('exit_code', 0));
      expect(terminatedRecord.properties['duration_ms'], isA<int>());
    });
  });
}

Future<void> _addPasswordConnection(
  TestStorageAdapter storage, {
  required String id,
}) async {
  await storage.connectionRepository.addConnection(
    ConnectionConfig(
      id: id,
      name: 'Server',
      host: '127.0.0.1',
      port: 22,
      username: 'tester',
      authMethod: AuthMethod.password,
    ),
  );
  await storage.credentialRepository.saveCredentials(
    connectionId: id,
    password: 'pw',
  );
}

/// 返回固定 peer 标识，强制 SshClientFactory 走 native 连接器路径
/// （连接器与可解析 peer 都存在时才使用 native 传输，否则回退真实 TCP）。
String? _enrolledPeerId(ConnectionConfig config) => 'peer-${config.id}';

final class _ThrowingSshConnector implements ssh_core.SshNativeStreamConnector {
  _ThrowingSshConnector(this.errorMessage);

  final String errorMessage;

  @override
  Future<ssh_core.SshNativeStream> open({
    required String peerId,
    String service = ssh_core.kSshNativeStreamService,
  }) {
    throw StateError(errorMessage);
  }

  @override
  Future<void> closeAll() async {}
}