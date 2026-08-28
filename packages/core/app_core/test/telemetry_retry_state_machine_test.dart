import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'telemetry_retry_test_support.dart';

void main() {
  group('TelemetryClient retry and trigger state machines', () {
    test(
      'keeps periodic flush alive while retrying and after success',
      () async {
        final timers = FakeTelemetryTimerFactory();
        final transport = ScriptedTelemetryTransport(
          uploadOutcomes: [
            const TelemetryUploadException(
              'server unavailable',
              statusCode: 503,
            ),
            null,
          ],
        );
        final client = buildRetryTelemetryClient(timers, transport);

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

        await periodic.fire();
        expect(transport.uploadCalls, 2);

        await client.dispose();
      },
    );

    test(
      'coalesces a trigger during an active upload into a follow-up drain',
      () async {
        final timers = FakeTelemetryTimerFactory();
        final transport = ScriptedTelemetryTransport(
          firstUploadGate: Completer<void>(),
        );
        final client = buildRetryTelemetryClient(timers, transport);

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
        final timers = FakeTelemetryTimerFactory();
        final transport = ScriptedTelemetryTransport(
          uploadOutcomes: [
            const TelemetryUploadException(
              'rate limited',
              statusCode: 429,
              retryAfterSeconds: 7,
            ),
            null,
          ],
        );
        final client = buildRetryTelemetryClient(timers, transport);

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
        final timers = FakeTelemetryTimerFactory();
        final transport = ScriptedTelemetryTransport(
          uploadOutcomes: [
            const TelemetryUploadException(
              'server unavailable',
              statusCode: 503,
            ),
            null,
          ],
        );
        final client = buildRetryTelemetryClient(timers, transport);

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
        final timers = FakeTelemetryTimerFactory();
        final transport = ScriptedTelemetryTransport(
          uploadOutcomes: [
            const TelemetryUploadException(
              'server unavailable',
              statusCode: 503,
            ),
          ],
          remotePolicy: retryPolicy(intervalSeconds: 20),
        );
        final client = buildRetryTelemetryClient(
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

    test(
      'coalesces concurrent policy refreshes and repeats a requested refresh',
      () async {
        final timers = FakeTelemetryTimerFactory();
        final policyGate = Completer<void>();
        final policyStarted = Completer<void>();
        final transport = ScriptedTelemetryTransport(
          policyGate: policyGate,
          policyRequestStarted: policyStarted,
          remotePolicy: retryPolicy(intervalSeconds: 20),
        );
        final client = buildRetryTelemetryClient(timers, transport);

        final first = client.refreshPolicy();
        await policyStarted.future;
        final second = client.refreshPolicy();
        expect(identical(first, second), isTrue);

        policyGate.complete();
        expect(await first, isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(transport.policyCalls, 2);
        expect(client.activePolicy.timeIntervalSeconds, 20);

        await client.dispose();
      },
    );

    test(
      'lifecycle triggers request uploads and ignore triggers after dispose',
      () async {
        final timers = FakeTelemetryTimerFactory();
        final transport = ScriptedTelemetryTransport();
        final client = buildRetryTelemetryClient(timers, transport);

        client.onAppBackground();
        client.onAppForeground();
        client.onNetworkRecovered();
        await Future<void>.delayed(Duration.zero);
        expect(transport.uploadCalls, 0);

        await client.dispose();
        client.onAppBackground();
        client.onAppForeground();
        client.onNetworkRecovered();
        await Future<void>.delayed(Duration.zero);
        expect(transport.uploadCalls, 0);
      },
    );

    test('default timer exposes active state and cancellation', () {
      final timer = const DartTelemetryTimerFactory().schedule(
        const Duration(hours: 1),
        () {},
      );

      expect(timer.isActive, isTrue);
      timer.cancel();
      expect(timer.isActive, isFalse);
    });

    test('dispose cancels every timer and remains idempotent', () async {
      final timers = FakeTelemetryTimerFactory();
      final transport = ScriptedTelemetryTransport(
        uploadOutcomes: [
          const TelemetryUploadException('server unavailable', statusCode: 503),
        ],
      );
      final storage = CloseTrackingTelemetryStorage();
      final client = buildRetryTelemetryClient(
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
}
