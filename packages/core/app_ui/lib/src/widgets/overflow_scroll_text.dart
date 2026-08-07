import 'package:flutter/material.dart';

/// 在横向空间不足时提供可选文本和横向滚动查看能力。
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
  late final PageStorageBucket _pageStorageBucket;

  @override
  void initState() {
    super.initState();
    _pageStorageBucket = PageStorageBucket();
    // 这些小型横向查看器常位于列表和展开面板中。
    // These small horizontal inspectors live inside lists and expansion tiles.
    // Isolate their storage bucket as well: Flutter can still consult
    // PageStorage during scrollable mount, and nearby ExpansionTile bool state
    // otherwise collides with the horizontal scroll offset slot.
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
    return PageStorage(
      bucket: _pageStorageBucket,
      child: Scrollbar(
        controller: _scrollController,
        thumbVisibility: false,
        child: SingleChildScrollView(
          controller: _scrollController,
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          child: child,
        ),
      ),
    );
  }
}
