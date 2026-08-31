// App Scope 遥测客户端的装配入口。
//
// 生产路径构造 DriftTelemetryStorage + 真实 BuildMetadataProvider + 安全存储
// 中的设备注册密钥。绝不使用内存或 JSONL 存储。

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:app_core/app_core.dart';
import 'package:cryptography/cryptography.dart';
import 'package:feature_lan_share/feature_lan_share.dart' as lan;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:network_sdk/network_sdk.dart' as sdk;

import 'build_metadata_provider.dart';
import 'drift_telemetry_storage.dart';

/// 设备注册密钥的安全存储键。
const String telemetryDeviceSecretKey = 'telemetry_device_secret';

/// App-owned proof provider for the public telemetry enrollment endpoint.
///
/// RelayEnrollmentService remains the owner of the Relay credential and its
/// Ed25519 signing seed. This adapter only borrows a short-lived configuration
/// snapshot, signs the operation transcript, and stores the one-time telemetry
/// secret in secure storage. It never exposes or logs either credential.
final class RelayTelemetryEnrollmentProvider
    implements
        TelemetryDeviceEnrollmentProvider,
        TelemetryDeviceEnrollmentPathProvider {
  RelayTelemetryEnrollmentProvider({
    required this._relayEnrollment,
    this.expectedDeviceId,
    this.allowLoopbackHttp = false,
    FlutterSecureStorage? secureStorage,
  }) : _secureStorage =
           secureStorage ??
           const FlutterSecureStorage(
             mOptions: MacOsOptions(usesDataProtectionKeychain: false),
           );

  final lan.LanRelayEnrollmentPort _relayEnrollment;
  final String? expectedDeviceId;
  final bool allowLoopbackHttp;
  final FlutterSecureStorage _secureStorage;

  @override
  Future<TelemetryDeviceEnrollmentRequest?> createRequest({
    required String baseUrl,
    required String deviceId,
  }) => createRequestForPath(
    baseUrl: baseUrl,
    deviceId: deviceId,
    transcriptPath: TelemetryEndpoints.publicEnrollPath,
  );

  @override
  Future<TelemetryDeviceEnrollmentRequest?> createRequestForPath({
    required String baseUrl,
    required String deviceId,
    required String transcriptPath,
  }) async {
    if ((expectedDeviceId != null && expectedDeviceId != deviceId) ||
        deviceId.isEmpty ||
        (transcriptPath != TelemetryEndpoints.publicEnrollPath &&
            transcriptPath != TelemetryEndpoints.publicRotatePath)) {
      return null;
    }

    final endpoint = TelemetryEndpoints.validateOrigin(
      baseUrl,
      allowLoopbackHttp: allowLoopbackHttp,
    );
    if (endpoint == null) return null;

    try {
      var native = await _relayEnrollment.nativeConfiguration(
        lan.RelaySettings(endpoint: endpoint),
      );
      if (native == null) {
        // A locally retained but expired Relay credential may still be
        // refreshed with the same Ed25519 identity. A missing local record is
        // not guessed or silently enrolled and therefore fails closed.
        final hasStored = await _relayEnrollment.hasStoredCredential(
          lan.RelaySettings(endpoint: endpoint),
        );
        if (!hasStored) return null;
        final refreshed = await _relayEnrollment.refreshCredential(
          lan.RelaySettings(endpoint: endpoint),
        );
        if (refreshed is sdk.SdkFailure<void>) return null;
        native = await _relayEnrollment.nativeConfiguration(
          lan.RelaySettings(endpoint: endpoint),
        );
      }
      if (native == null ||
          native.endpoint != endpoint ||
          native.credential.isEmpty ||
          native.signingSeed.length != 32) {
        return null;
      }

      final signing = Ed25519();
      final keyPair = await signing.newKeyPairFromSeed(native.signingSeed);
      final publicKey = await keyPair.extractPublicKey();
      if (publicKey.bytes.length != 32) return null;

      final timestamp =
          DateTime.now().toUtc().millisecondsSinceEpoch ~/
          Duration.millisecondsPerSecond;
      final nonce = _newNonce();
      final transcript = 'POST\n$transcriptPath\n$timestamp\n$nonce';
      final signature = await signing.sign(
        utf8.encode(transcript),
        keyPair: keyPair,
      );

      return TelemetryDeviceEnrollmentRequest(
        deviceId: deviceId,
        relayCredential: native.credential,
        publicKey: base64UrlEncode(publicKey.bytes).replaceAll('=', ''),
        timestamp: timestamp,
        nonce: nonce,
        signature: base64UrlEncode(signature.bytes).replaceAll('=', ''),
        transcriptPath: transcriptPath,
      );
    } on Object {
      // Credential/signing/storage failures are intentionally indistinguishable
      // to the caller; no platform exception may become telemetry diagnostics.
      return null;
    }
  }

  @override
  Future<void> persistSecret(String secret) async {
    if (!_telemetrySecretPattern.hasMatch(secret)) {
      // Never put a credential in ArgumentError's value field: its toString()
      // is observable by callers and may reach diagnostics.
      throw ArgumentError('Invalid telemetry secret.');
    }
    await _secureStorage.write(key: telemetryDeviceSecretKey, value: secret);
  }

  /// Removes the telemetry secret when the Relay enrollment gate closes.
  ///
  /// The secret is scoped to the Relay attestation. Retaining it after a user
  /// clears or loses enrollment could bind a later endpoint to stale identity
  /// material, so the App Shell explicitly clears it on disable.
  Future<void> clearPersistedSecret() =>
      _secureStorage.delete(key: telemetryDeviceSecretKey);

  String _newNonce() {
    final random = Random.secure();
    final bytes = Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

final RegExp _telemetrySecretPattern = RegExp(r'^[0-9a-fA-F]{64}$');

/// 遥测客户端装配结果。
class TelemetryRuntime {
  const TelemetryRuntime({required this.client, required this.storage});

  final TelemetryClient client;
  final DriftTelemetryStorage storage;
}

/// 从 App Settings 的 deviceId/relayEndpoint 装配遥测客户端。
Future<TelemetryRuntime> createTelemetryRuntime({
  required String deviceId,
  required String relayEndpoint,
  required AppBuildMetadata buildMetadata,
  FlutterSecureStorage? secureStorage,
  TelemetryDeviceEnrollmentProvider? deviceEnrollmentProvider,
  DriftTelemetryStorage? storage,
  TelemetryUploadPolicy? initialPolicy,
  bool disableBackgroundPolicyFetch = false,
  bool telemetryEnabled = false,
}) async {
  final secure =
      secureStorage ??
      const FlutterSecureStorage(
        mOptions: MacOsOptions(usesDataProtectionKeychain: false),
      );

  // 只读取已通过 App Shell Relay enrollment gate 的设备密钥；未注册时
  // 客户端保持关闭，不会因为空密钥而走匿名遥测路径。
  String? enrollmentSecret;
  var secureStorageReadFailed = false;
  if (telemetryEnabled) {
    try {
      enrollmentSecret = await secure.read(key: telemetryDeviceSecretKey);
    } catch (_) {
      secureStorageReadFailed = true;
      enrollmentSecret = null;
    }
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
      telemetryEnabled: telemetryEnabled,
      // A secure-storage read failure is an unavailable state, not an empty
      // credential. Never fall back to Relay enrollment/rotation because that
      // would create a new secret while the existing one is inaccessible.
      deviceEnrollmentProvider: secureStorageReadFailed
          ? null
          : deviceEnrollmentProvider,
      policyFetchIntervalSeconds: disableBackgroundPolicyFetch ? 0 : 3600,
    ),
    storage: driftStorage,
    initialPolicy: initialPolicy,
  );
  await client.ready;

  return TelemetryRuntime(client: client, storage: driftStorage);
}
