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
                showTrailingDivider: true,
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
              AppToolbarActions(
                children: [
                  AppToolbarAction(
                    icon: Icons.close,
                    tooltip: 'Close',
                    onPressed: () {},
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
    expect(find.byIcon(Icons.close), findsOneWidget);

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    expect(actionClicked, isTrue);
  });

  testWidgets(
    'AppToolbarAction renders 32x32 compact target on desktop platforms',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: Center(
              child: AppToolbarAction(
                key: const ValueKey('desktop-action'),
                icon: Icons.folder,
                onPressed: () {},
              ),
            ),
          ),
        ),
      );

      final actionFinder = find.byKey(const ValueKey('desktop-action'));
      expect(actionFinder, findsOneWidget);
      final size = tester.getSize(actionFinder);
      expect(size.width, equals(32.0));
      expect(size.height, equals(32.0));
    },
  );

  testWidgets(
    'AppToolbarAction renders >=44x44 touch target on mobile platforms',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Scaffold(
            body: Center(
              child: AppToolbarAction(
                key: const ValueKey('mobile-action'),
                icon: Icons.folder,
                onPressed: () {},
              ),
            ),
          ),
        ),
      );

      final actionFinder = find.byKey(const ValueKey('mobile-action'));
      expect(actionFinder, findsOneWidget);
      final size = tester.getSize(actionFinder);
      expect(size.width, greaterThanOrEqualTo(44.0));
      expect(size.height, greaterThanOrEqualTo(44.0));
    },
  );

  testWidgets(
    'AppToolbarAction.compact and touch constructors enforce target sizes',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: const Scaffold(
            body: Row(
              children: [
                AppToolbarAction.compact(
                  key: Key('compact-action'),
                  icon: Icons.compress,
                ),
                AppToolbarAction.touch(
                  key: Key('touch-action'),
                  icon: Icons.touch_app,
                ),
              ],
            ),
          ),
        ),
      );

      final compactSize = tester.getSize(
        find.byKey(const Key('compact-action')),
      );
      final touchSize = tester.getSize(find.byKey(const Key('touch-action')));

      expect(compactSize.height, equals(32.0));
      expect(touchSize.height, equals(44.0));
    },
  );

  testWidgets(
    'AppToolbarAction renders label, badge, isSelected, and isDestructive',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                AppToolbarAction(
                  icon: Icons.check,
                  label: 'Save',
                  isSelected: true,
                  badge: const Text('1'),
                  onPressed: () {},
                ),
                AppToolbarAction(
                  icon: Icons.delete,
                  isDestructive: true,
                  onPressed: () {},
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('Save'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.byIcon(Icons.delete), findsOneWidget);
    },
  );
}
