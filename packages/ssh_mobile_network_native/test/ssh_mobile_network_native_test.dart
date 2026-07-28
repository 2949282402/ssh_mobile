import 'package:test/test.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

void main() {
  const native = SshMobileNetworkNative();

  test('SshMobileNetworkNative can be instantiated', () {
    expect(native, isNotNull);
  });
}
