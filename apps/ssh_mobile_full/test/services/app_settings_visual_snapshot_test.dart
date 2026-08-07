import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ssh_mobile/services/app_settings.dart';
import 'package:app_ui/app_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('core preference loading notifies visual settings listeners', () async {
    SharedPreferences.setMockInitialValues({
      'theme_mode': 'dark',
      'color_palette': 'ocean',
    });
    final settings = AppSettings();
    var notifications = 0;
    settings.addListener(() => notifications++);

    await settings.ensureCoreLoaded();

    expect(settings.themeMode, ThemeMode.dark);
    expect(settings.colorPalette, AppColorPalette.ocean);
    expect(notifications, 1);
    settings.dispose();
  });

  testWidgets('non-visual settings do not rebuild the app theme shell', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = AppSettings();
    var builds = 0;

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: MaterialApp(home: _VisualSettingsProbe(onBuild: () => builds++)),
      ),
    );
    expect(builds, 1);

    await settings.setTerminalFontFamily('Consolas');
    await tester.pump();
    expect(builds, 1);

    settings.setThemeMode(ThemeMode.dark);
    await tester.pump();
    expect(builds, 2);

    await settings.setColorPalette(AppColorPalette.emerald);
    await tester.pump();
    expect(builds, 3);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('color_palette'), 'emerald');

    await tester.pump(const Duration(milliseconds: 200));
  });
}

class _VisualSettingsProbe extends StatelessWidget {
  const _VisualSettingsProbe({required this.onBuild});

  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context) {
    context.select<AppSettings, AppVisualSettingsSnapshot>(
      (settings) => settings.visualSettings,
    );
    onBuild();
    return const SizedBox.shrink();
  }
}
