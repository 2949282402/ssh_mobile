import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/widgets/responsive_row_or_column.dart';

void main() {
  group('ResponsiveRowOrColumn', () {
    testWidgets('renders Row when viewport width is expanded (>= 840)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ResponsiveRowOrColumn(
              spacing: 16.0,
              flexes: const [2, 3],
              children: const [
                Text('First Child'),
                Text('Second Child'),
                Text('Third Child'),
              ],
            ),
          ),
        ),
      );

      expect(find.byType(Row), findsOneWidget);
      expect(find.byType(Column), findsNothing);

      final row = tester.widget<Row>(find.byType(Row));
      expect(row.crossAxisAlignment, CrossAxisAlignment.start);

      // Verify flexes
      final expandeds = tester
          .widgetList<Expanded>(find.byType(Expanded))
          .toList();
      expect(expandeds.length, 3);
      expect(expandeds[0].flex, 2);
      expect(expandeds[1].flex, 3);
      expect(expandeds[2].flex, 1); // default when flexes list is shorter

      // Verify horizontal spacers
      final sizedBoxes = tester
          .widgetList<SizedBox>(find.byType(SizedBox))
          .toList();
      final widthSpacers = sizedBoxes.where((s) => s.width == 16.0).toList();
      expect(widthSpacers.length, 2);
    });

    testWidgets('renders Column when viewport width is compact (< 840)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(600, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ResponsiveRowOrColumn(
              spacing: 14.0,
              children: const [Text('Alpha'), Text('Beta')],
            ),
          ),
        ),
      );

      expect(find.byType(Column), findsOneWidget);
      expect(find.byType(Row), findsNothing);

      final column = tester.widget<Column>(find.byType(Column));
      expect(column.crossAxisAlignment, CrossAxisAlignment.stretch);

      final sizedBoxes = tester
          .widgetList<SizedBox>(find.byType(SizedBox))
          .toList();
      final heightSpacers = sizedBoxes.where((s) => s.height == 14.0).toList();
      expect(heightSpacers.length, 1);
    });

    testWidgets('handles empty and single child correctly', (tester) async {
      // Empty children in Row
      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ResponsiveRowOrColumn(children: [])),
        ),
      );
      expect(find.byType(Row), findsOneWidget);

      // Single child in Column
      tester.view.physicalSize = const Size(400, 800);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ResponsiveRowOrColumn(children: [Text('Solo')])),
        ),
      );
      expect(find.byType(Column), findsOneWidget);
      expect(find.text('Solo'), findsOneWidget);
    });
  });
}
