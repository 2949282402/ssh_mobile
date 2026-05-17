import 'package:flutter/material.dart';

class OverflowScrollText extends StatefulWidget {
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
  State<OverflowScrollText> createState() => _OverflowScrollTextState();
}

class _OverflowScrollTextState extends State<OverflowScrollText> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    // These small horizontal inspectors live inside lists and expansion tiles.
    // Do not persist their offset in PageStorage, or they can collide with
    // nearby ExpansionTile bool state.
    _scrollController = ScrollController(keepScrollOffset: false);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveText = widget.text.isEmpty ? '-' : widget.text;
    final child = widget.selectable
        ? SelectableText(
            effectiveText,
            maxLines: widget.maxLines,
            style: widget.style,
          )
        : Text(
            effectiveText,
            maxLines: widget.maxLines,
            overflow: TextOverflow.visible,
            softWrap: false,
            style: widget.style,
          );
    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: false,
      child: SingleChildScrollView(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        child: child,
      ),
    );
  }
}
