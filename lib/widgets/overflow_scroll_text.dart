import 'package:flutter/material.dart';

class OverflowScrollText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final bool selectable;
  final int? maxLines;

  const OverflowScrollText(
    this.text, {
    super.key,
    this.style,
    this.selectable = true,
    this.maxLines,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveText = text.isEmpty ? '-' : text;
    final child = selectable
        ? SelectableText(
            effectiveText,
            maxLines: maxLines,
            style: style,
          )
        : Text(
            effectiveText,
            maxLines: maxLines,
            overflow: TextOverflow.visible,
            softWrap: false,
            style: style,
          );
    return Scrollbar(
      thumbVisibility: false,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: child,
      ),
    );
  }
}
