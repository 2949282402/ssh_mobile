import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ssh_mobile/features/developer_panel/views/developer_panel_floating.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeveloperPanelFloatingHost', () {
    testWidgets('shows ball and opens panel when enabled', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final appSettings = AppSettings();
      addTearDown(appSettings.dispose);
      await appSettings.ensureCoreLoaded();
      await appSettings.setDeveloperMode(true);
      await appSettings.setDeveloperPanelFloating(true);

      await tester.pumpWidget(
        ChangeNotifierProvider<AppSettings>.value(
          value: appSettings,
          child: MaterialApp(
            home: DeveloperPanelFloatingHost(child: const ColoredBox(
              color: Colors.black,
              child: SizedBox.expand(),
            )),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Floating ball is visible.
      expect(find.byIcon(Icons.bug_report_outlined), findsOneWidget);
      // Panel is collapsed initially.
      expect(find.text('Frame Rate'), findsNothing);

      await tester.tap(find.byIcon(Icons.bug_report_outlined));
      await tester.pumpAndSettle();

      // Panel opened with the developer content.
      expect(find.text('Developer Panel'), findsWidgets);
      expect(find.byIcon(Icons.drag_handle_rounded), findsOneWidget);
      expect(find.text('Frame Rate'), findsOneWidget);
      expect(find.text('Memory (RSS)'), findsOneWidget);
      // The Component Activity card is below the fold in the short floating
      // panel and is offstage; find.text skips offstage widgets by default.
      expect(
        find.text('Component Activity', skipOffstage: false),
        findsOneWidget,
      );

      // Close collapses the panel back to the ball.
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Frame Rate'), findsNothing);
      expect(find.byIcon(Icons.bug_report_outlined), findsOneWidget);

      // Flush the batched AppLogService notify timer and unmount the host so
      // the developer panel ViewModel's periodic timer is cancelled.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('hides ball when floating is disabled', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final appSettings = AppSettings();
      addTearDown(appSettings.dispose);
      await appSettings.ensureCoreLoaded();
      await appSettings.setDeveloperMode(true);
      await appSettings.setDeveloperPanelFloating(false);

      await tester.pumpWidget(
        ChangeNotifierProvider<AppSettings>.value(
          value: appSettings,
          child: MaterialApp(
            home: DeveloperPanelFloatingHost(child: const SizedBox.expand()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Flush the batched AppLogService notify timer scheduled by the
      // setDeveloperMode log call (pumpAndSettle only settles frames).
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byIcon(Icons.bug_report_outlined), findsNothing);
    });

    testWidgets('shows ball after enabling floating at runtime', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final appSettings = AppSettings();
      addTearDown(appSettings.dispose);
      await appSettings.ensureCoreLoaded();
      // Mount with floating OFF, then toggle it ON while the widget is live.
      await appSettings.setDeveloperMode(true);
      await appSettings.setDeveloperPanelFloating(false);

      await tester.pumpWidget(
        ChangeNotifierProvider<AppSettings>.value(
          value: appSettings,
          child: MaterialApp(
            home: DeveloperPanelFloatingHost(child: const SizedBox.expand()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byIcon(Icons.bug_report_outlined), findsNothing);

      await appSettings.setDeveloperPanelFloating(true);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));

      // Ball appears even though the host was mounted while disabled.
      expect(find.byIcon(Icons.bug_report_outlined), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
