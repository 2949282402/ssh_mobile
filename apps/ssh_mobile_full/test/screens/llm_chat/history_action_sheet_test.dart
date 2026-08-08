import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_ai/ai_chat.dart';

void main() {
  testWidgets('history sheet exposes selected row semantics and 48dp delete', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(280, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? selected;
    String? deleted;
    const activeUrl = 'https://api.example.com/v1/selected';
    const longUrl =
        'https://api.example.com/a/very/long/history/value/that/must/ellipsis';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HistoryActionSheet<String>(
            title: 'Base URL history',
            emptyText: 'Empty',
            deleteTooltip: 'Delete',
            items: const [activeUrl, longUrl],
            labelBuilder: (value) => value,
            selectedValue: activeUrl,
            valueKeyBuilder: (value) => value,
            onSelect: (value) => selected = value,
            onDelete: (value) => deleted = value,
          ),
        ),
      ),
    );

    final selectedRow = find.byKey(
      const ValueKey<String>('history-action-item-0'),
    );
    final selectedTile = find.descendant(
      of: selectedRow,
      matching: find.byType(ListTile),
    );
    expect(tester.widget<ListTile>(selectedTile).selected, isTrue);
    expect(
      tester.getSemantics(selectedRow).flagsCollection.isSelected,
      Tristate.isTrue,
    );

    final deleteButtons = find.byTooltip('Delete');
    expect(deleteButtons, findsNWidgets(2));
    expect(
      tester.getSize(deleteButtons.first).height,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(deleteButtons.at(1));
    expect(deleted, longUrl);
    await tester.tap(find.text(activeUrl));
    expect(selected, activeUrl);
    expect(tester.takeException(), isNull);
  });
}
