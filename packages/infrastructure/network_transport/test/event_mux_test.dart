import 'package:flutter_test/flutter_test.dart';
import 'package:network_transport/network_transport.dart';

void main() {
  test(
    'critical control is preferred but data is served after eight controls',
    () {
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
      expect(
        mux.add('data', priority: EventMuxPriority.data, bytes: 1),
        isTrue,
      );

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
    },
  );

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
}
