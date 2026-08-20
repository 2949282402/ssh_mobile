import 'package:flutter_test/flutter_test.dart';
import 'package:network_transport/network_transport.dart';

void main() {
  test('eight_control_fairness', () {
    final mux = EventMux<String>();
    for (var index = 0; index < 10; index++) {
      expect(
        mux.add(
          'control-$index',
          priority: EventMuxPriority.criticalControl,
          bytes: 1,
        ),
        isTrue,
      );
    }
    expect(mux.add('data', priority: EventMuxPriority.data, bytes: 1), isTrue);

    expect(mux.take(), 'control-0');
    expect(mux.take(), 'control-1');
    expect(mux.take(), 'control-2');
    expect(mux.take(), 'control-3');
    expect(mux.take(), 'control-4');
    expect(mux.take(), 'control-5');
    expect(mux.take(), 'control-6');
    expect(mux.take(), 'control-7');
    expect(mux.take(), 'data');
    expect(mux.take(), 'control-8');
    expect(mux.take(), 'control-9');
  });

  test('data_flood_cannot_starve_critical_control', () {
    final mux = EventMux<String>();
    for (
      var index = 0;
      index < ResourceLimiter.maxDataQueueItems * 4;
      index++
    ) {
      expect(
        mux.add('data-$index', priority: EventMuxPriority.data, bytes: 1),
        isTrue,
      );
    }
    expect(
      mux.add('critical', priority: EventMuxPriority.criticalControl, bytes: 1),
      isTrue,
    );

    expect(mux.take(), 'critical');
  });

  test('control_byte_limit', () {
    final mux = EventMux<String>();
    for (var index = 0; index < 4; index++) {
      expect(
        mux.add(
          'control-$index',
          priority: EventMuxPriority.normalControl,
          bytes: ResourceLimiter.maxEventBytes,
        ),
        isTrue,
      );
    }
    expect(mux.controlBytes, ResourceLimiter.maxControlQueueBytes);
    expect(
      mux.add(
        'control-overflow',
        priority: EventMuxPriority.criticalControl,
        bytes: ResourceLimiter.maxEventBytes,
      ),
      isFalse,
    );
  });

  test('data_byte_limit', () {
    final mux = EventMux<String>();
    for (var index = 0; index < 9; index++) {
      expect(
        mux.add(
          'data-$index',
          priority: EventMuxPriority.data,
          bytes: ResourceLimiter.maxEventBytes,
        ),
        isTrue,
      );
    }
    expect(mux.dataBytes, ResourceLimiter.maxDataQueueBytes);
    expect(mux.dataItemCount, 8);
    expect(mux.take(), 'data-1');
  });

  test('single_event_limit', () {
    final mux = EventMux<String>();
    expect(
      mux.add(
        'too-large',
        priority: EventMuxPriority.criticalControl,
        bytes: ResourceLimiter.maxEventBytes + 1,
      ),
      isFalse,
    );
    expect(mux.isEmpty, isTrue);
  });

  test('data overflow drops oldest data and control overflow rejects', () {
    final mux = EventMux<String>(
      maxControlItems: 1,
      maxControlBytes: 2,
      maxDataItems: 2,
      maxDataBytes: 4,
      maxSinglePayloadBytes: 4,
    );

    expect(mux.add('d1', priority: EventMuxPriority.data, bytes: 2), isTrue);
    expect(mux.add('d2', priority: EventMuxPriority.data, bytes: 2), isTrue);
    expect(mux.add('d3', priority: EventMuxPriority.data, bytes: 2), isTrue);
    expect(mux.droppedDataItems, 1);
    expect(mux.dataBytes, 4);

    expect(
      mux.add('critical', priority: EventMuxPriority.criticalControl, bytes: 2),
      isTrue,
    );
    expect(
      mux.add('normal', priority: EventMuxPriority.normalControl, bytes: 1),
      isFalse,
    );
    expect(mux.rejectedControlItems, 1);
    expect(
      mux.add('too-large', priority: EventMuxPriority.data, bytes: 5),
      isFalse,
    );
    expect(mux.rejectedOversizeItems, 1);
  });

  test('close is explicit and idempotent', () {
    final mux = EventMux<String>();
    expect(mux.add('one', priority: EventMuxPriority.data, bytes: 1), isTrue);
    mux.close();
    mux.close();
    expect(mux.isClosed, isTrue);
    expect(mux.isEmpty, isTrue);
    expect(mux.add('two', priority: EventMuxPriority.data, bytes: 1), isFalse);
  });

  test('ResourceLimiter enforces item, byte, and single-payload budgets', () {
    const limiter = ResourceLimiter.controlQueue;

    expect(
      limiter.canReserve(
        items: ResourceLimiter.maxControlQueueItems,
        bytes: ResourceLimiter.maxControlQueueBytes,
      ),
      isTrue,
    );
    expect(
      limiter.canReserve(
        items: ResourceLimiter.maxControlQueueItems + 1,
        bytes: 0,
      ),
      isFalse,
    );
    expect(
      limiter.canReserve(items: 1, bytes: ResourceLimiter.maxEventBytes + 1),
      isFalse,
    );
  });
}
