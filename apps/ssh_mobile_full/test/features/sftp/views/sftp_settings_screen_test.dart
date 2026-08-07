import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ssh_mobile/features/sftp/views/sftp_settings_screen.dart';
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
      child: const MaterialApp(home: SftpSettingsScreen()),
    );
  }

  testWidgets('renders the four SFTP limit tiles', (tester) async {
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    expect(find.byType(ListTile), findsNWidgets(4));
  });

  testWidgets('editing the download limit persists to AppSettings', (
    tester,
  ) async {
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    final before = appSettings.sftpDownloadLimitBytes;
    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), '600');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(appSettings.sftpDownloadLimitBytes, 600 * 1024 * 1024);
    expect(appSettings.sftpDownloadLimitBytes, isNot(before));
  });

  testWidgets('an out-of-range limit shows an error and does not persist', (
    tester,
  ) async {
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    final before = appSettings.sftpDownloadLimitBytes;
    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '99999');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(appSettings.sftpDownloadLimitBytes, before);
    // The dialog stays open with an error message.
    expect(find.byType(TextField), findsOneWidget);
  });
}
