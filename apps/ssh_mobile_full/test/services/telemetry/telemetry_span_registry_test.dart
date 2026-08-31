// TelemetryTraceRegistry lifecycle, pruning, and capacity-boundary tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/telemetry/telemetry_span.dart';

void main() {
  group('telemetry span helpers', () {
    test('newTelemetryTraceId produces a v4 uuid shape', () {
      expect(newTelemetryTraceId(), matches(RegExp(r'^[0-9a-f-]{36}$')));
    });

    test('telemetryElapsedMs treats a missing start as zero', () {
      expect(telemetryElapsedMs(null), 0);
      final startedAt = DateTime.now().subtract(
        const Duration(milliseconds: 12),
      );
      expect(telemetryElapsedMs(startedAt), greaterThanOrEqualTo(12));
    });
  });

  group('TelemetryTraceRegistry', () {
    test('rejects invalid ttl and capacity bounds', () {
      expect(
        () => TelemetryTraceRegistry(bindingTtl: Duration.zero),
        throwsArgumentError,
      );
      expect(() => TelemetryTraceRegistry(maxBindings: 0), throwsArgumentError);
    });

    test('isDisposed reflects dispose and late binds fail closed', () {
      final registry = TelemetryTraceRegistry();
      expect(registry.isDisposed, isFalse);
      registry.dispose();
      expect(registry.isDisposed, isTrue);
      expect(
        () => registry.bindPeer(peerId: 'peer-a', traceId: 'trace-a'),
        throwsStateError,
      );
    });

    test('empty identifiers are rejected before mutation', () {
      final registry = TelemetryTraceRegistry();
      expect(
        () => registry.bindPeer(peerId: '   ', traceId: 'trace-a'),
        throwsArgumentError,
      );
      expect(
        () => registry.bindCommand(
          commandId: '',
          peerId: 'peer-a',
          traceId: 'trace-a',
        ),
        throwsArgumentError,
      );
    });

    test('traceForAnyPeer is unambiguous only with one distinct trace', () {
      final registry = TelemetryTraceRegistry();
      expect(registry.traceForAnyPeer(), isNull);
      registry.bindPeer(peerId: 'peer-a', traceId: 'trace-only');
      expect(registry.traceForAnyPeer(), 'trace-only');
      registry.bindPeer(peerId: 'peer-b', traceId: 'trace-second');
      expect(registry.traceForAnyPeer(), isNull);
    });

    test('releasePeerTrace without a trace clears a single-trace peer', () {
      final registry = TelemetryTraceRegistry();
      registry.bindPeer(peerId: 'peer-a', traceId: 'trace-a');

      registry.releasePeerTrace(peerId: 'peer-a');

      expect(registry.traceForPeer('peer-a'), isNull);
      expect(registry.peerBindingCount, 0);
    });

    test(
      'completeCommand with an explicit trace releases only that binding',
      () {
        final registry = TelemetryTraceRegistry();
        registry
          ..bindPeer(peerId: 'peer-a', traceId: 'trace-a')
          ..bindPeer(peerId: 'peer-a', traceId: 'trace-b')
          ..bindCommand(
            commandId: 'command-x',
            peerId: 'peer-a',
            traceId: 'trace-a',
          )
          ..bindCommand(
            commandId: 'command-x',
            peerId: 'peer-a',
            traceId: 'trace-b',
          );

        registry.completeCommand('command-x', traceId: 'trace-a');

        expect(registry.traceForCommand('command-x'), 'trace-b');
        expect(registry.hasCommandBinding('command-x'), isTrue);
        // Completing the only command that still referenced trace-a releases
        // that peer context; trace-b remains independently bound.
        expect(registry.peerBindingCount, 1);
        registry.completeCommand('command-x', traceId: 'trace-b');
        expect(registry.hasCommandBinding('command-x'), isFalse);
        expect(registry.peerBindingCount, 0);
      },
    );

    test('releasePeerTrace without a trace refuses an ambiguous peer', () {
      final registry = TelemetryTraceRegistry();
      registry
        ..bindPeer(peerId: 'peer-a', traceId: 'trace-a')
        ..bindPeer(peerId: 'peer-a', traceId: 'trace-b');

      registry.releasePeerTrace(peerId: 'peer-a');

      expect(registry.peerBindingCount, 2);
      registry.releasePeerTrace(peerId: 'peer-a', traceId: 'trace-b');
      expect(registry.traceForPeer('peer-a'), 'trace-a');
    });

    test('releaseTrace removes every peer and command for one operation', () {
      final registry = TelemetryTraceRegistry();
      registry
        ..bindPeer(peerId: 'peer-a', traceId: 'trace-op')
        ..bindCommand(
          commandId: 'command-op',
          peerId: 'peer-a',
          traceId: 'trace-op',
        )
        ..bindPeer(peerId: 'peer-b', traceId: 'trace-other')
        ..bindCommand(
          commandId: 'command-other',
          peerId: 'peer-b',
          traceId: 'trace-other',
        );

      registry.releaseTrace('trace-op');

      expect(registry.hasTrace('trace-op'), isFalse);
      expect(registry.traceForPeer('peer-a'), isNull);
      expect(registry.traceForPeer('peer-b'), 'trace-other');
      expect(registry.traceForCommand('command-other'), 'trace-other');
    });

    test('clear empties all contexts and leaves the registry usable', () {
      final registry = TelemetryTraceRegistry();
      registry
        ..bindPeer(peerId: 'peer-a', traceId: 'trace-a')
        ..bindCommand(
          commandId: 'command-a',
          peerId: 'peer-a',
          traceId: 'trace-a',
        );

      registry.clear();

      expect(registry.peerBindingCount, 0);
      expect(registry.commandBindingCount, 0);
      registry.bindPeer(peerId: 'peer-b', traceId: 'trace-b');
      expect(registry.traceForPeer('peer-b'), 'trace-b');
    });

    test('capacity trim evicts the oldest command when no peer exists', () {
      var now = DateTime.utc(2026, 1, 1);
      final registry = TelemetryTraceRegistry(maxBindings: 1, clock: () => now);
      registry.bindCommand(
        commandId: 'command-old',
        peerId: 'peer-a',
        traceId: 'trace-old',
      );
      now = now.add(const Duration(seconds: 1));
      registry.bindCommand(
        commandId: 'command-new',
        peerId: 'peer-a',
        traceId: 'trace-new',
      );

      expect(registry.commandBindingCount, 1);
      expect(registry.hasCommandBinding('command-new'), isTrue);
      expect(registry.hasCommandBinding('command-old'), isFalse);
    });

    test('expired command contexts are pruned at the ttl boundary', () {
      var now = DateTime.utc(2026, 1, 1);
      final registry = TelemetryTraceRegistry(
        bindingTtl: const Duration(seconds: 10),
        clock: () => now,
      );
      registry.bindCommand(
        commandId: 'command-stale',
        peerId: 'peer-a',
        traceId: 'trace-stale',
      );
      now = now.add(const Duration(seconds: 11));

      expect(registry.hasCommandBinding('command-stale'), isFalse);
      expect(registry.commandBindingCount, 0);
    });
  });
}
