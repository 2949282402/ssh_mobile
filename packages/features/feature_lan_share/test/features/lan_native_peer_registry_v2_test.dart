import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:network_sdk/network_sdk.dart';

part 'lan_native_peer_registry_failure_tests.dart';
part 'lan_native_peer_registry_observation_tests.dart';
part 'lan_native_peer_registry_policy_tests.dart';
part 'lan_native_peer_registry_restore_tests.dart';
part 'lan_native_peer_registry_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  _registerRegistryRestoreTests();
  _registerRegistryObservationTests();
  _registerRegistryPolicyTests();
  _registerRegistryFailureTests();
}
