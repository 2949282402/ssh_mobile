import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app_ui/app_ui.dart';

void main() {
  testWidgets('AppLoadingIndicator renders with default and custom sizes', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AppLoadingIndicator(size: 32, semanticsLabel: 'Custom loading'),
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.bySemanticsLabel('Custom loading'), findsOneWidget);
  });

  testWidgets('AppInlineProgress renders with optional message', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AppInlineProgress(message: 'Saving changes...')),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Saving changes...'), findsOneWidget);
  });

  testWidgets(
    'AppSkeletonRow renders leading and bone lines in skeletonizer zone',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppSkeletonizer.zone(
              enabled: true,
              semanticsLabel: 'Loading rows',
              child: AppSkeletonRow(),
            ),
          ),
        ),
      );

      expect(find.byType(AppSkeletonRow), findsOneWidget);
      expect(find.bySemanticsLabel('Loading rows'), findsOneWidget);
    },
  );
}
