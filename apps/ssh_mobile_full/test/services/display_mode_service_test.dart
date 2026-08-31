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

    test('requests high refresh rate on Android and logs success', () async {
      var requests = 0;

      await DisplayModeService.enableHighRefreshRate(
        isAndroid: true,
        requestHighRefreshRate: () async => requests++,
      );

      expect(requests, 1);
    });

    test(
      'swallows platform failures while attempting Android refresh rate',
      () async {
        await expectLater(
          DisplayModeService.enableHighRefreshRate(
            isAndroid: true,
            requestHighRefreshRate: () =>
                Future<void>.error(StateError('display mode unavailable')),
          ),
          completes,
        );
      },
    );
  });
}
