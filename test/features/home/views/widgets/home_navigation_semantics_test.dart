import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/home/views/widgets/home_navigation_semantics.dart';

void main() {
  testWidgets('exposes one selected button semantics node', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeNavigationSemantics(
              semanticsKey: const ValueKey<String>('navigation-semantics'),
              label: 'Servers',
              selected: true,
              onTap: () {},
              child: const Column(
                children: [Icon(Icons.dns_outlined), Text('Servers')],
              ),
            ),
          ),
        ),
      );

      expect(
        tester.getSemantics(find.byKey(const ValueKey('navigation-semantics'))),
        matchesSemantics(
          label: 'Servers',
          isButton: true,
          hasSelectedState: true,
          isSelected: true,
          hasTapAction: true,
        ),
      );
      expect(find.bySemanticsLabel('Servers'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });
}
