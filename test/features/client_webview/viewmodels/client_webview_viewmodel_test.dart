import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ssh_mobile/features/client_webview/viewmodels/client_webview_viewmodel.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppSettings appSettings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    appSettings = AppSettings();
    await appSettings.init();
  });

  group('ClientWebViewViewModel Tests', () {
    test('Initialization attributes checks without platform controllers', () {
      final viewModel = ClientWebViewViewModel(
        appSettings: appSettings,
      );

      // Verify basic settings proxying
      expect(viewModel.language, equals(AppLanguage.zh));
    });
  });
}
