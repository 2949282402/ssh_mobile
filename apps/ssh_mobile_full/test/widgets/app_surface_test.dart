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

  testWidgets('section card exposes a full expandable header target', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      var expanded = false;

      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) => SizedBox(
              width: 320,
              child: AppSectionCard(
                title: 'Advanced options',
                icon: Icons.tune_rounded,
                expanded: expanded,
                onHeaderTap: () => setState(() => expanded = !expanded),
                child: expanded ? const Text('Keep alive') : null,
              ),
            ),
          ),
        ),
      );
      final header = find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == 'Advanced options',
      );

      expect(find.text('Keep alive'), findsNothing);
      expect(
        tester.getSemantics(header),
        matchesSemantics(
          label: 'Advanced options',
          isButton: true,
          hasExpandedState: true,
          hasTapAction: true,
        ),
      );

      await tester.tap(header);
      await tester.pumpAndSettle();

      expect(find.text('Keep alive'), findsOneWidget);
      expect(
        tester.getSemantics(header),
        matchesSemantics(
          label: 'Advanced options',
          isButton: true,
          hasExpandedState: true,
          isExpanded: true,
          hasTapAction: true,
        ),
      );
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
