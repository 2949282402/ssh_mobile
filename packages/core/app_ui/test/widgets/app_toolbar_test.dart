import 'package:app_ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('AppToolbar renders title, leading, and actions', (tester) async {
    var actionClicked = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppToolbar(
            leading: const Icon(Icons.menu),
            titleText: 'Terminal Session',
            actions: [
              AppToolbarGroup(
                children: [
                  AppToolbarAction(
                    icon: Icons.refresh,
                    tooltip: 'Refresh',
                    onPressed: () => actionClicked = true,
                  ),
                  const AppToolbarAction(
                    icon: Icons.settings,
                    tooltip: 'Settings',
                  ),
                ],
              ),
            ],
          ),
          body: const SizedBox(),
        ),
      ),
    );

    expect(find.text('Terminal Session'), findsOneWidget);
    expect(find.byIcon(Icons.menu), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsOneWidget);

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    expect(actionClicked, isTrue);
  });
}
