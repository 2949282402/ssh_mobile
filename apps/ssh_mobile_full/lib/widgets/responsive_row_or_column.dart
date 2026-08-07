import 'package:flutter/material.dart';
import '../utils/responsive.dart';

class ResponsiveRowOrColumn extends StatelessWidget {
  final List<Widget> children;
  final List<int> flexes;
  final double spacing;

  const ResponsiveRowOrColumn({
    super.key,
    required this.children,
    this.flexes = const [],
    this.spacing = 12.0,
  });

  @override
  Widget build(BuildContext context) {
    final desktop = isDesktopLayout(context);
    if (desktop) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < children.length; i++) ...[
            if (i > 0) SizedBox(width: spacing),
            Expanded(
              flex: flexes.length > i ? flexes[i] : 1,
              child: children[i],
            ),
          ],
        ],
      );
    } else {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (int i = 0; i < children.length; i++) ...[
            if (i > 0) SizedBox(height: spacing),
            children[i],
          ],
        ],
      );
    }
  }
}
