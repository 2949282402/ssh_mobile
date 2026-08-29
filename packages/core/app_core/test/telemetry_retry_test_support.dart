import 'dart:async';
import 'dart:math';

import 'package:app_core/app_core.dart';

TelemetryClient buildRetryTelemetryClient(
  FakeTelemetryTimerFactory timers,
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
    storage: storage ?? CloseTrackingTelemetryStorage(),
    transport: transport,
    initialPolicy: retryPolicy(),
    timerFactory: timers,
    clock: () => DateTime.utc(2026, 8, 28),
    random: Random(0),
  );
}

TelemetryUploadPolicy retryPolicy({int intervalSeconds = 10}) =>
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

final class FakeTelemetryTimerFactory implements TelemetryTimerFactory {
  final List<FakeTelemetryTimer> oneShotTimers = [];
  final List<FakeTelemetryTimer> periodicTimers = [];
  final Completer<void> oneShotScheduled = Completer<void>();

  Iterable<FakeTelemetryTimer> get activeTimers sync* {
    yield* oneShotTimers.where((timer) => timer.isActive);
    yield* periodicTimers.where((timer) => timer.isActive);
  }

  @override
  TelemetryTimer schedule(Duration duration, TelemetryTimerCallback callback) {
    final timer = FakeTelemetryTimer(duration, callback, periodic: false);
    oneShotTimers.add(timer);
    if (!oneShotScheduled.isCompleted) oneShotScheduled.complete();
    return timer;
  }

  @override
  TelemetryTimer schedulePeriodic(
    Duration duration,
    TelemetryTimerCallback callback,
  ) {
    final timer = FakeTelemetryTimer(duration, callback, periodic: true);
    periodicTimers.add(timer);
    return timer;
  }
}

final class FakeTelemetryTimer implements TelemetryTimer {
  FakeTelemetryTimer(this.duration, this.callback, {required this.periodic});

  final Duration duration;
  final TelemetryTimerCallback callback;
  final bool periodic;
  bool _isActive = true;

  @override
  bool get isActive => _isActive;

  @override
  void cancel() => _isActive = false;

  Future<void> fire() async {
    if (!_isActive) return;
    if (!periodic) cancel();
    await callback();
  }
}

final class ScriptedTelemetryTransport implements TelemetryTransport {
  ScriptedTelemetryTransport({
    this.firstUploadGate,
    this.secondUploadGate,
    this.policyGate,
    this.policyRequestStarted,
    Iterable<TelemetryUploadException?> authOutcomes = const [],
    Iterable<TelemetryAuthResult?> authResultOutcomes = const [],
    Iterable<TelemetryUploadException?> uploadOutcomes = const [],
    Iterable<List<TelemetryAckResult>?> ackResultOutcomes = const [],
    this.remotePolicy,
  }) : authOutcomes = List<TelemetryUploadException?>.from(authOutcomes),
       authResultOutcomes = List<TelemetryAuthResult?>.from(authResultOutcomes),
       uploadOutcomes = List<TelemetryUploadException?>.from(uploadOutcomes),
       ackResultOutcomes = List<List<TelemetryAckResult>?>.from(
         ackResultOutcomes,
       );

  final Completer<void>? firstUploadGate;
  final Completer<void>? secondUploadGate;
  final Completer<void>? policyGate;
  final Completer<void>? policyRequestStarted;
  final Completer<void> firstUploadStarted = Completer<void>();
  final Completer<void> secondUploadStarted = Completer<void>();
  final List<TelemetryUploadException?> authOutcomes;
  final List<TelemetryAuthResult?> authResultOutcomes;
  final List<TelemetryUploadException?> uploadOutcomes;
  final List<List<TelemetryAckResult>?> ackResultOutcomes;
  final TelemetryUploadPolicy? remotePolicy;
  final List<List<TelemetryEventRecord>> uploadedBatches = [];
  int authCalls = 0;
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
  }) async {
    authCalls++;
    if (authResultOutcomes.isNotEmpty) {
      return authResultOutcomes.removeAt(0);
    }
    if (authOutcomes.isNotEmpty) {
      final outcome = authOutcomes.removeAt(0);
      if (outcome != null) throw outcome;
    }
    return const TelemetryAuthResult(
      token: 'state-machine-token',
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
    policyCalls++;
    if (policyRequestStarted != null && !policyRequestStarted!.isCompleted) {
      policyRequestStarted!.complete();
    }
    if (policyGate != null) await policyGate!.future;
    return remotePolicy ?? retryPolicy();
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

final class StalePolicyTelemetryTransport implements TelemetryTransport {
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

final class CloseTrackingTelemetryStorage extends MemoryTelemetryStorage {
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

final class ThrowingInsertTelemetryStorage extends MemoryTelemetryStorage {
  int insertCalls = 0;

  @override
  Future<void> insertRecord(TelemetryEventRecord record) async {
    insertCalls++;
    throw StateError('storage unavailable');
  }
}
