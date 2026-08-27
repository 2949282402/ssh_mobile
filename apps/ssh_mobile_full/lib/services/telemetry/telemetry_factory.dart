// App Scope 遥测客户端的装配入口。
//
// 生产路径构造 DriftTelemetryStorage + 真实 BuildMetadataProvider + 安全存储
// 中的设备注册密钥。绝不使用内存或 JSONL 存储。

import 'package:app_core/app_core.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'build_metadata_provider.dart';
import 'drift_telemetry_storage.dart';

/// 设备注册密钥的安全存储键。
const String telemetryDeviceSecretKey = 'telemetry_device_secret';

/// 遥测客户端装配结果。
class TelemetryRuntime {
  const TelemetryRuntime({
    required this.client,
    required this.storage,
  });

  final TelemetryClient client;
  final DriftTelemetryStorage storage;
}

/// 从 App Settings 的 deviceId/relayEndpoint 装配遥测客户端。
Future<TelemetryRuntime> createTelemetryRuntime({
  required String deviceId,
  required String relayEndpoint,
  required AppBuildMetadata buildMetadata,
  FlutterSecureStorage? secureStorage,
  DriftTelemetryStorage? storage,
  TelemetryUploadPolicy? initialPolicy,
  bool disableBackgroundPolicyFetch = false,
}) async {
  final secure = secureStorage ?? const FlutterSecureStorage();

  // 读取设备注册密钥；测试或未配置时允许为空（匿名认证）。
  String? enrollmentSecret;
  try {
    enrollmentSecret = await secure.read(key: telemetryDeviceSecretKey);
  } catch (_) {
    enrollmentSecret = null;
  }

  final driftStorage = storage ?? DriftTelemetryStorage();
  final client = TelemetryClient(
    config: TelemetryClientConfig(
      baseUrl: relayEndpoint,
      deviceId: deviceId,
      appVersion: buildMetadata.appVersion,
      buildNumber: buildMetadata.buildNumber,
      platform: buildMetadata.platform,
      releaseChannel: buildMetadata.releaseChannel,
      deviceEnrollmentSecret: enrollmentSecret,
      policyFetchIntervalSeconds: disableBackgroundPolicyFetch ? 0 : 3600,
    ),
    storage: driftStorage,
    initialPolicy: initialPolicy,
  );

  return TelemetryRuntime(client: client, storage: driftStorage);
}