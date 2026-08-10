import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:feature_sftp/feature_sftp.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _TestSftpSettings settings;

  setUp(() => settings = _TestSftpSettings());

  tearDown(() => settings.dispose());

  Widget buildSubject() {
    return ListenableProvider<SftpSettingsPort>.value(
      value: settings,
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

    final before = settings.sftpDownloadLimitBytes;
    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), '600');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(settings.sftpDownloadLimitBytes, 600 * 1024 * 1024);
    expect(settings.sftpDownloadLimitBytes, isNot(before));
  });

  testWidgets('an out-of-range limit shows an error and does not persist', (
    tester,
  ) async {
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    final before = settings.sftpDownloadLimitBytes;
    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '99999');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(settings.sftpDownloadLimitBytes, before);
    // The dialog stays open with an error message.
    expect(find.byType(TextField), findsOneWidget);
  });
}

final class _TestSftpSettings extends ChangeNotifier
    implements SftpSettingsPort {
  @override
  SftpLanguage language = SftpLanguage.english;

  @override
  int sftpDownloadLimitBytes = 512 * 1024 * 1024;

  @override
  int sftpTextPreviewLimitBytes = 2 * 1024 * 1024;

  @override
  int sftpRichPreviewLimitBytes = 20 * 1024 * 1024;

  @override
  int sftpTextEditLimitBytes = 512 * 1024;

  @override
  Future<void> setSftpDownloadLimitBytes(int bytes) async {
    sftpDownloadLimitBytes = bytes;
    notifyListeners();
  }

  @override
  Future<void> setSftpTextPreviewLimitBytes(int bytes) async {
    sftpTextPreviewLimitBytes = bytes;
    notifyListeners();
  }

  @override
  Future<void> setSftpRichPreviewLimitBytes(int bytes) async {
    sftpRichPreviewLimitBytes = bytes;
    notifyListeners();
  }

  @override
  Future<void> setSftpTextEditLimitBytes(int bytes) async {
    sftpTextEditLimitBytes = bytes;
    notifyListeners();
  }
}
