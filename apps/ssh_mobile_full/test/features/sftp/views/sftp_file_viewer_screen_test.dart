import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:feature_sftp/feature_sftp.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:provider/provider.dart';
import 'package:app_ui/app_ui.dart';

part 'sftp_file_viewer_screen_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('image render budget rejects hostile geometry and animation work', () {
    expect(sftpViewerImageMetadataWithinBudget(5000, 4000, 1), isTrue);
    expect(sftpViewerImageMetadataWithinBudget(1, 16385, 1), isFalse);
    expect(sftpViewerImageMetadataWithinBudget(6000, 5000, 1), isFalse);
    expect(sftpViewerImageMetadataWithinBudget(1200, 800, 121), isFalse);
    expect(sftpViewerImageMetadataWithinBudget(1200, 800, 100), isTrue);
    expect(sftpViewerImageMetadataWithinBudget(5000, 4000, 6), isFalse);
  });

  testWidgets('text preview loads once with configured limit and semantics', (
    tester,
  ) async {
    final gate = Completer<Uint8List>();
    final settings = _TestAppSettings(
      language: SftpLanguage.english,
      textLimitBytes: 123456,
    );
    addTearDown(settings.dispose);
    var readCalls = 0;
    int? receivedLimit;

    await tester.pumpWidget(
      _viewerHost(
        settings: settings,
        entry: _entry(name: 'service.DART', path: '/srv/service.DART'),
        readBytes: (entry, maxBytes, {required bool bypassCache}) {
          readCalls += 1;
          receivedLimit = maxBytes;
          return gate.future;
        },
      ),
    );
    await _openViewer(tester, settle: false);

    expect(readCalls, 1);
    expect(receivedLimit, 123456);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('sftp-viewer-loading'))),
      matchesSemantics(label: 'Loading file preview…', isLiveRegion: true),
    );

    gate.complete(Uint8List.fromList(utf8.encode('alpha\nbeta')));
    await _pumpUntilPreviewLoaded(tester);

    expect(find.text('alpha\nbeta'), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('sftp-viewer-path'))).label,
      contains('Remote path: /srv/service.DART'),
    );
    expect(find.byKey(const ValueKey('sftp-viewer-text')), findsOneWidget);
    expect(find.byType(SelectableText), findsWidgets);
    expect(
      tester.getSize(find.byKey(const ValueKey('sftp-viewer-back'))).height,
      greaterThanOrEqualTo(48),
    );
    final appBarTitle = find.descendant(
      of: find.byType(AppBar),
      matching: find.text('service.DART'),
    );
    final titleWidget = tester.widget<Text>(appBarTitle);
    final appBarTheme = Theme.of(
      tester.element(find.byType(AppBar)),
    ).appBarTheme;
    expect(titleWidget.style, appBarTheme.titleTextStyle);
    expect(readCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('in-memory text preview keeps a hard safety ceiling', (
    tester,
  ) async {
    final settings = _TestAppSettings(
      language: SftpLanguage.english,
      textLimitBytes: 64 * 1024 * 1024,
    );
    addTearDown(settings.dispose);
    int? receivedLimit;

    await tester.pumpWidget(
      _viewerHost(
        settings: settings,
        entry: _entry(name: 'large-config.log'),
        readBytes: (_, maxBytes, {required bool bypassCache}) async {
          receivedLimit = maxBytes;
          return Uint8List.fromList(utf8.encode('bounded'));
        },
      ),
    );
    await _openViewer(tester);

    expect(receivedLimit, 8 * 1024 * 1024);
    expect(find.text('bounded'), findsOneWidget);
  });

  testWidgets('markdown blocks remote images and mode changes do not reload', (
    tester,
  ) async {
    const markdown = r'''# Status
![chart](https://example.com/chart.png)
[Runbook](https://example.com/runbook)
[outer [inner]](https://example.com/nested)
`[inline](https://code.example/inline)`
``[multi](https://code.example/multi)``
```dart
final sample = '[fenced](https://code.example/fenced)';
```
~~~
[tilde](https://plain.example/tilde)
~~~
    [indented](https://plain.example/indented)
''';
    final settings = _TestAppSettings(language: SftpLanguage.english);
    addTearDown(settings.dispose);
    var readCalls = 0;

    await tester.pumpWidget(
      _viewerHost(
        settings: settings,
        entry: _entry(name: 'README.MARKDOWN'),
        readBytes: (_, _, {required bool bypassCache}) async {
          readCalls += 1;
          return Uint8List.fromList(utf8.encode(markdown));
        },
      ),
    );
    await _openViewer(tester);

    expect(find.byKey(const ValueKey('sftp-viewer-markdown')), findsOneWidget);
    expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('Runbook'), findsWidgets);
    final markdownWidget = tester.widget<GptMarkdown>(find.byType(GptMarkdown));
    expect(markdownWidget.data, markdown);
    expect(markdownWidget.inlineComponents, isNotNull);
    expect(
      markdownWidget.inlineComponents!.map(
        (component) => component.runtimeType.toString(),
      ),
      isNot(contains('ATagMd')),
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == 'LinkButton',
      ),
      findsNothing,
    );
    expect(readCalls, 1);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('sftp-viewer-mode-toggle')))
          .height,
      greaterThanOrEqualTo(48),
    );

    await tester.tap(find.byKey(const ValueKey('sftp-viewer-mode-source')));
    await tester.pump();

    expect(find.byKey(const ValueKey('sftp-viewer-text')), findsOneWidget);
    expect(find.text(markdown), findsOneWidget);
    expect(readCalls, 1);

    await tester.tap(find.byKey(const ValueKey('sftp-viewer-mode-preview')));
    await tester.pump();
    expect(find.byKey(const ValueKey('sftp-viewer-markdown')), findsOneWidget);
    expect(readCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported file never starts a remote read', (tester) async {
    final settings = _TestAppSettings(language: SftpLanguage.english);
    addTearDown(settings.dispose);
    var readCalls = 0;

    await tester.pumpWidget(
      _viewerHost(
        settings: settings,
        entry: _entry(name: 'archive.zip'),
        readBytes: (_, _, {required bool bypassCache}) async {
          readCalls += 1;
          return Uint8List(0);
        },
      ),
    );
    await _openViewer(tester);

    expect(readCalls, 0);
    expect(
      find.byKey(const ValueKey('sftp-viewer-unsupported')),
      findsOneWidget,
    );
    expect(find.text('No preview available'), findsOneWidget);
    expect(find.byKey(const ValueKey('sftp-viewer-retry')), findsNothing);
  });

  testWidgets('declared oversized file is rejected before remote read', (
    tester,
  ) async {
    final settings = _TestAppSettings(
      language: SftpLanguage.english,
      textLimitBytes: 10 * 1024,
    );
    addTearDown(settings.dispose);
    var readCalls = 0;

    await tester.pumpWidget(
      _viewerHost(
        settings: settings,
        entry: _entry(
          name: 'large.txt',
          size: 10 * 1024 + 1,
          sizeLabel: '10.1 KB',
        ),
        readBytes: (_, _, {required bool bypassCache}) async {
          readCalls += 1;
          return Uint8List(0);
        },
      ),
    );
    await _openViewer(tester);

    expect(readCalls, 0);
    expect(find.byKey(const ValueKey('sftp-viewer-too-large')), findsOneWidget);
    expect(find.textContaining('10 KB'), findsOneWidget);
    expect(find.textContaining('10.1 KB'), findsOneWidget);
    expect(find.byKey(const ValueKey('sftp-viewer-retry')), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('sftp-viewer-close'))).height,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets('returned oversized bytes are rejected by the viewer contract', (
    tester,
  ) async {
    final settings = _TestAppSettings(
      language: SftpLanguage.english,
      textLimitBytes: 4 * 1024,
    );
    addTearDown(settings.dispose);
    var readCalls = 0;

    await tester.pumpWidget(
      _viewerHost(
        settings: settings,
        entry: _entry(name: 'unknown.log'),
        readBytes: (_, _, {required bool bypassCache}) async {
          readCalls += 1;
          return Uint8List(4 * 1024 + 1);
        },
      ),
    );
    await _openViewer(tester);

    expect(readCalls, 1);
    expect(find.byKey(const ValueKey('sftp-viewer-too-large')), findsOneWidget);
    expect(find.textContaining('4 KB'), findsOneWidget);
    expect(find.byKey(const ValueKey('sftp-viewer-retry')), findsNothing);
  });

  testWidgets('load failure is safe and retry is single flight', (
    tester,
  ) async {
    final settings = _TestAppSettings(language: SftpLanguage.english);
    addTearDown(settings.dispose);
    final retryGate = Completer<Uint8List>();
    var readCalls = 0;
    final bypassValues = <bool>[];

    await tester.pumpWidget(
      _viewerHost(
        settings: settings,
        entry: _entry(name: 'retry.txt'),
        readBytes: (_, _, {required bool bypassCache}) {
          readCalls += 1;
          bypassValues.add(bypassCache);
          if (readCalls == 1) {
            return Future<Uint8List>.error(StateError('token=viewer-secret'));
          }
          return retryGate.future;
        },
      ),
    );
    await _openViewer(tester);

    expect(readCalls, 1);
    expect(
      find.byKey(const ValueKey('sftp-viewer-load-error')),
      findsOneWidget,
    );
    expect(find.textContaining('viewer-secret'), findsNothing);
    expect(find.text('Could not load this preview'), findsOneWidget);
    final errorSemantics = tester.getSemantics(
      find.byKey(const ValueKey('sftp-viewer-load-error')),
    );
    expect(errorSemantics.flagsCollection.isLiveRegion, isTrue);
    expect(errorSemantics.label, contains('Could not load this preview'));
    expect(errorSemantics.label, contains('Check the SFTP connection'));

    final retry = find.byKey(const ValueKey('sftp-viewer-retry'));
    await tester.tap(retry);
    await tester.tap(retry);
    expect(readCalls, 2);
    await tester.pump();
    expect(find.byKey(const ValueKey('sftp-viewer-loading')), findsOneWidget);

    retryGate.complete(Uint8List.fromList(utf8.encode('recovered')));
    await _pumpUntilPreviewLoaded(tester);

    expect(find.text('recovered'), findsOneWidget);
    expect(readCalls, 2);
    expect(bypassValues, [false, true]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'late read completion after leaving does not touch disposed state',
    (tester) async {
      final settings = _TestAppSettings(language: SftpLanguage.english);
      addTearDown(settings.dispose);
      final gate = Completer<Uint8List>();

      await tester.pumpWidget(
        _viewerHost(
          settings: settings,
          entry: _entry(name: 'slow.txt'),
          readBytes: (_, _, {required bool bypassCache}) => gate.future,
        ),
      );
      await _openViewer(tester, settle: false);
      expect(find.byKey(const ValueKey('sftp-viewer-loading')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('sftp-viewer-back')));
      await tester.pumpAndSettle();
      gate.complete(Uint8List.fromList(utf8.encode('late')));
      await tester.pump();

      expect(find.byKey(const ValueKey('open-sftp-viewer')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('supported HTML receives a CSP sandbox before remote content', (
    tester,
  ) async {
    const rawHtml = '<img src="https://example.com/tracker.png">';
    final settings = _TestAppSettings(language: SftpLanguage.english);
    addTearDown(settings.dispose);
    String? receivedHtml;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    try {
      await tester.pumpWidget(
        _viewerHost(
          settings: settings,
          entry: _entry(name: 'report.html'),
          readBytes: (_, _, {required bool bypassCache}) async =>
              Uint8List.fromList(utf8.encode(rawHtml)),
          htmlBuilder:
              (
                context,
                sandboxedHtml, {
                required loadingWidget,
                required onError,
              }) {
                receivedHtml = sandboxedHtml;
                return const Center(child: Text('sandboxed-html'));
              },
        ),
      );
      await _openViewer(tester);

      expect(find.byKey(const ValueKey('sftp-viewer-html')), findsOneWidget);
      expect(find.text('sandboxed-html'), findsOneWidget);
      expect(receivedHtml, contains("default-src 'none'"));
      expect(receivedHtml, contains("script-src 'none'"));
      expect(receivedHtml, contains('name="referrer" content="no-referrer"'));
      expect(receivedHtml, contains('name="color-scheme" content="light"'));
      expect(receivedHtml, contains('background: #'));
      expect(
        receivedHtml!.indexOf('Content-Security-Policy'),
        lessThan(receivedHtml!.indexOf('https://')),
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('HTML sandbox receives readable dark theme colors', (
    tester,
  ) async {
    final settings = _TestAppSettings(language: SftpLanguage.english);
    addTearDown(settings.dispose);
    String? receivedHtml;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    try {
      await tester.pumpWidget(
        _viewerHost(
          settings: settings,
          darkMode: true,
          entry: _entry(name: 'dark-report.html'),
          readBytes: (_, _, {required bool bypassCache}) async =>
              Uint8List.fromList(utf8.encode('<p>Readable report</p>')),
          htmlBuilder:
              (
                context,
                sandboxedHtml, {
                required loadingWidget,
                required onError,
              }) {
                receivedHtml = sandboxedHtml;
                return const Center(child: Text('dark-html'));
              },
        ),
      );
      await _openViewer(tester);

      expect(receivedHtml, contains('name="color-scheme" content="dark"'));
      expect(receivedHtml, contains(':root { color-scheme: dark; }'));
      expect(receivedHtml, contains('background: #'));
      expect(receivedHtml, contains('color: #'));
      expect(find.text('dark-html'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'unsupported HTML platform is explicit and source remains usable',
    (tester) async {
      const rawHtml = '<h1>Server report</h1>';
      final settings = _TestAppSettings(language: SftpLanguage.english);
      addTearDown(settings.dispose);
      var readCalls = 0;
      var htmlBuildCalls = 0;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      try {
        await tester.pumpWidget(
          _viewerHost(
            settings: settings,
            entry: _entry(name: 'report.htm'),
            readBytes: (_, _, {required bool bypassCache}) async {
              readCalls += 1;
              return Uint8List.fromList(utf8.encode(rawHtml));
            },
            htmlBuilder:
                (
                  context,
                  sandboxedHtml, {
                  required loadingWidget,
                  required onError,
                }) {
                  htmlBuildCalls += 1;
                  return const SizedBox.shrink();
                },
          ),
        );
        await _openViewer(tester);

        expect(readCalls, 1);
        expect(htmlBuildCalls, 0);
        expect(
          find.byKey(const ValueKey('sftp-viewer-html-unavailable')),
          findsOneWidget,
        );
        expect(find.text('HTML preview is unavailable here'), findsOneWidget);
        expect(
          tester
              .getSize(find.byKey(const ValueKey('sftp-viewer-view-source')))
              .height,
          greaterThanOrEqualTo(48),
        );

        await tester.tap(find.byKey(const ValueKey('sftp-viewer-view-source')));
        await tester.pump();

        expect(find.byKey(const ValueKey('sftp-viewer-text')), findsOneWidget);
        expect(find.text(rawHtml), findsOneWidget);
        expect(readCalls, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('HTML render error is safe and offers source', (tester) async {
    final settings = _TestAppSettings(language: SftpLanguage.english);
    addTearDown(settings.dispose);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    try {
      await tester.pumpWidget(
        _viewerHost(
          settings: settings,
          entry: _entry(name: 'broken.html'),
          readBytes: (_, _, {required bool bypassCache}) async =>
              Uint8List.fromList(utf8.encode('<p>source</p>')),
          htmlBuilder:
              (
                context,
                sandboxedHtml, {
                required loadingWidget,
                required onError,
              }) => onError(context, StateError('html-render-secret')),
        ),
      );
      await _openViewer(tester);

      expect(
        find.byKey(const ValueKey('sftp-viewer-html-error')),
        findsOneWidget,
      );
      expect(find.text('Could not display this preview'), findsOneWidget);
      expect(find.textContaining('html-render-secret'), findsNothing);
      expect(find.text('View source'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('image decode failure can retry to a zoomable image', (
    tester,
  ) async {
    final testImage = await tester.runAsync<ui.Image>(
      () => createTestImage(width: 2, height: 2),
    );
    if (testImage == null) fail('Could not create a test image');
    addTearDown(testImage.dispose);
    final successfulProvider = _SynchronousImageProvider(testImage);
    final settings = _TestAppSettings(
      language: SftpLanguage.english,
      richLimitBytes: 765432,
    );
    addTearDown(settings.dispose);
    var readCalls = 0;
    final receivedLimits = <int>[];
    final bypassValues = <bool>[];

    await tester.pumpWidget(
      _viewerHost(
        settings: settings,
        entry: _entry(name: 'chart.png'),
        readBytes: (_, maxBytes, {required bool bypassCache}) async {
          readCalls += 1;
          receivedLimits.add(maxBytes);
          bypassValues.add(bypassCache);
          return readCalls == 1 ? Uint8List.fromList([1, 2, 3, 4]) : _testPng;
        },
        imageProviderBuilder: (_, _, _) => successfulProvider,
      ),
    );
    await _openViewer(tester);

    expect(
      find.byKey(const ValueKey('sftp-viewer-image-error')),
      findsOneWidget,
    );
    expect(find.text('Could not display this preview'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sftp-viewer-retry')));
    await _pumpUntilFound(
      tester,
      find.byKey(const ValueKey('sftp-viewer-image')),
    );

    expect(find.byKey(const ValueKey('sftp-viewer-image')), findsOneWidget);
    expect(find.byKey(const ValueKey('sftp-viewer-image-error')), findsNothing);
    expect(receivedLimits, [765432, 765432]);
    expect(bypassValues, [false, true]);
    expect(readCalls, 2);
    for (final key in const [
      ValueKey('sftp-viewer-zoom-out'),
      ValueKey('sftp-viewer-zoom-reset'),
      ValueKey('sftp-viewer-zoom-in'),
    ]) {
      expect(tester.getSize(find.byKey(key)).height, greaterThanOrEqualTo(48));
    }
    final imageSemantics = tester.getSemantics(
      find.byKey(const ValueKey('sftp-viewer-image')),
    );
    expect(
      imageSemantics.getSemanticsData().hasAction(ui.SemanticsAction.increase),
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('sftp-viewer-zoom-in')));
    await tester.pump();
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('sftp-viewer-image')))
          .value,
      contains('150%'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('image frame failure hides zoom semantics and controls', (
    tester,
  ) async {
    final settings = _TestAppSettings(language: SftpLanguage.english);
    addTearDown(settings.dispose);
    final failingProvider = MemoryImage(Uint8List.fromList([1, 2, 3, 4]));

    await tester.pumpWidget(
      _viewerHost(
        settings: settings,
        entry: _entry(name: 'corrupt-frame.png'),
        readBytes: (_, _, {required bool bypassCache}) async => _testPng,
        imageProviderBuilder: (_, _, _) => failingProvider,
      ),
    );
    await _openViewer(tester);

    expect(
      find.byKey(const ValueKey('sftp-viewer-image-error')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('sftp-viewer-image')), findsNothing);
    expect(find.byKey(const ValueKey('sftp-viewer-zoom-out')), findsNothing);
    expect(find.byKey(const ValueKey('sftp-viewer-zoom-reset')), findsNothing);
    expect(find.byKey(const ValueKey('sftp-viewer-zoom-in')), findsNothing);
    expect(find.text('Could not display this preview'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote PDF is blocked before reading untrusted bytes', (
    tester,
  ) async {
    final settings = _TestAppSettings(language: SftpLanguage.english);
    addTearDown(settings.dispose);
    var readCalls = 0;

    await tester.pumpWidget(
      _viewerHost(
        settings: settings,
        entry: _entry(name: 'manual.pdf'),
        readBytes: (_, _, {required bool bypassCache}) async {
          readCalls += 1;
          return Uint8List.fromList([37, 80, 68, 70]);
        },
      ),
    );
    await _openViewer(tester);

    expect(readCalls, 0);
    expect(
      find.byKey(const ValueKey('sftp-viewer-pdf-unavailable')),
      findsOneWidget,
    );
    expect(find.text('Remote PDF preview is disabled'), findsOneWidget);
    expect(find.textContaining('trusted reader'), findsOneWidget);
    expect(find.byKey(const ValueKey('sftp-viewer-retry')), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('sftp-viewer-close'))).height,
      greaterThanOrEqualTo(48),
    );
    final semantics = tester.getSemantics(
      find.byKey(const ValueKey('sftp-viewer-pdf-unavailable')),
    );
    expect(semantics.label, contains('Remote PDF preview is disabled'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('320dp at 200 percent remains usable without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final settings = _TestAppSettings(language: SftpLanguage.english);
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      _viewerHost(
        settings: settings,
        textScale: 2,
        entry: _entry(
          name: 'very-long-production-incident-report.markdown',
          path:
              '/srv/releases/2026/very-long-production-incident-report.markdown',
        ),
        readBytes: (_, _, {required bool bypassCache}) async =>
            Uint8List.fromList(utf8.encode('# Report\nHealthy')),
      ),
    );
    await _openViewer(tester);

    expect(
      find.byKey(const ValueKey('sftp-viewer-compact-summary')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('sftp-viewer-file-summary')),
      findsNothing,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('sftp-viewer-preview-surface')))
          .height,
      greaterThan(80),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('sftp-viewer-back'))).height,
      greaterThanOrEqualTo(48),
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('sftp-viewer-mode-toggle')))
          .height,
      greaterThanOrEqualTo(48),
    );

    await tester.tap(find.byKey(const ValueKey('sftp-viewer-mode-source')));
    await tester.pump();
    expect(find.byKey(const ValueKey('sftp-viewer-text')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short landscape respects asymmetric safe insets', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    const safePadding = EdgeInsets.fromLTRB(42, 0, 18, 12);
    final settings = _TestAppSettings(language: SftpLanguage.english);
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      _viewerHost(
        settings: settings,
        textScale: 2,
        safePadding: safePadding,
        entry: _entry(name: 'status.txt', path: '/srv/status.txt'),
        readBytes: (_, _, {required bool bypassCache}) async =>
            Uint8List.fromList(utf8.encode('landscape content')),
      ),
    );
    await _openViewer(tester);

    final content = find.byKey(const ValueKey('sftp-viewer-content'));
    expect(
      find.byKey(const ValueKey('sftp-viewer-compact-summary')),
      findsOneWidget,
    );
    expect(tester.getTopLeft(content).dx, greaterThanOrEqualTo(42));
    expect(tester.getBottomRight(content).dx, lessThanOrEqualTo(982));
    expect(
      tester
          .getSize(find.byKey(const ValueKey('sftp-viewer-preview-surface')))
          .height,
      greaterThan(80),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('language changes update safe error text without reloading', (
    tester,
  ) async {
    final settings = _TestAppSettings(language: SftpLanguage.english);
    addTearDown(settings.dispose);
    var readCalls = 0;

    await tester.pumpWidget(
      _viewerHost(
        settings: settings,
        entry: _entry(name: 'failure.txt'),
        readBytes: (_, _, {required bool bypassCache}) {
          readCalls += 1;
          return Future<Uint8List>.error(StateError('private-detail'));
        },
      ),
    );
    await _openViewer(tester);

    expect(find.text('Could not load this preview'), findsOneWidget);
    expect(readCalls, 1);

    settings.setLanguage(SftpLanguage.chinese);
    await tester.pump();

    expect(find.text('无法加载此文件预览'), findsOneWidget);
    expect(find.textContaining('private-detail'), findsNothing);
    expect(readCalls, 1);
  });
}

Widget _viewerHost({
  required _TestAppSettings settings,
  required SftpEntry entry,
  required SftpViewerReadBytes readBytes,
  SftpViewerHtmlBuilder? htmlBuilder,
  SftpViewerImageProviderBuilder? imageProviderBuilder,
  double textScale = 1,
  EdgeInsets safePadding = EdgeInsets.zero,
  bool darkMode = false,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<_TestAppSettings>.value(value: settings),
      ListenableProvider<SftpSettingsPort>.value(value: settings),
    ],
    child: MaterialApp(
      theme: AppTheme.lightThemeFor(),
      darkTheme: AppTheme.darkThemeFor(oledDark: false),
      themeMode: darkMode ? ThemeMode.dark : ThemeMode.light,
      builder: (context, child) {
        final media = MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          padding: safePadding,
          viewPadding: safePadding,
        );
        return MediaQuery(data: media, child: child!);
      },
      home: _ViewerLauncher(
        entry: entry,
        readBytes: readBytes,
        htmlBuilder: htmlBuilder,
        imageProviderBuilder: imageProviderBuilder,
      ),
    ),
  );
}

Future<void> _openViewer(WidgetTester tester, {bool settle = true}) async {
  await tester.tap(find.byKey(const ValueKey('open-sftp-viewer')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  if (settle) {
    await _pumpUntilPreviewLoaded(tester);
  }
}

Future<void> _pumpUntilPreviewLoaded(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 80)),
  );
  for (var attempt = 0; attempt < 80; attempt += 1) {
    await tester.pump(const Duration(milliseconds: 25));
    if (find.byKey(const ValueKey('sftp-viewer-loading')).evaluate().isEmpty) {
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      return;
    }
  }
  fail('SFTP viewer did not finish loading');
}

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 80)),
  );
  for (var attempt = 0; attempt < 80; attempt += 1) {
    await tester.pump(const Duration(milliseconds: 25));
    if (finder.evaluate().isNotEmpty) {
      await tester.pump();
      return;
    }
  }
  final pendingError = tester.takeException();
  fail(
    'Expected widget did not appear: $finder; '
    'renderError=${find.byKey(const ValueKey('sftp-viewer-image-error')).evaluate().length}; '
    'outerLoading=${find.byKey(const ValueKey('sftp-viewer-loading')).evaluate().length}; '
    'imageDecoding=${find.byKey(const ValueKey('sftp-viewer-image-decoding')).evaluate().length}; '
    'progress=${find.byType(CircularProgressIndicator).evaluate().length}; '
    'exception=$pendingError',
  );
}
