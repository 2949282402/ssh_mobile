import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ssh_mobile/features/terminal/views/terminal_settings_screen.dart';
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

  tearDown(() => appSettings.dispose());

  Widget buildSubject() {
    return ChangeNotifierProvider<AppSettings>.value(
      value: appSettings,
      child: const MaterialApp(home: TerminalSettingsScreen()),
    );
  }

  testWidgets('renders the theme selector and the font field', (tester) async {
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('changing the terminal theme persists to AppSettings', (
    tester,
  ) async {
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Monokai').last);
    await tester.pumpAndSettle();

    expect(appSettings.terminalThemeId, 'monokai');
  });

  testWidgets('typing a custom font family persists after the debounce', (
    tester,
  ) async {
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'JetBrains Mono');
    // The onChanged handler debounces persistence by 400 ms.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(appSettings.terminalFontFamily, 'JetBrains Mono');
  });
}
