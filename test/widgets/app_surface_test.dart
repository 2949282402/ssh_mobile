import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ssh_mobile/theme/app_theme.dart';
import 'package:ssh_mobile/widgets/app_surface.dart';

void main() {
  Widget host(Widget child, {ThemeData? theme}) {
    return MaterialApp(
      theme: theme ?? AppTheme.lightThemeFor(),
      home: Scaffold(body: child),
    );
  }

  testWidgets('page surface preserves its child', (tester) async {
    await tester.pumpWidget(
      host(const AppPageSurface(child: Center(child: Text('workspace')))),
    );

    expect(find.text('workspace'), findsOneWidget);
    expect(find.byType(DecoratedBox), findsWidgets);
  });

  testWidgets('compact empty state keeps content and action visible', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        SizedBox(
          width: 320,
          height: 480,
          child: AppEmptyState(
            icon: Icons.terminal_rounded,
            title: 'No servers yet',
            message: 'Add a server to start a secure terminal session.',
            compact: true,
            action: FilledButton(
              onPressed: () {},
              child: const Text('Add server'),
            ),
          ),
        ),
      ),
    );

    expect(find.text('No servers yet'), findsOneWidget);
    expect(
      find.text('Add a server to start a secure terminal session.'),
      findsOneWidget,
    );
    expect(find.text('Add server'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('page header adapts to a narrow width', (tester) async {
    await tester.pumpWidget(
      host(
        const SizedBox(
          width: 340,
          child: AppPageHeader(
            title: 'Servers',
            subtitle: 'Three saved connections',
            icon: Icons.dns_rounded,
            trailing: IconButton(
              onPressed: null,
              icon: Icon(Icons.add_rounded),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Servers'), findsOneWidget);
    expect(find.text('Three saved connections'), findsOneWidget);
    expect(find.byIcon(Icons.dns_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
