import 'package:app_ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestServerItem {
  final String id;
  final String name;
  final String address;

  const _TestServerItem({
    required this.id,
    required this.name,
    required this.address,
  });
}

void main() {
  group('AppServerSelectorPane', () {
    testWidgets('renders empty state and disabled collapse button when empty', (
      tester,
    ) async {
      var collapseInvoked = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppServerSelectorPane<_TestServerItem>(
              connections: const [],
              title: 'Server Selector',
              subtitle: '0 available',
              headerIcon: Icons.dns_outlined,
              collapseTooltip: 'Collapse',
              reorderTooltip: 'Reorder',
              collapseButtonKey: const ValueKey('collapse_btn'),
              emptyState: const Text('No servers available'),
              onCollapse: () => collapseInvoked = true,
              onReorder: (_, _) {},
              tileBuilder: (context, conn, compact) => Text(conn.name),
            ),
          ),
        ),
      );

      expect(find.text('Server Selector'), findsOneWidget);
      expect(find.text('0 available'), findsOneWidget);
      expect(find.byIcon(Icons.dns_outlined), findsOneWidget);
      expect(find.text('No servers available'), findsOneWidget);

      final iconButton = tester.widget<IconButton>(
        find.byKey(const ValueKey('collapse_btn')),
      );
      expect(iconButton.onPressed, isNull);
      expect(collapseInvoked, isFalse);
    });

    testWidgets('renders list with drag handles and triggers actions', (
      tester,
    ) async {
      var collapseInvoked = false;
      int? reorderOld;
      int? reorderNew;

      final items = [
        const _TestServerItem(
          id: 'srv-1',
          name: 'Server Alpha',
          address: 'root@alpha:22',
        ),
        const _TestServerItem(
          id: 'srv-2',
          name: 'Server Beta',
          address: 'root@beta:22',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppServerSelectorPane<_TestServerItem>(
              connections: items,
              title: 'Server Selector',
              subtitle: '2 available',
              headerIcon: Icons.dns_outlined,
              collapseTooltip: 'Collapse',
              reorderTooltip: 'Reorder',
              collapseButtonKey: const ValueKey('collapse_btn'),
              dragHandleKeyBuilder: (item) => ValueKey('drag_${item.id}'),
              emptyState: const Text('No servers'),
              onCollapse: () => collapseInvoked = true,
              onReorder: (oldIndex, newIndex) {
                reorderOld = oldIndex;
                reorderNew = newIndex;
              },
              tileBuilder: (context, item, compact) =>
                  Text('Tile: ${item.name}'),
            ),
          ),
        ),
      );

      expect(find.text('Tile: Server Alpha'), findsOneWidget);
      expect(find.text('Tile: Server Beta'), findsOneWidget);
      expect(find.byKey(const ValueKey('drag_srv-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('drag_srv-2')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('collapse_btn')));
      await tester.pump();
      expect(collapseInvoked, isTrue);

      final reorderableFinder = find.byType(ReorderableListView);
      expect(reorderableFinder, findsOneWidget);
      final reorderable = tester.widget<ReorderableListView>(reorderableFinder);
      reorderable.onReorderItem?.call(0, 1);
      expect(reorderOld, 0);
      expect(reorderNew, 1);
    });

    testWidgets('renders cleanly under narrow constraints without overflow', (
      tester,
    ) async {
      final items = [
        const _TestServerItem(
          id: 'srv-1',
          name: 'Server Alpha',
          address: 'root@alpha:22',
        ),
      ];

      for (final width in [44.0, 68.0, 120.0, 200.0]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: width,
                  height: 400,
                  child: AppServerSelectorPane<_TestServerItem>(
                    connections: items,
                    title: 'Server Selector',
                    subtitle: '1 available',
                    headerIcon: Icons.dns_outlined,
                    collapseTooltip: 'Collapse',
                    reorderTooltip: 'Reorder',
                    collapseButtonKey: const ValueKey('collapse_btn'),
                    emptyState: const Text('No servers'),
                    onCollapse: () {},
                    onReorder: (_, _) {},
                    tileBuilder: (context, item, compact) =>
                        Text('Tile: ${item.name}'),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('AppServerSelectorStrip', () {
    testWidgets('renders empty placeholder when no items', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppServerSelectorStrip<_TestServerItem>(
              connections: const [],
              semanticsLabel: 'Strip',
              noConnectionsLabel: 'No servers',
              collapseTooltip: 'Collapse',
              onCollapse: () {},
              tileBuilder: (_, item, _) => Text(item.name),
            ),
          ),
        ),
      );

      expect(find.text('No servers'), findsOneWidget);
    });

    testWidgets('renders horizontal list with centered collapse button', (
      tester,
    ) async {
      var collapseInvoked = false;
      final items = [
        const _TestServerItem(
          id: 'srv-1',
          name: 'Server Alpha',
          address: 'root@alpha:22',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppServerSelectorStrip<_TestServerItem>(
              connections: items,
              semanticsLabel: 'Strip',
              noConnectionsLabel: 'No servers',
              collapseTooltip: 'Collapse',
              collapseButtonKey: const ValueKey('strip_collapse_btn'),
              onCollapse: () => collapseInvoked = true,
              tileBuilder: (_, item, compact) => Text('Compact: ${item.name}'),
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('strip_collapse_btn')), findsOneWidget);
      final alignFinder = find.ancestor(
        of: find.byKey(const ValueKey('strip_collapse_btn')),
        matching: find.byType(Align),
      );
      expect(alignFinder, findsOneWidget);
      final align = tester.widget<Align>(alignFinder);
      expect(align.alignment, Alignment.center);

      expect(find.text('Compact: Server Alpha'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('strip_collapse_btn')));
      await tester.pump();
      expect(collapseInvoked, isTrue);
    });
  });

  group('AppServerSummaryBar', () {
    testWidgets('renders expand button, status icon, and summary text', (
      tester,
    ) async {
      var expandInvoked = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppServerSummaryBar(
              title: 'Server Alpha',
              subtitle: 'ubuntu@192.168.1.1:22',
              statusIcon: const Icon(Icons.check_circle),
              expandTooltip: 'Expand',
              expandButtonKey: const ValueKey('expand_btn'),
              onExpand: () => expandInvoked = true,
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('expand_btn')), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.text('Server Alpha  ubuntu@192.168.1.1:22'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('expand_btn')));
      await tester.pump();
      expect(expandInvoked, isTrue);
    });
  });

  group('AppServerTile', () {
    testWidgets('renders tile in compact and expanded modes', (tester) async {
      var tapInvoked = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppServerTile(
              title: 'Production Node',
              subtitle: 'admin@prod.example.com:22',
              leading: const Icon(Icons.dns),
              selected: true,
              compact: true,
              onTap: () => tapInvoked = true,
            ),
          ),
        ),
      );

      expect(find.text('Production Node'), findsOneWidget);
      expect(find.text('admin@prod.example.com:22'), findsOneWidget);
      expect(find.byIcon(Icons.dns), findsOneWidget);
      expect(find.byIcon(Icons.dns_outlined), findsOneWidget);

      await tester.tap(find.text('Production Node'));
      await tester.pump();
      expect(tapInvoked, isTrue);
    });

    testWidgets('renders cleanly in narrow width without overflow', (
      tester,
    ) async {
      for (final width in [40.0, 80.0, 140.0, 300.0]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: width,
                  child: AppServerTile(
                    title: 'Production Node',
                    subtitle: 'admin@prod.example.com:22',
                    leading: const Icon(Icons.dns),
                    selected: true,
                    compact: false,
                    onTap: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
      }
    });
  });
}
