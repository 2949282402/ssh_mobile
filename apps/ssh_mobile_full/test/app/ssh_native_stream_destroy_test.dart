// AppSshNativeStream destroy-path coverage.
//
// destroy() is the socket destroy fast path used by dartssh2: it must release
// the stream from the connector, complete `done`, and make later sends fail
// closed instead of silently dropping bytes.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/ssh_native_stream_adapters.dart';

import 'ssh_native_stream_connector_test_support.dart';

void main() {
  group('AppSshNativeStream destroy', () {
    test(
      'destroy releases the stream and completes done without close wire',
      () async {
        final gateway = StreamFakeGateway();
        final connector = AppSshNativeStreamConnector(
          gatewayProvider: () async => gateway,
          openerDeviceIdProvider: () async => 'device-a',
        );

        final stream = await connector.open(peerId: 'peer-a');
        expect(connector.activeStreamCount, 1);

        stream.destroy();
        stream.destroy();

        await stream.done;
        expect(connector.activeStreamCount, 0);
        await expectLater(
          stream.send(Uint8List.fromList([0x01])),
          throwsA(isA<StateError>()),
        );

        await connector.closeAll();
      },
    );
  });
}
