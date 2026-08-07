import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('developerPanelFloating defaults to false and persists', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = AppSettings();
    addTearDown(settings.dispose);

    await settings.ensureCoreLoaded();

    expect(settings.developerPanelFloating, isFalse);

    await settings.setDeveloperPanelFloating(true);
    expect(settings.developerPanelFloating, isTrue);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('developer_panel_floating'), isTrue);

    await settings.setDeveloperPanelFloating(false);
    expect(settings.developerPanelFloating, isFalse);
    expect(preferences.getBool('developer_panel_floating'), isFalse);
  });

  test(
    'developerPanelFloating does not notify when value is unchanged',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = AppSettings();
      addTearDown(settings.dispose);

      await settings.ensureCoreLoaded();

      var notifications = 0;
      settings.addListener(() => notifications++);

      await settings.setDeveloperPanelFloating(false);
      expect(notifications, 0);

      await settings.setDeveloperPanelFloating(true);
      expect(notifications, 1);
    },
  );
}
