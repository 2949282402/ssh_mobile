import 'package:app_core/app_core.dart';
import 'package:feature_webview/feature_webview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ClientWebViewService webViewService;
  late _FakeWebViewSettings settings;

  setUp(() async {
    settings = _FakeWebViewSettings();
    webViewService = ClientWebViewService(
      logger: const _TestLogger(),
      networkLoader: const _TestNetworkLoader(),
    );
  });

  tearDown(() => webViewService.dispose());

  group('ClientWebViewViewModel Tests', () {
    test('Initialization attributes checks without platform controllers', () {
      final viewModel = ClientWebViewViewModel(
        webViewService: webViewService,
        settings: settings,
      );

      // Verify basic settings proxying
      expect(viewModel.language, equals(AppLanguage.zh));
    });
  });
}

final class _FakeWebViewSettings extends ChangeNotifier
    implements WebViewSettingsPort {
  @override
  AppLanguage language = AppLanguage.zh;
}

final class _TestLogger implements AppLogger {
  const _TestLogger();

  @override
  void log(LogRecord record) {}

  @override
  AppLogger scope(String name) => this;
}

final class _TestNetworkLoader implements ClientWebViewNetworkLoader {
  const _TestNetworkLoader();

  @override
  Future<ClientWebViewFetchedPage> load(Uri uri) async {
    return ClientWebViewFetchedPage(
      requestedUri: uri,
      finalUri: uri,
      contentType: 'text/plain',
      body: '',
    );
  }
}
