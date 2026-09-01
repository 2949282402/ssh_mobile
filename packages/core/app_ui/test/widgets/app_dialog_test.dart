import 'package:app_ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('AppConfirmDialog renders title, content and handles actions', (
    tester,
  ) async {
    bool? confirmed;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () async {
                  confirmed = await AppConfirmDialog.show(
                    context,
                    title: 'Delete Connection',
                    content: 'Are you sure you want to delete this host?',
                    cancelLabel: 'Cancel',
                    confirmLabel: 'Delete',
                    isDestructive: true,
                  );
                },
                child: const Text('Open Dialog'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Dialog'));
    await tester.pumpAndSettle();

    expect(find.text('Delete Connection'), findsOneWidget);
    expect(
      find.text('Are you sure you want to delete this host?'),
      findsOneWidget,
    );
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(confirmed, isTrue);
  });

  testWidgets('AppDialog and AppErrorDialog render correctly', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return Column(
                children: [
                  ElevatedButton(
                    onPressed: () {
                      AppDialog.show(
                        context: context,
                        title: 'Generic Dialog',
                        child: const Text('Dialog Body'),
                      );
                    },
                    child: const Text('Show Dialog'),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      AppErrorDialog.show(
                        context,
                        title: 'Error Occurred',
                        message: 'Failed to connect to host',
                        details: 'Socket timeout error',
                      );
                    },
                    child: const Text('Show Error'),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Show Dialog'));
    await tester.pumpAndSettle();
    expect(find.text('Generic Dialog'), findsOneWidget);
    expect(find.text('Dialog Body'), findsOneWidget);

    // Tap outside to dismiss or close
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Show Error'));
    await tester.pumpAndSettle();
    expect(find.text('Error Occurred'), findsOneWidget);
    expect(find.text('Failed to connect to host'), findsOneWidget);
    expect(find.text('Socket timeout error'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Error Occurred'), findsNothing);
  });

  testWidgets('AppBottomSheet renders title and child', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () {
                  AppBottomSheet.show(
                    context: context,
                    title: 'Actions',
                    child: const Text('Sheet Content'),
                  );
                },
                child: const Text('Open Sheet'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Sheet'));
    await tester.pumpAndSettle();

    expect(find.text('Actions'), findsOneWidget);
    expect(find.text('Sheet Content'), findsOneWidget);
  });

  testWidgets('AppStatusColors provides consistent status tokens', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.buildDarkTheme(),
        home: Builder(
          builder: (context) {
            final colors = AppStatusColors.of(context);
            expect(colors.success, isNotNull);
            expect(colors.warning, isNotNull);
            expect(colors.error, isNotNull);
            expect(colors.info, isNotNull);
            expect(colors.neutral, isNotNull);
            return const SizedBox();
          },
        ),
      ),
    );
  });
}
