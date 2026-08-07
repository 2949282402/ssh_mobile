import 'package:flutter/material.dart';

import 'package:ssh_mobile/theme/app_theme.dart';

class SectionCard extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final Widget? trailing;
  final bool isCollapsible;
  final bool isExpanded;
  final VoidCallback? onToggle;

  const SectionCard({
    super.key,
    required this.title,
    required this.children,
    this.trailing,
    this.isCollapsible = false,
    this.isExpanded = true,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.72)),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
              if (isCollapsible && onToggle != null)
                IconButton(
                  icon: Icon(
                    isExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                  ),
                  onPressed: onToggle,
                )
              else
                ?trailing,
            ],
          ),
          if (isExpanded) ...[const SizedBox(height: 12), ...children],
        ],
      ),
    );
  }
}
