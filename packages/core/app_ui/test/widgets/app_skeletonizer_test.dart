import 'package:app_ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skeletonizer/skeletonizer.dart';

void main() {
  group('AppSkeletonizer', () {
    testWidgets('renders child content when enabled is false', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppSkeletonizer(
              enabled: false,
              semanticsLabel: 'Loading servers...',
              child: Text('Real Server Content'),
            ),
          ),
        ),
      );

      expect(find.text('Real Server Content'), findsOneWidget);
      final semantics = tester.getSemantics(find.byType(AppSkeletonizer));
      expect(semantics.label, isNot(contains('Loading servers...')));
    });

    testWidgets(
      'exposes semantics label and blocks click when enabled is true',
      (tester) async {
        var clicked = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AppSkeletonizer(
                enabled: true,
                semanticsLabel: 'Loading servers...',
                child: ElevatedButton(
                  onPressed: () => clicked = true,
                  child: const Text('Server Button'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.byType(ElevatedButton), warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 100));
        expect(clicked, isFalse);

        final semantics = tester.getSemantics(find.byType(AppSkeletonizer));
        expect(semantics.label, contains('Loading servers...'));
      },
    );

    testWidgets('supports zone mode with Bone widgets', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppSkeletonizer.zone(
              enabled: true,
              semanticsLabel: 'Loading custom bone...',
              child: Column(
                children: [Bone(width: 100, height: 20), Bone.circle(size: 40)],
              ),
            ),
          ),
        ),
      );

      expect(
        find.byWidgetPredicate((widget) => widget is Bone),
        findsNWidgets(2),
      );
      final semantics = tester.getSemantics(find.byType(AppSkeletonizer));
      expect(semantics.label, contains('Loading custom bone...'));
    });

    testWidgets('respects disableAnimations for reduced motion', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: const Scaffold(
              body: AppSkeletonizer(
                enabled: true,
                semanticsLabel: 'Loading with reduced motion...',
                child: Text('Test Content'),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(AppSkeletonizer), findsOneWidget);
      final skeletonizer = tester.widget<Skeletonizer>(
        find.byWidgetPredicate((w) => w is Skeletonizer),
      );
      expect(skeletonizer.effect, isA<SolidColorEffect>());
      expect(skeletonizer.enableSwitchAnimation, isFalse);
    });
  });

  group('AppTerminalSkeleton', () {
    testWidgets('renders on dark background without overflowing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppTerminalSkeleton(backgroundColor: Color(0xFF000000)),
          ),
        ),
      );

      expect(find.byType(AppTerminalSkeleton), findsOneWidget);
      expect(
        find.byWidgetPredicate((widget) => widget is Bone),
        findsNWidgets(4),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders on light background without overflowing', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppTerminalSkeleton(backgroundColor: Color(0xFFF8FAFC)),
          ),
        ),
      );

      expect(find.byType(AppTerminalSkeleton), findsOneWidget);
      expect(
        find.byWidgetPredicate((widget) => widget is Bone),
        findsNWidgets(4),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
