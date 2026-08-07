import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ssh_mobile/features/terminal/views/terminal_copy_screen.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('preserves the exact read-only snapshot and scrolls to the end', (
    tester,
  ) async {
    final settings = _TestAppSettings(AppLanguage.zh);
    addTearDown(settings.dispose);
    final text = <String>[
      for (var index = 0; index < 180; index += 1)
        '第 $index 行 — terminal output  ',
      '最后一行  ',
      '',
    ].join('\n');

    await tester.pumpWidget(
      _copyHost(
        settings: settings,
        title: '生产环境终端',
        text: text,
        clipboardWriter: (_) async {},
      ),
    );
    await _openCopyScreen(tester);

    final textField = tester.widget<TextField>(
      find.byKey(const ValueKey('terminal-copy-text-field')),
    );
    expect(textField.controller?.text, text);
    expect(textField.readOnly, isTrue);
    expect(textField.expands, isTrue);
    expect(textField.minLines, isNull);
    expect(textField.maxLines, isNull);
    expect(textField.enableInteractiveSelection, isNot(false));
    expect(textField.autocorrect, isFalse);
    expect(textField.enableSuggestions, isFalse);
    expect(textField.smartDashesType, SmartDashesType.disabled);
    expect(textField.smartQuotesType, SmartQuotesType.disabled);

    final scrollController = textField.scrollController!;
    expect(scrollController.position.maxScrollExtent, greaterThan(0));
    expect(
      scrollController.offset,
      moreOrLessEquals(
        scrollController.position.maxScrollExtent,
        epsilon: 0.01,
      ),
    );
    expect(find.textContaining('${text.length} 个字符'), findsOneWidget);
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('terminal-copy-output')))
          .label,
      '终端输出',
    );
    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey('terminal-copy-read-only-status')),
          )
          .label,
      '只读',
    );

    for (final key in const [
      ValueKey('terminal-copy-close'),
      ValueKey('terminal-copy-copy-all'),
    ]) {
      final size = tester.getSize(find.byKey(key));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('copy is single-flight, locks return, and exits after success', (
    tester,
  ) async {
    final settings = _TestAppSettings(AppLanguage.en);
    addTearDown(settings.dispose);
    final copyGate = Completer<void>();
    addTearDown(() {
      if (!copyGate.isCompleted) copyGate.complete();
    });
    const text = '  exact output\nwith trailing spaces  \n';
    final received = <String>[];

    await tester.pumpWidget(
      _copyHost(
        settings: settings,
        title: 'Production terminal',
        text: text,
        clipboardWriter: (value) {
          received.add(value);
          return copyGate.future;
        },
      ),
    );
    await _openCopyScreen(tester);

    final copyAction = find.byKey(const ValueKey('terminal-copy-copy-all'));
    await tester.tap(copyAction);
    await tester.tap(copyAction);
    expect(received, [text]);
    await tester.pump();

    expect(
      tester.getSemantics(copyAction),
      matchesSemantics(
        label: 'Copying output...',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
        isLiveRegion: true,
      ),
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('terminal-copy-close')))
          .onPressed,
      isNull,
    );

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('terminal-copy-output-surface')),
      findsOneWidget,
    );
    expect(find.text('copy-result:unset'), findsNothing);

    copyGate.complete();
    await tester.pumpAndSettle();
    expect(find.text('copy-result:true'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('copy failure stays on the page with safe retry feedback', (
    tester,
  ) async {
    final settings = _TestAppSettings(AppLanguage.en);
    addTearDown(settings.dispose);
    var attempts = 0;

    await tester.pumpWidget(
      _copyHost(
        settings: settings,
        title: 'Staging terminal',
        text: 'visible output',
        clipboardWriter: (_) {
          attempts += 1;
          if (attempts == 1) {
            throw StateError('token=copy-secret');
          }
          return Future.value();
        },
      ),
    );
    await _openCopyScreen(tester);

    final copyAction = find.byKey(const ValueKey('terminal-copy-copy-all'));
    await tester.tap(copyAction);
    await tester.pumpAndSettle();

    expect(attempts, 1);
    expect(find.text('Failed to copy output. Retry.'), findsOneWidget);
    expect(find.textContaining('copy-secret'), findsNothing);
    expect(
      find.byKey(const ValueKey('terminal-copy-output-surface')),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(copyAction),
      matchesSemantics(
        label: 'Copy all',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );

    await tester.tap(copyAction);
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('copy-result:true'), findsOneWidget);
    expect(find.text('Failed to copy output. Retry.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late clipboard completion never touches disposed state', (
    tester,
  ) async {
    final settings = _TestAppSettings(AppLanguage.en);
    addTearDown(settings.dispose);
    final copyGate = Completer<void>();
    addTearDown(() {
      if (!copyGate.isCompleted) copyGate.complete();
    });

    await tester.pumpWidget(
      _copyHost(
        settings: settings,
        title: 'Disposable terminal',
        text: 'pending output',
        clipboardWriter: (_) => copyGate.future,
      ),
    );
    await _openCopyScreen(tester);
    await tester.tap(find.byKey(const ValueKey('terminal-copy-copy-all')));
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    copyGate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact Chinese layout survives 320dp at 200 percent text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = _TestAppSettings(AppLanguage.zh);
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      _copyHost(
        settings: settings,
        title: '名称非常长且必须在窄屏幕上稳定显示的生产环境终端窗口',
        text: List.generate(80, (index) => '输出第 $index 行').join('\n'),
        clipboardWriter: (_) async {},
        textScale: 2,
        safePadding: const EdgeInsets.only(bottom: 24),
        visualDensity: const VisualDensity(horizontal: -0.5, vertical: -0.5),
      ),
    );
    await _openCopyScreen(tester);

    expect(
      find.byKey(const ValueKey('terminal-copy-compact-summary')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('terminal-copy-summary')), findsNothing);
    final outputRect = tester.getRect(
      find.byKey(const ValueKey('terminal-copy-output-surface')),
    );
    expect(outputRect.bottom, lessThanOrEqualTo(544));
    for (final key in const [
      ValueKey('terminal-copy-close'),
      ValueKey('terminal-copy-copy-all'),
    ]) {
      final size = tester.getSize(find.byKey(key));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  });

  testWidgets('short landscape layout respects asymmetric safe areas', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = _TestAppSettings(AppLanguage.en);
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      _copyHost(
        settings: settings,
        title: 'Landscape terminal',
        text: 'one\ntwo\nthree',
        clipboardWriter: (_) async {},
        textScale: 1.3,
        safePadding: const EdgeInsets.fromLTRB(42, 0, 18, 12),
      ),
    );
    await _openCopyScreen(tester);

    expect(
      find.byKey(const ValueKey('terminal-copy-compact-summary')),
      findsOneWidget,
    );
    final contentRect = tester.getRect(
      find.byKey(const ValueKey('terminal-copy-content')),
    );
    expect(contentRect.left, greaterThanOrEqualTo(62));
    expect(contentRect.right, lessThanOrEqualTo(962));
    expect(contentRect.bottom, lessThanOrEqualTo(348));
    expect(find.textContaining('3 lines'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  });
}

Widget _copyHost({
  required AppSettings settings,
  required String title,
  required String text,
  required TerminalClipboardWriter clipboardWriter,
  double textScale = 1,
  EdgeInsets safePadding = EdgeInsets.zero,
  VisualDensity visualDensity = VisualDensity.standard,
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
        return MediaQuery(
          data: media,
          child: Theme(
            data: Theme.of(context).copyWith(visualDensity: visualDensity),
            child: child!,
          ),
        );
      },
      home: _CopyLauncher(
        title: title,
        text: text,
        clipboardWriter: clipboardWriter,
      ),
    ),
  );
}

Future<void> _openCopyScreen(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open-terminal-copy')));
  await tester.pumpAndSettle();
}

class _CopyLauncher extends StatefulWidget {
  const _CopyLauncher({
    required this.title,
    required this.text,
    required this.clipboardWriter,
  });

  final String title;
  final String text;
  final TerminalClipboardWriter clipboardWriter;

  @override
  State<_CopyLauncher> createState() => _CopyLauncherState();
}

class _CopyLauncherState extends State<_CopyLauncher> {
  String _result = 'unset';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              key: const ValueKey('open-terminal-copy'),
              onPressed: _open,
              child: const Text('Open terminal copy'),
            ),
            Text('copy-result:$_result'),
          ],
        ),
      ),
    );
  }

  Future<void> _open() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => TerminalCopyScreen(
          title: widget.title,
          text: widget.text,
          clipboardWriter: widget.clipboardWriter,
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _result = result?.toString() ?? 'null');
  }
}

class _TestAppSettings extends AppSettings {
  _TestAppSettings(this._testLanguage);

  final AppLanguage _testLanguage;

  @override
  AppLanguage get language => _testLanguage;
}
