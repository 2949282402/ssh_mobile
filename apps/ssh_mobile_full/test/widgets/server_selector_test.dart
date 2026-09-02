import 'package:connection_core/connection_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/widgets/server_selector.dart';

ConnectionConfig _createTestConfig(String id, String name) {
  return ConnectionConfig(
    id: id,
    name: name,
    host: '$id.example.com',
    port: 22,
    username: 'root',
  );
}

void main() {
  group('ServerSelectorPane', () {
    testWidgets('renders empty state and disabled collapse button when empty', (
      tester,
    ) async {
      var collapseInvoked = false;
      var reorderInvoked = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ServerSelectorPane(
              connections: const [],
              title: 'Server Selector',
              subtitle: 'Select a server to manage',
              headerIcon: Icons.storage,
              collapseTooltip: 'Collapse panel',
              reorderTooltip: 'Drag to reorder',
              itemKeyBuilder: (connection) =>
                  ValueKey('server-${connection.id}'),
              collapseButtonKey: const ValueKey('collapse_btn'),
              emptyState: const Text('No servers available'),
              onCollapse: () => collapseInvoked = true,
              onReorder: (oldIndex, newIndex) => reorderInvoked = true,
              tileBuilder: (context, connection, compact) =>
                  Text(connection.name),
            ),
          ),
        ),
      );

      expect(find.text('Server Selector'), findsOneWidget);
      expect(find.text('Select a server to manage'), findsOneWidget);
      expect(find.byIcon(Icons.storage), findsOneWidget);
      expect(find.text('No servers available'), findsOneWidget);
      expect(find.byKey(const ValueKey('collapse_btn')), findsOneWidget);

      // Tap collapse button when empty (should be disabled, onCollapse not called)
      final iconButton = tester.widget<IconButton>(
        find.byKey(const ValueKey('collapse_btn')),
      );
      expect(iconButton.onPressed, isNull);
      expect(collapseInvoked, isFalse);
      expect(reorderInvoked, isFalse);
    });

    testWidgets('renders server list with drag handles and triggers actions', (
      tester,
    ) async {
      var collapseInvoked = false;
      int? reorderedOld;
      int? reorderedNew;

      final configs = [
        _createTestConfig('srv-1', 'Server Alpha'),
        _createTestConfig('srv-2', 'Server Beta'),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ServerSelectorPane(
              connections: configs,
              title: 'Server Selector',
              subtitle: 'Active servers',
              headerIcon: Icons.dns,
              collapseTooltip: 'Collapse panel',
              reorderTooltip: 'Reorder server',
              itemKeyBuilder: (connection) =>
                  ValueKey('server-${connection.id}'),
              collapseButtonKey: const ValueKey('collapse_btn'),
              dragHandleKeyBuilder: (conn) => ValueKey('drag_${conn.id}'),
              collapseIcon: Icons.arrow_back,
              emptyState: const Text('No servers'),
              onCollapse: () => collapseInvoked = true,
              onReorder: (oldIndex, newIndex) {
                reorderedOld = oldIndex;
                reorderedNew = newIndex;
              },
              tileBuilder: (context, connection, compact) {
                expect(compact, isFalse);
                return Text('Tile: ${connection.name}');
              },
            ),
          ),
        ),
      );

      expect(find.text('Tile: Server Alpha'), findsOneWidget);
      expect(find.text('Tile: Server Beta'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      expect(find.byKey(const ValueKey('drag_srv-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('drag_srv-2')), findsOneWidget);

      // Tap collapse button when not empty
      await tester.tap(find.byKey(const ValueKey('collapse_btn')));
      await tester.pump();
      expect(collapseInvoked, isTrue);

      // Simulate reorder on ReorderableListView
      final reorderableFinder = find.byType(ReorderableListView);
      expect(reorderableFinder, findsOneWidget);
      final reorderable = tester.widget<ReorderableListView>(reorderableFinder);
      reorderable.onReorderItem?.call(0, 2);
      expect(reorderedOld, 0);
      expect(reorderedNew, 2);
    });
  });

  group('ServerSelectorStrip', () {
    testWidgets('renders empty placeholder when no connections', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ServerSelectorStrip(
              connections: const [],
              semanticsLabel: 'Server selector bar',
              noConnectionsLabel: 'No active connections',
              collapseTooltip: 'Collapse bar',
              collapseButtonKey: const ValueKey('collapse_strip_btn'),
              onCollapse: () {},
              tileBuilder: (context, connection, compact) =>
                  Text(connection.name),
            ),
          ),
        ),
      );

      expect(find.text('No active connections'), findsOneWidget);
    });

    testWidgets('renders horizontal list with collapse button and tiles', (
      tester,
    ) async {
      var collapseInvoked = false;
      final configs = [
        _createTestConfig('srv-1', 'Server Alpha'),
        _createTestConfig('srv-2', 'Server Beta'),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ServerSelectorStrip(
              connections: configs,
              semanticsLabel: 'Server selector strip',
              noConnectionsLabel: 'No active connections',
              collapseTooltip: 'Collapse strip',
              collapseIcon: Icons.keyboard_arrow_up,
              collapseButtonKey: const ValueKey('collapse_strip_btn'),
              onCollapse: () => collapseInvoked = true,
              tileBuilder: (context, connection, compact) {
                expect(compact, isTrue);
                return Text('Compact: ${connection.name}');
              },
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('collapse_strip_btn')), findsOneWidget);
      final alignFinder = find.ancestor(
        of: find.byKey(const ValueKey('collapse_strip_btn')),
        matching: find.byType(Align),
      );
      expect(alignFinder, findsOneWidget);
      final align = tester.widget<Align>(alignFinder);
      expect(align.alignment, Alignment.center);
      expect(find.byIcon(Icons.keyboard_arrow_up), findsOneWidget);
      expect(find.text('Compact: Server Alpha'), findsOneWidget);
      expect(find.text('Compact: Server Beta'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('collapse_strip_btn')));
      await tester.pump();
      expect(collapseInvoked, isTrue);
    });
  });
}
