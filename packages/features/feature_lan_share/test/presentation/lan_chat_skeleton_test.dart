import 'package:app_ui/app_ui.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  testWidgets(
    'LanChat conversation skeleton renders correctly with AppSkeletonizer',
    (tester) async {
      final settings = FakeLanShareSettings();
      final strings = settings.strings;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: _LanChatConversationSkeletonTestWrapper(
              strings: strings,
              deviceAlias: 'Remote Desktop',
            ),
          ),
        ),
      );

      expect(find.byType(AppSkeletonizer), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.byType(AppIconBadge), findsOneWidget);
      expect(find.text('Remote Desktop'), findsOneWidget);
      expect(find.byIcon(Icons.add_circle_outline_rounded), findsOneWidget);
      expect(find.byIcon(Icons.send_rounded), findsOneWidget);
    },
  );
}

class _LanChatConversationSkeletonTestWrapper extends StatelessWidget {
  const _LanChatConversationSkeletonTestWrapper({
    required this.strings,
    required this.deviceAlias,
  });

  final LanShareStrings strings;
  final String deviceAlias;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AppSkeletonizer.zone(
      enabled: true,
      semanticsLabel: strings.lanRelayConnecting,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
            child: Row(
              children: [
                const BackButton(),
                const SizedBox(width: 4),
                const AppIconBadge(
                  icon: Icons.smartphone_rounded,
                  size: 40,
                  iconSize: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        deviceAlias,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          const Icon(
                            Icons.shield_rounded,
                            size: 12,
                            color: Color(0xFF29B6F6),
                          ),
                          const SizedBox(width: 3),
                          Text(
                            strings.lanShareOnline,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const IconButton(
                  icon: Icon(Icons.more_vert_rounded),
                  onPressed: null,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 12.0,
              ),
              children: const [Bone(width: 200, height: 48)],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
            decoration: BoxDecoration(color: Theme.of(context).cardColor),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline_rounded),
                    color: colorScheme.primary,
                    onPressed: null,
                  ),
                  Expanded(
                    child: TextField(
                      enabled: false,
                      decoration: InputDecoration(
                        hintText: strings.lanShareChatInputHint,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const IconButton(
                    icon: Icon(Icons.send_rounded),
                    onPressed: null,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
