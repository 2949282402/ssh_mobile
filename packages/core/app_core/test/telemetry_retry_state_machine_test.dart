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

    test(
      'gates a queued trigger behind the failed upload retry delay',
      () async {
        final timers = _FakeTelemetryTimerFactory();
        final transport = _ScriptedTelemetryTransport(
          firstUploadGate: Completer<void>(),
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
        final first = client.flush();
        await transport.firstUploadStarted.future;

        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: const {'session_type': 'queued-after-failure'},
        );
        final queued = client.flush();
        expect(identical(first, queued), isTrue);

        transport.firstUploadGate!.complete();
        await timers.oneShotScheduled.future;

        expect(transport.uploadCalls, 1);
        expect(timers.oneShotTimers, hasLength(1));
        expect(
          timers.oneShotTimers.single.duration,
          const Duration(seconds: 7),
        );
        expect(timers.oneShotTimers.single.isActive, isTrue);

        await timers.oneShotTimers.single.fire();
        await Future.wait([first, queued]);

        expect(transport.uploadCalls, 2);
        expect(await client.storage.fetchPendingBatch(10), isEmpty);

        await client.dispose();
      },
    );

    test(
      'partial ACKs sync acknowledged rows and retry unacknowledged rows',
      () async {
        final timers = _FakeTelemetryTimerFactory();
        final transport = _ScriptedTelemetryTransport();
        final client = _buildClient(timers, transport);

        await client.record(event: TelemetryEvents.sshSessionStarted);
        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: const {'session_type': 'partial-ack'},
        );
        final pending = await client.storage.fetchPendingBatch(10);
        transport.ackResultOutcomes.add([
          TelemetryAckResult(
            eventId: pending.first.eventId,
            status: 'accepted',
          ),
        ]);
        transport.ackResultOutcomes.add(null);

        await client.flush();

        expect(transport.uploadCalls, 1);
        expect(await client.storage.fetchPendingBatch(10), hasLength(1));
        expect(timers.oneShotTimers, hasLength(1));
        expect(timers.oneShotTimers.single.isActive, isTrue);

        await timers.oneShotTimers.single.fire();

        expect(transport.uploadCalls, 2);
        expect(await client.storage.fetchPendingBatch(10), isEmpty);

        await client.dispose();
      },
    );

    test('empty ACK results remain pending and schedule a retry', () async {
      final timers = _FakeTelemetryTimerFactory();
      final transport = _ScriptedTelemetryTransport(
        ackResultOutcomes: [const <TelemetryAckResult>[], null],
      );
      final client = _buildClient(timers, transport);

      await client.record(event: TelemetryEvents.sshSessionStarted);
      await client.flush();

      expect(transport.uploadCalls, 1);
      expect(await client.storage.fetchPendingBatch(10), hasLength(1));
      expect(timers.oneShotTimers, hasLength(1));
      expect(timers.oneShotTimers.single.isActive, isTrue);

      await timers.oneShotTimers.single.fire();

      expect(transport.uploadCalls, 2);
      expect(await client.storage.fetchPendingBatch(10), isEmpty);

      await client.dispose();
    });

    test(
      'flush waits for replay cleanup and its queued follow-up drain',
      () async {
        final timers = _FakeTelemetryTimerFactory();
        final transport = _ScriptedTelemetryTransport(
          firstUploadGate: Completer<void>(),
          secondUploadGate: Completer<void>(),
        );
        final client = _buildClient(timers, transport);

        await client.record(event: TelemetryEvents.sshSessionStarted);
        final replay = client.replayAllLocalRecords();
        await transport.firstUploadStarted.future;

        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: const {'session_type': 'replay-follow-up'},
        );
        expect(transport.uploadCalls, 1);
        expect(await client.storage.fetchPendingBatch(10), hasLength(2));
        final flush = client.flush();
        var flushCompleted = false;
        unawaited(flush.then((_) => flushCompleted = true));
        var replayCompleted = false;
        unawaited(replay.then((_) => replayCompleted = true));

        transport.firstUploadGate!.complete();
        await transport.secondUploadStarted.future;
        await Future<void>.value();

        expect(flushCompleted, isFalse);
        expect(replayCompleted, isFalse);

        transport.secondUploadGate!.complete();
        await Future.wait([flush, replay]);
        expect(flushCompleted, isTrue);
        expect(replayCompleted, isTrue);
        expect(transport.uploadCalls, 2);
        expect(await client.storage.fetchPendingBatch(10), isEmpty);

        await client.dispose();
      },
    );

    test(
      'stale policy 401 does not clear a newer token from upload recovery',
      () async {
        final timers = _FakeTelemetryTimerFactory();
        final transport = _StalePolicyTelemetryTransport();
        final client = _buildClient(timers, transport);

        await client.record(event: TelemetryEvents.sshSessionStarted);
        await client.flush();
        expect(transport.authCalls, 1);

        final policyRefresh = client.refreshPolicy();
        await transport.policyRequestStarted.future;

        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: const {'session_type': 'upload-reauth'},
        );
        await client.flush();
        expect(transport.authCalls, 2);

        transport.policyRequestGate.complete();
        expect(await policyRefresh, isFalse);

        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: const {'session_type': 'token-retained'},
        );
        await client.flush();

        expect(transport.authCalls, 2);
        expect(await client.storage.fetchPendingBatch(10), isEmpty);

        await client.dispose();
      },
    );
  });
}

TelemetryClient _buildClient(
  _FakeTelemetryTimerFactory timers,
  TelemetryTransport transport, {
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
  final Completer<void> oneShotScheduled = Completer<void>();

  Iterable<_FakeTelemetryTimer> get activeTimers sync* {
    yield* oneShotTimers.where((timer) => timer.isActive);
    yield* periodicTimers.where((timer) => timer.isActive);
  }

  @override
  TelemetryTimer schedule(Duration duration, TelemetryTimerCallback callback) {
    final timer = _FakeTelemetryTimer(duration, callback, periodic: false);
    oneShotTimers.add(timer);
    if (!oneShotScheduled.isCompleted) oneShotScheduled.complete();
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
    this.secondUploadGate,
    Iterable<TelemetryUploadException?> uploadOutcomes = const [],
    Iterable<List<TelemetryAckResult>?> ackResultOutcomes = const [],
    this.remotePolicy,
  }) : uploadOutcomes = List<TelemetryUploadException?>.from(uploadOutcomes),
       ackResultOutcomes = List<List<TelemetryAckResult>?>.from(
         ackResultOutcomes,
       );

  final Completer<void>? firstUploadGate;
  final Completer<void>? secondUploadGate;
  final Completer<void> firstUploadStarted = Completer<void>();
  final Completer<void> secondUploadStarted = Completer<void>();
  final List<TelemetryUploadException?> uploadOutcomes;
  final List<List<TelemetryAckResult>?> ackResultOutcomes;
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
    if (uploadCalls == 2 && secondUploadGate != null) {
      secondUploadStarted.complete();
      await secondUploadGate!.future;
    }
    if (uploadOutcomes.isNotEmpty) {
      final outcome = uploadOutcomes.removeAt(0);
      if (outcome != null) throw outcome;
    }
    uploadedBatches.add(List<TelemetryEventRecord>.from(records));
    if (ackResultOutcomes.isNotEmpty) {
      final ackResults = ackResultOutcomes.removeAt(0);
      if (ackResults != null) {
        return TelemetryBatchUploadResult(ackResults: ackResults);
      }
    }
    return TelemetryBatchUploadResult(
      ackResults: [
        for (final record in records)
          TelemetryAckResult(eventId: record.eventId, status: 'accepted'),
      ],
    );
  }
}

final class _StalePolicyTelemetryTransport implements TelemetryTransport {
  final Completer<void> policyRequestGate = Completer<void>();
  final Completer<void> policyRequestStarted = Completer<void>();
  int authCalls = 0;
  int uploadCalls = 0;

  @override
  Future<TelemetryAuthResult?> authenticateDevice({
    required String baseUrl,
    required String deviceId,
    required String platform,
    required String appVersion,
    String? authSecret,
    int? expEpoch,
  }) async {
    authCalls++;
    return TelemetryAuthResult(
      token: 'policy-token-$authCalls',
      expiresInSeconds: 3600,
    );
  }

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
    policyRequestStarted.complete();
    await policyRequestGate.future;
    throw const TelemetryUploadException('stale policy token', statusCode: 401);
  }

  @override
  Future<TelemetryBatchUploadResult> uploadBatch({
    required String baseUrl,
    required String authToken,
    required String deviceId,
    required List<TelemetryEventRecord> records,
  }) async {
    uploadCalls++;
    if (authToken == 'policy-token-1' && uploadCalls == 2) {
      throw const TelemetryUploadException(
        'expired upload token',
        statusCode: 401,
      );
    }
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
