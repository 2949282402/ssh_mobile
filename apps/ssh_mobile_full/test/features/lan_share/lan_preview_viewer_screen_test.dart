import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:provider/provider.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:ssh_mobile/app/lan_share_feature_adapters.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:app_ui/app_ui.dart';

final Uint8List _testPng = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAARSURBVBhXY9DPf/sfhBlgDABVngopRVqb1AAAAABJRU5ErkJggg==',
  ),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LAN preview safety helpers', () {
    test(
      'bounded reader rejects an over-budget file before allocation',
      () async {
        final file = await _temporaryFile(
          'oversized.txt',
          List<int>.filled(33, 7),
        );

        await expectLater(
          readLanPreviewFileBounded(file, maxBytes: 32),
          throwsA(
            isA<LanPreviewTooLargeException>().having(
              (error) => error.maxBytes,
              'maxBytes',
              32,
            ),
          ),
        );
      },
    );

    test('bounded reader permits a file exactly at the byte budget', () async {
      final source = List<int>.generate(32, (index) => index);
      final file = await _temporaryFile('exact.txt', source);

      final bytes = await readLanPreviewFileBounded(file, maxBytes: 32);

      expect(bytes, orderedEquals(source));
    });

    test('UTF-8 byte budget is counted without code-unit assumptions', () {
      expect(lanPreviewUtf8WithinLimit('abc', 3), isTrue);
      expect(lanPreviewUtf8WithinLimit('abc', 2), isFalse);
      expect(lanPreviewUtf8WithinLimit('中', 3), isTrue);
      expect(lanPreviewUtf8WithinLimit('中', 2), isFalse);
      expect(lanPreviewUtf8WithinLimit('🙂', 4), isTrue);
      expect(lanPreviewUtf8WithinLimit('🙂', 3), isFalse);
    });

    test('image metadata enforces dimension, frame, and pixel budgets', () {
      expect(lanPreviewImageMetadataWithinBudget(5000, 5000, 1), isTrue);
      expect(lanPreviewImageMetadataWithinBudget(16385, 1, 1), isFalse);
      expect(lanPreviewImageMetadataWithinBudget(5001, 5000, 1), isFalse);
      expect(lanPreviewImageMetadataWithinBudget(1000, 1000, 121), isFalse);
      expect(lanPreviewImageMetadataWithinBudget(1000, 1000, 101), isFalse);
      expect(lanPreviewImageMetadataWithinBudget(0, 100, 1), isFalse);
    });

    test(
      'image inspector reads bounded metadata without full-size decoding',
      () async {
        final metadata = await inspectLanPreviewImage(_testPng);

        expect(metadata.width, 2);
        expect(metadata.height, 2);
        expect(metadata.frameCount, 1);
      },
    );

    test('image inspector reports malformed content as a decode failure', () {
      expect(
        inspectLanPreviewImage(Uint8List.fromList(const [1, 2, 3, 4])),
        throwsA(isA<LanPreviewDecodeException>()),
      );
    });
    test('decoded image target remains inside the rendering pixel budget', () {
      final target = boundedLanPreviewPixelSize(
        const Size(12000, 12000),
        maxWidth: 4096,
        maxHeight: 4096,
      );

      expect(target.width, lessThanOrEqualTo(4096));
      expect(target.height, lessThanOrEqualTo(4096));
      expect(
        target.width * target.height,
        lessThanOrEqualTo(lanPreviewMaxDecodedImagePixels),
      );
    });

    test('HTML sandbox precedes content and denies every resource class', () {
      const rawHtml =
          '<a href="https://example.com">leave</a>'
          '<img src="data:image/svg+xml,bad">'
          '<script>alert(1)</script>';
      final sandboxed = buildLanPreviewSandboxedHtml(
        rawHtml,
        brightness: Brightness.dark,
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        linkColor: Colors.blue,
        codeBackgroundColor: Colors.grey,
      );

      expect(sandboxed, contains("default-src 'none'"));
      expect(sandboxed, contains("script-src 'none'"));
      expect(sandboxed, contains("connect-src 'none'"));
      expect(sandboxed, contains("img-src 'none'"));
      expect(sandboxed, contains("navigate-to 'none'"));
      expect(sandboxed, contains('name="referrer" content="no-referrer"'));
      expect(
        sandboxed.indexOf('Content-Security-Policy'),
        lessThan(sandboxed.indexOf('https://example.com')),
      );
    });

    test('HTML navigation permits only the inert loaded document URL', () {
      expect(lanPreviewNavigationAllowed('about:blank'), isTrue);
      expect(lanPreviewNavigationAllowed('about:blank#section'), isTrue);
      expect(lanPreviewNavigationAllowed('https://example.com'), isFalse);
      expect(lanPreviewNavigationAllowed('http://192.168.1.1'), isFalse);
      expect(lanPreviewNavigationAllowed('file:///etc/passwd'), isFalse);
      expect(lanPreviewNavigationAllowed('data:text/html,hello'), isFalse);
      expect(lanPreviewNavigationAllowed('javascript:alert(1)'), isFalse);
      expect(lanPreviewNavigationAllowed('ssh://host'), isFalse);
    });
  });

  group('LAN preview viewer', () {
    testWidgets('declared oversized text is rejected before file reading', (
      tester,
    ) async {
      final file = await _temporaryWidgetFile(
        tester,
        'large.txt',
        utf8.encode('ignored'),
      );
      final settings = _TestAppSettings();
      addTearDown(settings.dispose);
      var readCalls = 0;

      await tester.pumpWidget(
        _viewerHost(
          settings: settings,
          message: _message(
            fileName: 'large.txt',
            path: file.path,
            fileSize: lanPreviewTextLimitBytes + 1,
          ),
          readBytes: (file, {required maxBytes}) async {
            readCalls += 1;
            return Uint8List(0);
          },
        ),
      );
      await _pumpUntilLoaded(tester);

      expect(
        find.byKey(const ValueKey('lan-preview-too-large')),
        findsOneWidget,
      );
      expect(readCalls, 0);
      expect(find.text('This file is too large to preview'), findsOneWidget);
    });

    testWidgets('text reader receives the hard byte limit', (tester) async {
      final file = await _temporaryWidgetFile(
        tester,
        'report.txt',
        const <int>[],
      );
      final settings = _TestAppSettings();
      addTearDown(settings.dispose);
      int? receivedLimit;

      await tester.pumpWidget(
        _viewerHost(
          settings: settings,
          message: _message(
            fileName: 'report.txt',
            path: file.path,
            fileSize: 4,
          ),
          readBytes: (file, {required maxBytes}) async {
            receivedLimit = maxBytes;
            return Uint8List.fromList(utf8.encode('safe'));
          },
        ),
      );
      await _pumpUntilLoaded(tester);

      expect(receivedLimit, lanPreviewTextLimitBytes);
      expect(find.text('safe'), findsOneWidget);
    });

    testWidgets('markdown blocks remote images and removes link components', (
      tester,
    ) async {
      const markdown =
          '# Report\n'
          '![tracker](https://example.com/tracker.png)\n'
          '[Runbook](https://example.com/runbook)\n'
          '`[code](https://example.com/code)`';
      final file = await _temporaryWidgetFile(
        tester,
        'report.md',
        const <int>[],
      );
      final settings = _TestAppSettings();
      addTearDown(settings.dispose);

      await tester.pumpWidget(
        _viewerHost(
          settings: settings,
          message: _message(
            fileName: 'report.md',
            path: file.path,
            fileSize: utf8.encode(markdown).length,
          ),
          readBytes: (file, {required maxBytes}) async {
            return Uint8List.fromList(utf8.encode(markdown));
          },
        ),
      );
      await _pumpUntilLoaded(tester);

      expect(
        find.byKey(const ValueKey('lan-preview-markdown')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
      final markdownWidget = tester.widget<GptMarkdown>(
        find.byType(GptMarkdown),
      );
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
    });

    testWidgets('HTML is wrapped in the deny-by-default sandbox', (
      tester,
    ) async {
      const rawHtml = '<img src="https://example.com/tracker.png">';
      final file = await _temporaryWidgetFile(
        tester,
        'report.html',
        const <int>[],
      );
      final settings = _TestAppSettings();
      addTearDown(settings.dispose);
      String? receivedHtml;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      try {
        await tester.pumpWidget(
          _viewerHost(
            settings: settings,
            message: _message(
              fileName: 'report.html',
              path: file.path,
              fileSize: utf8.encode(rawHtml).length,
            ),
            readBytes: (file, {required maxBytes}) async {
              return Uint8List.fromList(utf8.encode(rawHtml));
            },
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
        await _pumpUntilLoaded(tester);

        expect(find.text('sandboxed-html'), findsOneWidget);
        expect(receivedHtml, contains("default-src 'none'"));
        expect(receivedHtml, contains("script-src 'none'"));
        expect(receivedHtml, contains("img-src 'none'"));
        expect(
          receivedHtml!.indexOf('Content-Security-Policy'),
          lessThan(receivedHtml!.indexOf('https://example.com')),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('dangerous image metadata is rejected before rendering', (
      tester,
    ) async {
      final file = await _temporaryWidgetFile(
        tester,
        'bomb.gif',
        const <int>[],
      );
      final settings = _TestAppSettings();
      addTearDown(settings.dispose);
      var providerCalls = 0;

      await tester.pumpWidget(
        _viewerHost(
          settings: settings,
          message: _message(
            payloadType: LanPayloadType.image,
            fileName: 'bomb.gif',
            path: file.path,
            fileSize: 1,
          ),
          readBytes: (file, {required maxBytes}) async {
            expect(maxBytes, lanPreviewImageLimitBytes);
            return Uint8List.fromList(const [0]);
          },
          imageInspector: (bytes) async => const LanPreviewImageMetadata(
            width: 1000,
            height: 1000,
            frameCount: 121,
          ),
          imageProviderBuilder: (bytes, width, height) {
            providerCalls += 1;
            return MemoryImage(bytes);
          },
        ),
      );
      await _pumpUntilLoaded(tester);

      expect(
        find.byKey(const ValueKey('lan-preview-resource-limit')),
        findsOneWidget,
      );
      expect(providerCalls, 0);
      expect(
        find.text('This file is too complex to preview safely'),
        findsOneWidget,
      );
    });
  });
}

class _TestAppSettings extends AppSettings {
  @override
  AppLanguage get language => AppLanguage.en;
}

Widget _viewerHost({
  required _TestAppSettings settings,
  required LanMessage message,
  required LanPreviewFileReader readBytes,
  LanPreviewImageInspector? imageInspector,
  LanPreviewHtmlBuilder? htmlBuilder,
  LanPreviewImageProviderBuilder? imageProviderBuilder,
}) {
  final settingsPort = AppLanShareSettingsAdapter(settings);
  addTearDown(settingsPort.dispose);
  return ListenableProvider<LanShareSettingsPort>.value(
    value: settingsPort,
    child: MaterialApp(
      theme: AppTheme.lightThemeFor(),
      home: LanPreviewViewerScreen.forTesting(
        message: message,
        readBytesForTesting: readBytes,
        imageInspectorForTesting: imageInspector,
        htmlBuilderForTesting: htmlBuilder,
        imageProviderBuilderForTesting: imageProviderBuilder,
      ),
    ),
  );
}

LanMessage _message({
  LanPayloadType payloadType = LanPayloadType.file,
  required String fileName,
  required String path,
  required int fileSize,
}) {
  return LanMessage(
    id: 'message-1',
    senderId: 'sender',
    senderAlias: 'Sender',
    receiverId: 'receiver',
    payloadType: payloadType,
    fileName: fileName,
    fileSize: fileSize,
    localPath: path,
    status: LanTransferStatus.completed,
    createdAt: DateTime(2026, 7, 18),
    isIncoming: true,
  );
}

Future<File> _temporaryWidgetFile(
  WidgetTester tester,
  String name,
  List<int> bytes,
) async {
  final file = await tester.runAsync(() => _temporaryFile(name, bytes));
  if (file == null) {
    throw StateError('Widget test file creation did not complete');
  }
  return file;
}

Future<File> _temporaryFile(String name, List<int> bytes) async {
  final directory = await Directory.systemTemp.createTemp('lan_preview_test_');
  addTearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });
  final file = File('${directory.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

Future<void> _pumpUntilLoaded(WidgetTester tester) async {
  for (var attempt = 0; attempt < 80; attempt += 1) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 25));
    if (find.byKey(const ValueKey('lan-preview-loading')).evaluate().isEmpty) {
      await tester.pump(const Duration(milliseconds: 100));
      return;
    }
  }
  fail('LAN preview did not finish loading');
}
