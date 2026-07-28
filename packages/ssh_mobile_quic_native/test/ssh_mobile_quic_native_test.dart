import 'package:test/test.dart';
import 'package:ssh_mobile_quic_native/ssh_mobile_quic_native.dart';

void main() {

  const native = SshMobileQuicNative();

  test('native FFI ping works', () {
    const quic = SshMobileQuicNative();
    final result = quic.ping();

    expect(
      result,
      20260727,
    );
  });
    test(
    'MsQuic runtime can be initialized',
    () {

      final result =
          native.msquicOpenTest();

      expect(
        result,
        0,
      );
    },
  );
}