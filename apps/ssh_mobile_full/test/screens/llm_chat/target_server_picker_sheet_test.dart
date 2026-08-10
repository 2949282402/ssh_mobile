import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_ai/ai_chat.dart';
import 'package:connection_core/connection_core.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('server picker fits narrow mobile and exposes full semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 24);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);

    const longName =
        'Production server with an extremely long name that must be truncated';
    const fullAddress =
        'administrator@[2001:0db8:85a3:0000:0000:8a2e:0370:7334]:2222';
    await tester.pumpWidget(
      _serverPickerHost(
        strings: const AiStrings(AppLanguage.en),
        connections: [
          _connection(
            id: 'primary',
            name: longName,
            host: '2001:0db8:85a3:0000:0000:8a2e:0370:7334',
            username: 'administrator',
            port: 2222,
          ),
          _connection(id: 'bracketed', name: 'Bracketed IPv6', host: '[::1]'),
        ],
        initialSelection: const {'primary'},
        onClosed: (_) {},
        textScale: 2,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-server-picker')));
    await tester.pumpAndSettle();

    final option = find.byKey(const ValueKey('server-option-primary'));
    expect(option, findsOneWidget);
    final title = tester.widget<Text>(
      find.descendant(of: option, matching: find.text(longName)),
    );
    final subtitle = tester.widget<Text>(
      find.descendant(of: option, matching: find.text(fullAddress)),
    );
    for (final text in [title, subtitle]) {
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
    }
    expect(
      tester.getSemantics(option),
      matchesSemantics(
        label: '$longName, $fullAddress',
        hasCheckedState: true,
        isChecked: true,
        hasTapAction: true,
      ),
    );
    expect(find.text('admin@[::1]:22'), findsOneWidget);

    final clear = find.byKey(const ValueKey('server-selector-clear'));
    final cancel = find.byKey(const ValueKey('server-selector-cancel'));
    final save = find.byKey(const ValueKey('server-selector-save'));
    for (final action in [clear, cancel, save]) {
      expect(action, findsOneWidget);
      expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
    }
    expect(tester.getBottomRight(save).dy, lessThanOrEqualTo(544));
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('server picker actions remain above a 1.5K landscape keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2856, 1280);
    tester.view.devicePixelRatio = 3;
    tester.view.viewInsets = const FakeViewPadding(bottom: 660);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(
      _serverPickerHost(
        strings: const AiStrings(AppLanguage.zh),
        connections: List.generate(
          8,
          (index) => _connection(id: 'server-$index', name: '服务器 $index'),
        ),
        initialSelection: const {'server-0'},
        onClosed: (_) {},
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-server-picker')));
    await tester.pumpAndSettle();

    final clear = find.byKey(const ValueKey('server-selector-clear'));
    final cancel = find.byKey(const ValueKey('server-selector-cancel'));
    final save = find.byKey(const ValueKey('server-selector-save'));
    for (final action in [clear, cancel, save]) {
      expect(action, findsOneWidget);
      expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
    }
    final visibleBottom =
        tester.view.physicalSize.height / tester.view.devicePixelRatio -
        tester.view.viewInsets.bottom / tester.view.devicePixelRatio;
    expect(tester.getBottomRight(save).dy, lessThanOrEqualTo(visibleBottom));
    expect(tester.getBottomRight(clear).dy, lessThanOrEqualTo(visibleBottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('server picker lazily builds large connection lists', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final connections = List.generate(
      200,
      (index) => _connection(id: 'server-$index', name: 'Server $index'),
    );

    await tester.pumpWidget(
      _serverPickerHost(
        strings: const AiStrings(AppLanguage.en),
        connections: connections,
        initialSelection: const {},
        onClosed: (_) {},
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-server-picker')));
    await tester.pumpAndSettle();

    expect(find.byType(CheckboxListTile).evaluate().length, lessThan(200));
    final list = find.byKey(const ValueKey('server-selector-list'));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('server-option-server-199')),
      500,
      scrollable: find.descendant(of: list, matching: find.byType(Scrollable)),
    );
    expect(
      find.byKey(const ValueKey('server-option-server-199')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('server picker drops stale ids, cancels, and saves once', (
    tester,
  ) async {
    Set<String>? result = {'unchanged'};
    var closeCount = 0;
    final connections = [
      _connection(id: 'server-1', name: 'Server 1'),
      _connection(id: 'server-2', name: 'Server 2'),
    ];
    await tester.pumpWidget(
      _serverPickerHost(
        strings: const AiStrings(AppLanguage.en),
        connections: connections,
        initialSelection: const {'server-1', 'stale'},
        onClosed: (value) {
          result = value;
          closeCount += 1;
        },
      ),
    );

    await tester.tap(find.byKey(const ValueKey('open-server-picker')));
    await tester.pumpAndSettle();
    expect(find.text('1 server'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('server-option-server-2')));
    await tester.pump();
    expect(find.text('2 servers'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('server-selector-cancel')));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(closeCount, 1);

    await tester.tap(find.byKey(const ValueKey('open-server-picker')));
    await tester.pumpAndSettle();
    final secondOption = find.byKey(const ValueKey('server-option-server-2'));
    await tester.tap(secondOption);
    await tester.pump();
    final save = find.byKey(const ValueKey('server-selector-save'));
    await tester.tap(save);
    await tester.tap(save, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(result, const {'server-1', 'server-2'});
    expect(closeCount, 2);
    expect(find.byKey(const ValueKey('host-sentinel')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

ConnectionConfig _connection({
  required String id,
  required String name,
  String host = 'example.com',
  String username = 'admin',
  int port = 22,
}) {
  return ConnectionConfig(
    id: id,
    name: name,
    host: host,
    username: username,
    port: port,
  );
}

Widget _serverPickerHost({
  required AiStrings strings,
  required List<ConnectionConfig> connections,
  required Set<String> initialSelection,
  required ValueChanged<Set<String>?> onClosed,
  double textScale = 1,
}) {
  return MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(
      body: Column(
        children: [
          const Text('Host remains open', key: ValueKey('host-sentinel')),
          Builder(
            builder: (context) => FilledButton(
              key: const ValueKey('open-server-picker'),
              onPressed: () async {
                final result = await showTargetServerPickerSheet(
                  context: context,
                  connections: connections,
                  initialSelection: initialSelection,
                  strings: strings,
                );
                onClosed(result);
              },
              child: const Text('Open'),
            ),
          ),
        ],
      ),
    ),
  );
}
