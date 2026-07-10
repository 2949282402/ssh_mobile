import 'package:flutter/material.dart';

/// Adds one concise accessibility node to a custom home navigation item.
///
/// The visual child is excluded from semantics so screen readers announce the
/// destination once, together with its selected state and tap action.
class HomeNavigationSemantics extends StatelessWidget {
  const HomeNavigationSemantics({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.child,
    this.semanticsKey,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;
  final Key? semanticsKey;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: semanticsKey,
      container: true,
      button: true,
      selected: selected,
      label: label,
      onTap: onTap,
      child: ExcludeSemantics(child: child),
    );
  }
}
