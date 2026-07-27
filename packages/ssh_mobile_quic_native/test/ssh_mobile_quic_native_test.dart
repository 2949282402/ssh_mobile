import 'package:test/test.dart';
import 'package:ssh_mobile_quic_native/ssh_mobile_quic_native.dart';

void main() {
  test('native FFI ping works', () {
    const quic = SshMobileQuicNative();

    final result = quic.ping();

    expect(
      result,
      20260727,
    );
  });
}