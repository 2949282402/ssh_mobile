import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/telemetry/network_telemetry_connectivity.dart';

void main() {
  test(
    'maps platform connectivity results into a distinct bool stream',
    () async {
      final changes = StreamController<List<ConnectivityResult>>.broadcast();
      final previousPlatform = ConnectivityPlatform.instance;
      ConnectivityPlatform.instance = _FakeConnectivityPlatform(
        current: const [ConnectivityResult.none],
        changes: changes.stream,
      );

      try {
        final source = PlatformTelemetryConnectivitySource();
        expect(await source.readConnectivity(), isFalse);
        final values = source.changes.take(2).toList();
        changes.add(const [ConnectivityResult.wifi]);
        changes.add(const [ConnectivityResult.ethernet]);
        changes.add(const [ConnectivityResult.none]);
        expect(await values, [true, false]);
      } finally {
        ConnectivityPlatform.instance = previousPlatform;
        await changes.close();
      }
    },
  );

  test('flushes durable backlog on an offline-to-online transition', () async {
    final source = _FakeConnectivitySource(initiallyConnected: false);
    final transport = _ConnectivityTransport();
    final client = _client(transport);
    final monitor = TelemetryConnectivityMonitor(
      client: client,
      source: source,
    );

    await client.record(event: TelemetryEvents.sshSessionStarted);
    await monitor.start();
    await monitor.start();

    source.emit(false);
    source.emit(true);
    await Future<void>.delayed(Duration.zero);

    expect(transport.uploadCalls, 1);
    expect(await client.storage.fetchPendingBatch(10), isEmpty);

    await monitor.dispose();
    await client.dispose();
    await source.dispose();
  });

  test(
    'does not duplicate uploads for repeated online notifications',
    () async {
      final source = _FakeConnectivitySource(initiallyConnected: true);
      final transport = _ConnectivityTransport();
      final client = _client(transport);
      final monitor = TelemetryConnectivityMonitor(
        client: client,
        source: source,
      );

      await monitor.start();
      source.emit(true);
      source.emit(true);
      await Future<void>.delayed(Duration.zero);

      expect(transport.uploadCalls, 0);
      source.emitError(StateError('platform event unavailable'));
      await Future<void>.delayed(Duration.zero);
      await monitor.dispose();
      await monitor.dispose();
      await monitor.start();
      await client.dispose();
      await source.dispose();
    },
  );

  test('flushes a backlog when the process starts online', () async {
    final source = _FakeConnectivitySource(initiallyConnected: true);
    final transport = _ConnectivityTransport();
    final client = _client(transport);
    final monitor = TelemetryConnectivityMonitor(
      client: client,
      source: source,
    );

    await client.record(event: TelemetryEvents.sshSessionStarted);
    await monitor.start();
    await Future<void>.delayed(Duration.zero);

    expect(transport.uploadCalls, 1);
    expect(await client.storage.fetchPendingBatch(10), isEmpty);
    await monitor.dispose();
    await client.dispose();
    await source.dispose();
  });

  test('treats an unavailable initial query as offline for recovery', () async {
    final source = _FakeConnectivitySource(
      initiallyConnected: false,
      failRead: true,
    );
    final transport = _ConnectivityTransport();
    final client = _client(transport);
    final monitor = TelemetryConnectivityMonitor(
      client: client,
      source: source,
    );

    await client.record(event: TelemetryEvents.sshSessionStarted);
    await monitor.start();
    source.emit(true);
    await Future<void>.delayed(Duration.zero);

    expect(transport.uploadCalls, 1);
    await monitor.dispose();
    await client.dispose();
    await source.dispose();
  });
}

TelemetryClient _client(_ConnectivityTransport transport) {
  return TelemetryClient(
    config: const TelemetryClientConfig(
      baseUrl: 'https://telemetry.example.test',
      deviceId: 'connectivity-device',
      appVersion: '1.0.0',
      buildNumber: '1',
      platform: 'android',
      releaseChannel: 'test',
      telemetryEnabled: true,
      deviceEnrollmentSecret: 'test-secret',
      policyFetchIntervalSeconds: 0,
    ),
    storage: MemoryTelemetryStorage(),
    transport: transport,
    initialPolicy: const TelemetryUploadPolicy(
      uploadEnabled: true,
      batchSizeThreshold: 100,
      timeIntervalSeconds: 60,
      maxBatchSize: 10,
      clientMaxLocalRecords: 100,
      specialTriggers: ['networkRecovered'],
      policyVersion: 1,
    ),
  );
}

final class _FakeConnectivitySource implements TelemetryConnectivitySource {
  _FakeConnectivitySource({
    required bool initiallyConnected,
    this.failRead = false,
  }) : _connected = initiallyConnected;

  final StreamController<bool> _changes = StreamController<bool>.broadcast();
  final bool failRead;
  bool _connected;

  @override
  Future<bool> readConnectivity() async {
    if (failRead) throw StateError('connectivity read unavailable');
    return _connected;
  }

  @override
  Stream<bool> get changes => _changes.stream;

  void emit(bool connected) {
    _connected = connected;
    _changes.add(connected);
  }

  void emitError(Object error) => _changes.addError(error);

  Future<void> dispose() => _changes.close();
}

final class _FakeConnectivityPlatform extends ConnectivityPlatform {
  _FakeConnectivityPlatform({required this.current, required this.changes});

  final List<ConnectivityResult> current;
  final Stream<List<ConnectivityResult>> changes;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => current;

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => changes;
}

final class _ConnectivityTransport implements TelemetryTransport {
  int uploadCalls = 0;

  @override
  Future<TelemetryAuthResult?> authenticateDevice({
    required String baseUrl,
    required String deviceId,
    required String platform,
    required String appVersion,
    String? authSecret,
    int? expEpoch,
  }) async => const TelemetryAuthResult(token: 'token', expiresInSeconds: 3600);

  @override
  Future<TelemetryEnrollmentResult?> enrollDevice({
    required String baseUrl,
    required String deviceId,
    required TelemetryDeviceEnrollmentRequest request,
  }) async => null;

  @override
  Future<TelemetryEnrollmentResult?> rotateDevice({
    required String baseUrl,
    required String deviceId,
    required TelemetryDeviceEnrollmentRequest request,
  }) async => null;

  @override
  Future<TelemetryUploadPolicy?> fetchRemotePolicy({
    required String baseUrl,
    required String authToken,
  }) async => null;

  @override
  Future<TelemetryBatchUploadResult> uploadBatch({
    required String baseUrl,
    required String authToken,
    required String deviceId,
    required List<TelemetryEventRecord> records,
  }) async {
    uploadCalls++;
    return TelemetryBatchUploadResult(
      ackResults: [
        for (final record in records)
          TelemetryAckResult(eventId: record.eventId, status: 'accepted'),
      ],
    );
  }
}
