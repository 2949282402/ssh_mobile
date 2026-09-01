import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app_ui/app_ui.dart';

void main() {
  testWidgets('AppConfirmDialog renders title, content and handles actions', (
    tester,
  ) async {
    bool? confirmed;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                confirmed = await AppConfirmDialog.show(
                  context,
                  title: 'Delete Item',
                  content: 'Are you sure you want to delete?',
                  cancelLabel: 'Cancel',
                  confirmLabel: 'Delete',
                  isDestructive: true,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Delete Item'), findsOneWidget);
    expect(find.text('Are you sure you want to delete?'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(confirmed, isTrue);
  });

  test('AppStatusColors provides consistent status tokens', () {
    final light = AppStatusColors.light;
    final dark = AppStatusColors.dark;

    expect(light.success, isNotNull);
    expect(light.warning, isNotNull);
    expect(light.error, isNotNull);
    expect(light.info, isNotNull);
    expect(light.neutral, isNotNull);

    expect(dark.success, isNotNull);
    expect(dark.warning, isNotNull);
    expect(dark.error, isNotNull);
    expect(dark.info, isNotNull);
    expect(dark.neutral, isNotNull);
  });
}
