import 'dart:async';
import 'dart:math';

import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TelemetryClient retry and trigger state machines', () {
    test(
      'keeps periodic flush alive while retrying and after success',
      () async {
        final timers = _FakeTelemetryTimerFactory();
        final transport = _ScriptedTelemetryTransport(
          uploadOutcomes: [
            const TelemetryUploadException(
              'server unavailable',
              statusCode: 503,
            ),
            null,
          ],
        );
        final client = _buildClient(timers, transport);

        await client.record(event: TelemetryEvents.sshSessionStarted);
        await client.flush();

        final periodic = timers.periodicTimers.single;
        final retry = timers.oneShotTimers.single;
        expect(periodic.isActive, isTrue);
        expect(retry.duration.inMilliseconds, inInclusiveRange(800, 1200));

        await retry.fire();

        expect(transport.uploadCalls, 2);
        expect(periodic.isActive, isTrue);
        expect(await client.storage.fetchPendingBatch(10), isEmpty);

        await client.dispose();
      },
    );

    test(
      'coalesces a trigger during an active upload into a follow-up drain',
      () async {
        final timers = _FakeTelemetryTimerFactory();
        final transport = _ScriptedTelemetryTransport(
          firstUploadGate: Completer<void>(),
        );
        final client = _buildClient(timers, transport);

        await client.record(event: TelemetryEvents.sshSessionStarted);
        final first = client.flush();
        await transport.firstUploadStarted.future;

        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: const {'session_type': 'follow-up'},
        );
        final followUp = client.flush();
        expect(identical(first, followUp), isTrue);

        transport.firstUploadGate!.complete();
        await Future.wait([first, followUp]);

        expect(transport.uploadCalls, 2);
        expect(transport.uploadedBatches[0], hasLength(1));
        expect(transport.uploadedBatches[1], hasLength(1));
        expect(await client.storage.fetchPendingBatch(10), isEmpty);

        await client.dispose();
      },
    );

    test(
      'honors a bounded Retry-After delay without real time passing',
      () async {
        final timers = _FakeTelemetryTimerFactory();
        final transport = _ScriptedTelemetryTransport(
          uploadOutcomes: [
            const TelemetryUploadException(
              'rate limited',
              statusCode: 429,
              retryAfterSeconds: 7,
            ),
            null,
          ],
        );
        final client = _buildClient(timers, transport);

        await client.record(event: TelemetryEvents.sshSessionStarted);
        await client.flush();

        final retry = timers.oneShotTimers.single;
        expect(retry.duration, const Duration(seconds: 7));
        expect(transport.uploadCalls, 1);

        await retry.fire();

        expect(transport.uploadCalls, 2);
        expect(await client.storage.fetchPendingBatch(10), isEmpty);

        await client.dispose();
      },
    );

    test(
      'manual success cancels stale retry but retains periodic scheduling',
      () async {
        final timers = _FakeTelemetryTimerFactory();
        final transport = _ScriptedTelemetryTransport(
          uploadOutcomes: [
            const TelemetryUploadException(
              'server unavailable',
              statusCode: 503,
            ),
            null,
          ],
        );
        final client = _buildClient(timers, transport);

        await client.record(event: TelemetryEvents.sshSessionStarted);
        await client.flush();
        final retry = timers.oneShotTimers.single;
        final periodic = timers.periodicTimers.single;

        await client.flush();

        expect(retry.isActive, isFalse);
        expect(periodic.isActive, isTrue);
        expect(transport.uploadCalls, 2);
        expect(await client.storage.fetchPendingBatch(10), isEmpty);

        await client.dispose();
      },
    );

    test(
      'policy refresh has an independent timer from periodic flush/retry',
      () async {
        final timers = _FakeTelemetryTimerFactory();
        final transport = _ScriptedTelemetryTransport(
          uploadOutcomes: [
            const TelemetryUploadException(
              'server unavailable',
              statusCode: 503,
            ),
          ],
          remotePolicy: _policy(intervalSeconds: 20),
        );
        final client = _buildClient(
          timers,
          transport,
          policyFetchIntervalSeconds: 30,
        );

        await client.record(event: TelemetryEvents.sshSessionStarted);
        await client.flush();

        final periodic = timers.periodicTimers.first;
        final policyTimer = timers.periodicTimers.last;
        final retry = timers.oneShotTimers.single;
        expect(periodic.isActive, isTrue);
        expect(policyTimer.isActive, isTrue);
        expect(retry.isActive, isTrue);

        await policyTimer.fire();

        expect(periodic.isActive, isFalse);
        expect(timers.periodicTimers.last.isActive, isTrue);
        expect(client.activePolicy.timeIntervalSeconds, 20);
        expect(retry.isActive, isTrue);

        await client.dispose();
      },
    );

    test('dispose cancels every timer and remains idempotent', () async {
      final timers = _FakeTelemetryTimerFactory();
      final transport = _ScriptedTelemetryTransport(
        uploadOutcomes: [
          const TelemetryUploadException('server unavailable', statusCode: 503),
        ],
      );
      final storage = _CloseTrackingTelemetryStorage();
      final client = _buildClient(
        timers,
        transport,
        storage: storage,
        policyFetchIntervalSeconds: 30,
      );

      await client.record(event: TelemetryEvents.sshSessionStarted);
      await client.flush();
      expect(timers.activeTimers, hasLength(3));

      final firstDispose = client.dispose();
      final secondDispose = client.dispose();
      expect(identical(firstDispose, secondDispose), isTrue);
      await firstDispose;

      expect(timers.activeTimers, isEmpty);
      expect(storage.closeCalls, 1);
    });
  });

  group('TelemetryClient record storage boundary', () {
    test(
      'contains insert failures and returns false to fire-and-forget callers',
      () async {
        final storage = _ThrowingInsertTelemetryStorage();
        final client = _buildClient(
          _FakeTelemetryTimerFactory(),
          _ScriptedTelemetryTransport(),
          storage: storage,
        );

        expect(
          await client.record(event: TelemetryEvents.sshSessionStarted),
          isFalse,
        );
        expect(storage.insertCalls, 1);
        expect(
          client.latestDiagnostics.lastSyncError,
          'Telemetry storage operation failed',
        );

        await client.dispose();
      },
    );

    test(
      'rejects unsafe config metadata before inserting an envelope',
      () async {
        final storage = _CloseTrackingTelemetryStorage();
        final client = _buildClient(
          _FakeTelemetryTimerFactory(),
          _ScriptedTelemetryTransport(),
          storage: storage,
          config: const TelemetryClientConfig(
            baseUrl: 'https://telemetry.example.test',
            deviceId: 'device-safe',
            appVersion: 'token value',
            buildNumber: '100',
            platform: 'android',
            releaseChannel: 'test',
            deviceEnrollmentSecret: 'test-secret',
            policyFetchIntervalSeconds: 0,
          ),
        );

        expect(
          await client.record(event: TelemetryEvents.sshSessionStarted),
          isFalse,
        );
        expect(storage.insertCalls, 0);

        await client.dispose();
      },
    );
  });
}

TelemetryClient _buildClient(
  _FakeTelemetryTimerFactory timers,
  _ScriptedTelemetryTransport transport, {
  TelemetryStorage? storage,
  TelemetryClientConfig? config,
  int policyFetchIntervalSeconds = 0,
}) {
  return TelemetryClient(
    config:
        config ??
        TelemetryClientConfig(
          baseUrl: 'https://telemetry.example.test',
          deviceId: 'device-state-1',
          appVersion: '1.0.0',
          buildNumber: '100',
          platform: 'android',
          releaseChannel: 'test',
          deviceEnrollmentSecret: 'test-secret',
          policyFetchIntervalSeconds: policyFetchIntervalSeconds,
        ),
    storage: storage ?? _CloseTrackingTelemetryStorage(),
    transport: transport,
    initialPolicy: _policy(),
    timerFactory: timers,
    clock: () => DateTime.utc(2026, 8, 28),
    random: Random(0),
  );
}

TelemetryUploadPolicy _policy({int intervalSeconds = 10}) =>
    TelemetryUploadPolicy(
      uploadEnabled: true,
      batchSizeThreshold: 100,
      timeIntervalSeconds: intervalSeconds,
      maxBatchSize: 10,
      clientMaxLocalRecords: 100,
      specialTriggers: const [
        'highPriorityError',
        'appBackground',
        'networkRecovered',
        'appForegroundWithBacklog',
      ],
      policyVersion: 1,
    );

final class _FakeTelemetryTimerFactory implements TelemetryTimerFactory {
  final List<_FakeTelemetryTimer> oneShotTimers = [];
  final List<_FakeTelemetryTimer> periodicTimers = [];

  Iterable<_FakeTelemetryTimer> get activeTimers sync* {
    yield* oneShotTimers.where((timer) => timer.isActive);
    yield* periodicTimers.where((timer) => timer.isActive);
  }

  @override
  TelemetryTimer schedule(Duration duration, TelemetryTimerCallback callback) {
    final timer = _FakeTelemetryTimer(duration, callback, periodic: false);
    oneShotTimers.add(timer);
    return timer;
  }

  @override
  TelemetryTimer schedulePeriodic(
    Duration duration,
    TelemetryTimerCallback callback,
  ) {
    final timer = _FakeTelemetryTimer(duration, callback, periodic: true);
    periodicTimers.add(timer);
    return timer;
  }
}

final class _FakeTelemetryTimer implements TelemetryTimer {
  _FakeTelemetryTimer(this.duration, this.callback, {required this.periodic});

  final Duration duration;
  final TelemetryTimerCallback callback;
  final bool periodic;
  bool _isActive = true;

  @override
  bool get isActive => _isActive;

  @override
  void cancel() {
    _isActive = false;
  }

  Future<void> fire() async {
    if (!_isActive) return;
    if (!periodic) cancel();
    await callback();
  }
}

final class _ScriptedTelemetryTransport implements TelemetryTransport {
  _ScriptedTelemetryTransport({
    this.firstUploadGate,
    Iterable<TelemetryUploadException?> uploadOutcomes = const [],
    this.remotePolicy,
  }) : uploadOutcomes = List<TelemetryUploadException?>.from(uploadOutcomes);

  final Completer<void>? firstUploadGate;
  final Completer<void> firstUploadStarted = Completer<void>();
  final List<TelemetryUploadException?> uploadOutcomes;
  final TelemetryUploadPolicy? remotePolicy;
  final List<List<TelemetryEventRecord>> uploadedBatches = [];
  int uploadCalls = 0;
  int policyCalls = 0;

  @override
  Future<TelemetryAuthResult?> authenticateDevice({
    required String baseUrl,
    required String deviceId,
    required String platform,
    required String appVersion,
    String? authSecret,
    int? expEpoch,
  }) async => const TelemetryAuthResult(
    token: 'state-machine-token',
    expiresInSeconds: 3600,
  );

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
  }) async {
    policyCalls++;
    return remotePolicy ?? _policy();
  }

  @override
  Future<TelemetryBatchUploadResult> uploadBatch({
    required String baseUrl,
    required String authToken,
    required String deviceId,
    required List<TelemetryEventRecord> records,
  }) async {
    uploadCalls++;
    if (uploadCalls == 1 && firstUploadGate != null) {
      firstUploadStarted.complete();
      await firstUploadGate!.future;
    }
    if (uploadOutcomes.isNotEmpty) {
      final outcome = uploadOutcomes.removeAt(0);
      if (outcome != null) throw outcome;
    }
    uploadedBatches.add(List<TelemetryEventRecord>.from(records));
    return TelemetryBatchUploadResult(
      ackResults: [
        for (final record in records)
          TelemetryAckResult(eventId: record.eventId, status: 'accepted'),
      ],
    );
  }
}

final class _CloseTrackingTelemetryStorage extends MemoryTelemetryStorage {
  int insertCalls = 0;
  int closeCalls = 0;

  @override
  Future<void> insertRecord(TelemetryEventRecord record) {
    insertCalls++;
    return super.insertRecord(record);
  }

  @override
  Future<void> close() async {
    closeCalls++;
    await super.close();
  }
}

final class _ThrowingInsertTelemetryStorage extends MemoryTelemetryStorage {
  int insertCalls = 0;

  @override
  Future<void> insertRecord(TelemetryEventRecord record) async {
    insertCalls++;
    throw StateError('storage unavailable');
  }
}
