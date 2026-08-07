import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/utils/startup_instrumentation.dart';

void main() {
  group('StartupInstrumentation Tests', () {
    final probe = StartupInstrumentation.instance;

    setUp(() {
      probe.reset();
    });

    test('tracks timings correctly', () {
      probe.recordMainStart();
      probe.recordRunAppStart();
      probe.recordCoreReady();
      probe.recordHomeReady();

      final snapshot = probe.snapshot();
      expect(snapshot['timings_ms']['main_start'], equals(0));
      expect(snapshot['timings_ms']['run_app_start'], greaterThanOrEqualTo(0));
      expect(snapshot['timings_ms']['core_ready'], greaterThanOrEqualTo(0));
      expect(snapshot['timings_ms']['home_ready'], greaterThanOrEqualTo(0));
    });

    test('tracks service construct and ensure counts', () {
      probe.recordServiceConstructed('SshService');
      probe.recordServiceConstructed('SshService');
      probe.recordServiceInitialized('SshService');

      expect(probe.getConstructCount('SshService'), equals(2));
      expect(probe.getEnsureCount('SshService'), equals(1));
    });

    test('tracks resource counters', () {
      probe.incrementResource('timer');
      probe.incrementResource('timer');
      expect(probe.getResourceCount('timer'), equals(2));

      probe.decrementResource('timer');
      expect(probe.getResourceCount('timer'), equals(1));
    });
  });
}
