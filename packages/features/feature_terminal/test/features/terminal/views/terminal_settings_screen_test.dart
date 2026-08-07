import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:feature_terminal/feature_terminal.dart';

import '../../../fakes/terminal_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeTerminalSettings settings;

  setUp(() {
    settings = FakeTerminalSettings(language: 'en');
  });

  tearDown(() => settings.dispose());

  Widget buildSubject() {
    return ListenableProvider<TerminalSettingsPort>.value(
      value: settings,
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

    expect(settings.terminalThemeId, 'monokai');
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

    expect(settings.terminalFontFamily, 'JetBrains Mono');
  });
}
