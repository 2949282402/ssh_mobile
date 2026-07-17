import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/display_mode_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DisplayModeService', () {
    test(
      'enableHighRefreshRate runs safely without throwing exceptions',
      () async {
        // In desktop/test runner environment, Platform.isAndroid is false.
        // The method should safely complete without throwing.
        await expectLater(
          DisplayModeService.enableHighRefreshRate(),
          completes,
        );
      },
    );
  });
}
