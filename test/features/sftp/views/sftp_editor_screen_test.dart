import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ssh_mobile/features/sftp/views/sftp_editor_screen.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('loads once with configured limit and exposes editor tools', (
    tester,
  ) async {
    final loadGate = Completer<String>();
    var loadCalls = 0;
    int? receivedLimit;
    final settings = _TestAppSettings(
      language: AppLanguage.en,
      editLimitBytes: 123456,
    );
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      _editorHost(
        settings: settings,
        readText: (entry, maxBytes) {
          loadCalls += 1;
          receivedLimit = maxBytes;
          return loadGate.future;
        },
      ),
    );
    await _openEditor(tester, settle: false);

    expect(loadCalls, 1);
    expect(receivedLimit, 123456);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('sftp-editor-loading'))),
      matchesSemantics(label: 'Loading remote file…', isLiveRegion: true),
    );

    loadGate.complete('alpha\nbeta');
    await tester.pumpAndSettle();

    final textField = tester.widget<TextField>(
      find.byKey(const ValueKey('sftp-editor-text-field')),
    );
    expect(textField.controller?.text, 'alpha\nbeta');
    expect(textField.autocorrect, isFalse);
    expect(textField.enableSuggestions, isFalse);
    expect(textField.smartDashesType, SmartDashesType.disabled);
    expect(textField.smartQuotesType, SmartQuotesType.disabled);
    expect(loadCalls, 1);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('sftp-editor-path'))).label,
      'Remote path: /etc/ssh/sshd_config',
    );
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('sftp-editor-save-status')))
          .label,
      'All changes saved',
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('sftp-editor-line-wrap'))),
      matchesSemantics(
        label: 'Disable line wrap',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasToggledState: true,
        isToggled: true,
        hasTapAction: true,
      ),
    );

    for (final key in const [
      ValueKey('sftp-editor-back'),
      ValueKey('sftp-editor-save'),
      ValueKey('sftp-editor-font-decrease'),
      ValueKey('sftp-editor-font-increase'),
      ValueKey('sftp-editor-line-wrap'),
    ]) {
      expect(tester.getSize(find.byKey(key)).height, greaterThanOrEqualTo(48));
    }

    await tester.tap(find.byKey(const ValueKey('sftp-editor-font-decrease')));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('sftp-editor-text-field')),
          )
          .style
          ?.fontSize,
      13,
    );
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('sftp-editor-font-slider')))
          .value,
      contains('13'),
    );

    await tester.tap(find.byKey(const ValueKey('sftp-editor-line-wrap')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('sftp-editor-unwrapped-canvas')),
      findsOneWidget,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('sftp-editor-unwrapped-canvas')))
          .width,
      greaterThanOrEqualTo(1600),
    );
    final initialCanvasWidth = tester
        .getSize(find.byKey(const ValueKey('sftp-editor-unwrapped-canvas')))
        .width;
    await tester.enterText(
      find.byKey(const ValueKey('sftp-editor-text-field')),
      'dirty',
    );
    await tester.pump();
    expect(
      tester
          .getSize(find.byKey(const ValueKey('sftp-editor-unwrapped-canvas')))
          .width,
      initialCanvasWidth,
    );
    await tester.enterText(
      find.byKey(const ValueKey('sftp-editor-text-field')),
      List.filled(220, 'x').join(),
    );
    await tester.pump();
    expect(
      tester
          .getSize(find.byKey(const ValueKey('sftp-editor-unwrapped-canvas')))
          .width,
      greaterThan(initialCanvasWidth),
    );
    await tester.pump(const Duration(milliseconds: 250));
    final asciiCanvasWidth = tester
        .getSize(find.byKey(const ValueKey('sftp-editor-unwrapped-canvas')))
        .width;
    await tester.enterText(
      find.byKey(const ValueKey('sftp-editor-text-field')),
      List.filled(120, '界').join(),
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      tester
          .getSize(find.byKey(const ValueKey('sftp-editor-unwrapped-canvas')))
          .width,
      greaterThan(asciiCanvasWidth),
    );
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('sftp-editor-line-wrap')))
          .flagsCollection
          .isToggled,
      Tristate.isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('plain edit always asks before leaving and discard exits', (
    tester,
  ) async {
    final settings = _TestAppSettings(language: AppLanguage.zh);
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      _editorHost(settings: settings, readText: (_, _) async => '原始内容'),
    );
    await _openEditor(tester);

    await tester.enterText(
      find.byKey(const ValueKey('sftp-editor-text-field')),
      '修改后的内容',
    );
    await tester.pump();
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('sftp-editor-save-status')))
          .label,
      '有未保存的修改',
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('sftp-editor-save'))),
      matchesSemantics(
        label: '保存远程文件',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('放弃修改？'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sftp-editor-keep-editing')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('sftp-editor-text-field')),
      findsOneWidget,
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sftp-editor-discard')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('open-sftp-editor')), findsOneWidget);
    expect(find.text('editor-result:null'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pristine file leaves without a discard prompt', (tester) async {
    final settings = _TestAppSettings(language: AppLanguage.en);
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      _editorHost(settings: settings, readText: (_, _) async => 'unchanged'),
    );
    await _openEditor(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('Discard changes?'), findsNothing);
    expect(find.text('editor-result:null'), findsOneWidget);
  });

  testWidgets('saving locks editing and back until exact snapshot succeeds', (
    tester,
  ) async {
    final saveGate = Completer<void>();
    var saveCalls = 0;
    String? savedText;
    int? receivedLimit;
    final settings = _TestAppSettings(
      language: AppLanguage.en,
      editLimitBytes: 654321,
    );
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      _editorHost(
        settings: settings,
        readText: (_, _) async => 'before',
        saveText: (entry, text, maxBytes) {
          saveCalls += 1;
          savedText = text;
          receivedLimit = maxBytes;
          return saveGate.future;
        },
      ),
    );
    await _openEditor(tester);
    await tester.enterText(
      find.byKey(const ValueKey('sftp-editor-text-field')),
      'after\nwith another line',
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('sftp-editor-save')));
    await tester.pump();
    expect(saveCalls, 1);
    expect(savedText, 'after\nwith another line');
    expect(receivedLimit, 654321);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('sftp-editor-text-field')),
          )
          .readOnly,
      isTrue,
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('sftp-editor-save'))).label,
      'Saving remote file…',
    );

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('sftp-editor-text-field')),
      findsOneWidget,
    );
    expect(find.text('Discard changes?'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('sftp-editor-save')),
      warnIfMissed: false,
    );
    expect(saveCalls, 1);

    saveGate.complete();
    await tester.pumpAndSettle();
    expect(find.text('editor-result:true'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('save failure is safe, stays dirty, and can retry', (
    tester,
  ) async {
    var saveCalls = 0;
    final settings = _TestAppSettings(language: AppLanguage.en);
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      _editorHost(
        settings: settings,
        readText: (_, _) async => 'before',
        saveText: (_, _, _) async {
          saveCalls += 1;
          if (saveCalls == 1) {
            throw StateError('token=save-secret');
          }
        },
      ),
    );
    await _openEditor(tester);
    await tester.enterText(
      find.byKey(const ValueKey('sftp-editor-text-field')),
      'after',
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('sftp-editor-save')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Could not save this file. Check the connection and try again.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('save-secret'), findsNothing);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('sftp-editor-text-field')),
          )
          .readOnly,
      isFalse,
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sftp-editor-keep-editing')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('sftp-editor-save')));
    await tester.pumpAndSettle();
    expect(saveCalls, 2);
    expect(find.text('editor-result:true'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new input arriving after save snapshot remains in editor', (
    tester,
  ) async {
    final firstSaveGate = Completer<void>();
    final secondSaveGate = Completer<void>();
    var saveCalls = 0;
    final savedTexts = <String>[];
    final settings = _TestAppSettings(language: AppLanguage.en);
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      _editorHost(
        settings: settings,
        readText: (_, _) async => 'before',
        saveText: (_, text, _) {
          saveCalls += 1;
          savedTexts.add(text);
          return switch (saveCalls) {
            1 => firstSaveGate.future,
            2 => secondSaveGate.future,
            _ => Future.value(),
          };
        },
      ),
    );
    await _openEditor(tester);
    final textFieldFinder = find.byKey(
      const ValueKey('sftp-editor-text-field'),
    );
    await tester.enterText(textFieldFinder, 'snapshot');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('sftp-editor-save')));
    await tester.pump();

    tester.widget<TextField>(textFieldFinder).controller?.text = 'newer input';
    firstSaveGate.complete();
    await tester.pumpAndSettle();

    expect(saveCalls, 1);
    expect(savedTexts, ['snapshot']);
    expect(textFieldFinder, findsOneWidget);
    expect(
      find.text('Earlier changes were saved. New edits are still unsaved.'),
      findsOneWidget,
    );
    expect(
      tester.widget<TextField>(textFieldFinder).controller?.text,
      'newer input',
    );

    await tester.tap(find.byKey(const ValueKey('sftp-editor-save')));
    await tester.pump();
    final textField = tester.widget<TextField>(textFieldFinder);
    tester.binding.addPostFrameCallback((_) {
      textField.controller?.text = 'post-frame input';
      textField.onChanged?.call('post-frame input');
    });
    secondSaveGate.complete();
    await tester.pumpAndSettle();
    expect(savedTexts, ['snapshot', 'newer input']);
    expect(textFieldFinder, findsOneWidget);
    expect(
      tester.widget<TextField>(textFieldFinder).controller?.text,
      'post-frame input',
    );
    expect(
      find.text('Earlier changes were saved. New edits are still unsaved.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('sftp-editor-save')));
    await tester.pumpAndSettle();
    expect(savedTexts, ['snapshot', 'newer input', 'post-frame input']);
    expect(find.text('editor-result:true'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('oversized save gives a specific safe limit message', (
    tester,
  ) async {
    final settings = _TestAppSettings(
      language: AppLanguage.en,
      editLimitBytes: 512 * 1024,
    );
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      _editorHost(
        settings: settings,
        readText: (_, _) async => 'before',
        saveText: (_, _, maxBytes) async {
          throw SftpTextSizeLimitException(
            actualBytes: maxBytes + 1,
            maxBytes: maxBytes,
          );
        },
      ),
    );
    await _openEditor(tester);
    await tester.enterText(
      find.byKey(const ValueKey('sftp-editor-text-field')),
      'after',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('sftp-editor-save')));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'This file is larger than the 512 KB edit limit. '
        'Reduce its content before saving.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('524289'), findsNothing);
    expect(
      find.byKey(const ValueKey('sftp-editor-text-field')),
      findsOneWidget,
    );
  });

  testWidgets('load error hides raw details and retry recovers', (
    tester,
  ) async {
    var loadCalls = 0;
    final settings = _TestAppSettings(language: AppLanguage.en);
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      _editorHost(
        settings: settings,
        readText: (_, _) async {
          loadCalls += 1;
          if (loadCalls == 1) {
            throw StateError('password=load-secret');
          }
          return 'recovered';
        },
      ),
    );
    await _openEditor(tester);

    expect(find.text('Could not open this file'), findsOneWidget);
    expect(find.textContaining('load-secret'), findsNothing);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('sftp-editor-load-error'))),
      matchesSemantics(
        label:
            'Could not open this file. Check the SFTP connection and file permissions, then try again.',
        isLiveRegion: true,
      ),
    );
    final retry = find.byKey(const ValueKey('sftp-editor-retry'));
    expect(tester.getSize(retry).height, greaterThanOrEqualTo(48));

    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(loadCalls, 2);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('sftp-editor-text-field')),
          )
          .controller
          ?.text,
      'recovered',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('late load completion after leaving never touches disposal', (
    tester,
  ) async {
    final loadGate = Completer<String>();
    final settings = _TestAppSettings(language: AppLanguage.en);
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      _editorHost(settings: settings, readText: (_, _) => loadGate.future),
    );
    await _openEditor(tester, settle: false);

    await tester.tap(find.byKey(const ValueKey('sftp-editor-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('open-sftp-editor')), findsOneWidget);

    loadGate.complete('too late');
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('320dp at 200 percent remains usable without overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final settings = _TestAppSettings(language: AppLanguage.en);
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      _editorHost(
        settings: settings,
        textScale: 2,
        entry: const SftpEntry(
          connectionId: 'server-1',
          name: 'a-very-long-production-configuration-file.conf',
          path:
              '/srv/production/services/ssh/configuration/a-very-long-production-configuration-file.conf',
          lowerName: 'a-very-long-production-configuration-file.conf',
          isDirectory: false,
          isLink: false,
          sizeLabel: '2 KB',
        ),
        readText: (_, _) async => 'server {\n  listen 22;\n}',
      ),
    );
    await _openEditor(tester);

    expect(
      find.byKey(const ValueKey('sftp-editor-file-summary')),
      findsNothing,
    );
    final compactSummary = find.byKey(
      const ValueKey('sftp-editor-compact-summary'),
    );
    expect(compactSummary, findsOneWidget);
    expect(
      tester.getSemantics(compactSummary).label,
      contains('Remote path: /srv/production/services/ssh/configuration/'),
    );
    expect(find.byKey(const ValueKey('sftp-editor-toolbar')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sftp-editor-text-field')),
      findsOneWidget,
    );
    for (final key in const [
      ValueKey('sftp-editor-back'),
      ValueKey('sftp-editor-save'),
      ValueKey('sftp-editor-font-decrease'),
      ValueKey('sftp-editor-font-increase'),
      ValueKey('sftp-editor-line-wrap'),
    ]) {
      expect(tester.getSize(find.byKey(key)).height, greaterThanOrEqualTo(48));
    }
    await tester.enterText(
      find.byKey(const ValueKey('sftp-editor-text-field')),
      'changed',
    );
    await tester.pump();
    expect(
      tester.getSemantics(compactSummary).label,
      contains('Unsaved changes'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('short landscape respects asymmetric safe insets', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final settings = _TestAppSettings(language: AppLanguage.zh);
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      _editorHost(
        settings: settings,
        textScale: 1.3,
        safePadding: const EdgeInsets.fromLTRB(42, 0, 18, 12),
        readText: (_, _) async => '横屏内容',
      ),
    );
    await _openEditor(tester);

    final editorRect = tester.getRect(
      find.byKey(const ValueKey('sftp-editor-surface')),
    );
    expect(editorRect.left, greaterThanOrEqualTo(62));
    expect(editorRect.right, lessThanOrEqualTo(962));
    expect(editorRect.bottom, lessThanOrEqualTo(348));
    expect(
      find.byKey(const ValueKey('sftp-editor-file-summary')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}

const _defaultEntry = SftpEntry(
  connectionId: 'server-1',
  name: 'sshd_config',
  path: '/etc/ssh/sshd_config',
  lowerName: 'sshd_config',
  isDirectory: false,
  isLink: false,
  sizeLabel: '1 KB',
);

Widget _editorHost({
  required AppSettings settings,
  required SftpEditorReadText readText,
  SftpEditorSaveText? saveText,
  SftpEntry entry = _defaultEntry,
  double textScale = 1,
  EdgeInsets safePadding = EdgeInsets.zero,
}) {
  return ChangeNotifierProvider<AppSettings>.value(
    value: settings,
    child: MaterialApp(
      theme: AppTheme.lightThemeFor(),
      builder: (context, child) {
        final media = MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          padding: safePadding,
          viewPadding: safePadding,
        );
        return MediaQuery(data: media, child: child!);
      },
      home: _EditorLauncher(
        entry: entry,
        readText: readText,
        saveText: saveText ?? (_, _, _) async {},
      ),
    ),
  );
}

Future<void> _openEditor(WidgetTester tester, {bool settle = true}) async {
  await tester.tap(find.byKey(const ValueKey('open-sftp-editor')));
  await tester.pump();
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 400));
  }
}

class _EditorLauncher extends StatefulWidget {
  const _EditorLauncher({
    required this.entry,
    required this.readText,
    required this.saveText,
  });

  final SftpEntry entry;
  final SftpEditorReadText readText;
  final SftpEditorSaveText saveText;

  @override
  State<_EditorLauncher> createState() => _EditorLauncherState();
}

class _EditorLauncherState extends State<_EditorLauncher> {
  String _result = 'unset';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              key: const ValueKey('open-sftp-editor'),
              onPressed: _open,
              child: const Text('Open editor'),
            ),
            Text('editor-result:$_result'),
          ],
        ),
      ),
    );
  }

  Future<void> _open() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => SftpEditorScreen.forTesting(
          entry: widget.entry,
          readTextForTesting: widget.readText,
          saveTextForTesting: widget.saveText,
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _result = result?.toString() ?? 'null');
  }
}

class _TestAppSettings extends AppSettings {
  _TestAppSettings({
    required this.language,
    this.editLimitBytes = AppSettings.defaultSftpTextEditLimitBytes,
  });

  @override
  final AppLanguage language;
  final int editLimitBytes;

  @override
  int get sftpTextEditLimitBytes => editLimitBytes;
}
