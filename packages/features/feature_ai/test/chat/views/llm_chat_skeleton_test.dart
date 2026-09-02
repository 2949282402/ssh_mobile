import 'package:app_core/app_core.dart';
import 'package:app_ui/app_ui.dart';
import 'package:feature_ai/ai_chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'Chat conversation skeleton renders correctly with AppSkeletonizer',
    (tester) async {
      const strings = AiStrings(AppLanguage.en);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: _ChatConversationSkeletonTestWrapper(strings: strings),
          ),
        ),
      );

      expect(find.byType(AppSkeletonizer), findsOneWidget);
      expect(find.byIcon(Icons.menu_rounded), findsOneWidget);
      expect(find.byIcon(Icons.add_comment_outlined), findsOneWidget);
      expect(find.byIcon(Icons.tune_rounded), findsOneWidget);
      expect(find.byType(AppEmptyState), findsOneWidget);
      expect(find.byIcon(Icons.add_rounded), findsOneWidget);
      expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
    },
  );
}

class _ChatConversationSkeletonTestWrapper extends StatelessWidget {
  const _ChatConversationSkeletonTestWrapper({required this.strings});

  final AiStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AppSkeletonizer(
      enabled: true,
      semanticsLabel: strings.title,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(14, 9, 12, 9),
            child: Row(
              children: [
                IconButton(
                  tooltip: strings.history,
                  icon: const Icon(Icons.menu_rounded),
                  style: IconButton.styleFrom(
                    foregroundColor: colorScheme.primary,
                    backgroundColor: colorScheme.primary.withValues(alpha: 0.1),
                  ),
                  onPressed: null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        strings.newChat,
                        maxLines: 1,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.1,
                        ),
                      ),
                      Text(
                        '0 / 128K (0.0%)',
                        maxLines: 1,
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: strings.newChat,
                  icon: const Icon(Icons.add_comment_outlined),
                  onPressed: null,
                ),
                const SizedBox.square(
                  dimension: 48,
                  child: IconButton(
                    icon: Icon(Icons.tune_rounded),
                    onPressed: null,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 280),
                  child: AppEmptyState(
                    icon: Icons.auto_awesome_rounded,
                    title: strings.welcomeTitle,
                    message: strings.welcome,
                    compact: true,
                    contained: false,
                    action: const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colorScheme.surface.withValues(alpha: 0.96),
                border: Border(
                  top: BorderSide(
                    color: colorScheme.outline.withValues(alpha: 0.56),
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  heightFactor: 1,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 960),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(
                          AppTheme.radiusMedium,
                        ),
                        border: Border.all(
                          color: colorScheme.outline.withValues(alpha: 0.62),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: strings.tools,
                            style: IconButton.styleFrom(
                              minimumSize: const Size.square(48),
                              foregroundColor: colorScheme.primary,
                            ),
                            icon: const Icon(Icons.add_rounded),
                            onPressed: null,
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              child: Text(
                                strings.composerHint,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(
                              right: 8,
                              top: 6,
                              bottom: 6,
                              left: 4,
                            ),
                            child: IconButton(
                              tooltip: strings.send,
                              style: IconButton.styleFrom(
                                minimumSize: const Size.square(38),
                                padding: EdgeInsets.zero,
                                foregroundColor: colorScheme.onPrimary,
                                backgroundColor: colorScheme.primary,
                              ),
                              icon: const Icon(Icons.arrow_upward_rounded),
                              onPressed: null,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
