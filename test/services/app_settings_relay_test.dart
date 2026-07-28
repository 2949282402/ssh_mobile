import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('Relay settings persist only a TLS origin', () async {
    final settings = AppSettings();
    addTearDown(settings.dispose);
    await settings.init();

    await expectLater(
      settings.setRelayEndpoint('http://relay.example.test:8080'),
      throwsArgumentError,
    );
    await expectLater(
      settings.setRelayEndpoint(
        'https://user@relay.example.test:8443?token=secret',
      ),
      throwsArgumentError,
    );
    await settings.setRelayEndpoint('https://relay.example.test:8443/');

    expect(settings.relayEndpoint, 'https://relay.example.test:8443');
    expect(
      (await SharedPreferences.getInstance()).getString('relay_endpoint'),
      'https://relay.example.test:8443',
    );
  });
}
