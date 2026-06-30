import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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
    return ShadCard(
      title: Text(
        title,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: colorScheme.primary,
        ),
      ),
      trailing: isCollapsible && onToggle != null
          ? IconButton(
              icon: Icon(isExpanded
                  ? Icons.expand_less_rounded
                  : Icons.expand_more_rounded),
              onPressed: onToggle,
            )
          : trailing,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isExpanded) ...[
            const SizedBox(height: 8),
            ...children,
          ],
        ],
      ),
    );
  }
}
