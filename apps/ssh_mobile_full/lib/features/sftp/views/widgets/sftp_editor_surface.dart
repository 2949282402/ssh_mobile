part of '../sftp_editor_screen.dart';

class _EditorSurface extends StatefulWidget {
  const _EditorSurface({
    required this.controller,
    required this.verticalController,
    required this.horizontalController,
    required this.strings,
    required this.fontSize,
    required this.wrapLines,
    required this.readOnly,
    required this.onChanged,
  });

  final TextEditingController controller;
  final ScrollController verticalController;
  final ScrollController horizontalController;
  final AppStrings strings;
  final double fontSize;
  final bool wrapLines;
  final bool readOnly;
  final ValueChanged<String> onChanged;

  @override
  State<_EditorSurface> createState() => _EditorSurfaceState();
}

class _EditorSurfaceState extends State<_EditorSurface> {
  static const _widthRecalculationDelay = Duration(milliseconds: 220);

  Timer? _widthRecalculationTimer;
  late String _lastText;
  late double _longestColumns;

  @override
  void initState() {
    super.initState();
    _resetWidthCache();
  }

  @override
  void didUpdateWidget(covariant _EditorSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _widthRecalculationTimer?.cancel();
      _resetWidthCache();
      return;
    }
    if (oldWidget.wrapLines && !widget.wrapLines) {
      _recalculateWidth(notify: false);
    } else if (widget.controller.text != _lastText) {
      _recalculateWidth(notify: false);
    }
  }

  @override
  void dispose() {
    _widthRecalculationTimer?.cancel();
    super.dispose();
  }

  void _resetWidthCache() {
    _lastText = widget.controller.text;
    _longestColumns = _measureLongestColumns(_lastText);
  }

  void _handleTextChanged(String text) {
    if (text != _lastText) {
      final lengthDelta = text.length - _lastText.length;
      if (lengthDelta > 0) {
        _longestColumns += lengthDelta * 2;
      } else if (lengthDelta == 0) {
        _longestColumns += 2;
      }
      _lastText = text;
      _scheduleWidthRecalculation();
      if (!widget.wrapLines) setState(() {});
    }
    widget.onChanged(text);
  }

  void _scheduleWidthRecalculation() {
    _widthRecalculationTimer?.cancel();
    _widthRecalculationTimer = Timer(
      _widthRecalculationDelay,
      () => _recalculateWidth(notify: true),
    );
  }

  void _recalculateWidth({required bool notify}) {
    final text = widget.controller.text;
    final longestColumns = _measureLongestColumns(text);
    final changed = longestColumns != _longestColumns || text != _lastText;
    _lastText = text;
    _longestColumns = longestColumns;
    if (notify && changed && mounted && !widget.wrapLines) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Card(
      key: const ValueKey('sftp-editor-surface'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(color: colors.outline.withValues(alpha: 0.72)),
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        ),
        child: Semantics(
          container: true,
          label: widget.strings.remoteFileContent,
          child: widget.wrapLines
              ? _buildWrappedEditor()
              : _buildUnwrappedEditor(),
        ),
      ),
    );
  }

  Widget _buildWrappedEditor() {
    return Scrollbar(
      controller: widget.verticalController,
      child: _buildTextField(),
    );
  }

  Widget _buildUnwrappedEditor() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = _estimatedUnwrappedWidth(
          _longestColumns,
          widget.fontSize,
          constraints.maxWidth,
        );
        return Scrollbar(
          controller: widget.horizontalController,
          notificationPredicate: (notification) => notification.depth == 0,
          child: SingleChildScrollView(
            controller: widget.horizontalController,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              key: const ValueKey('sftp-editor-unwrapped-canvas'),
              width: width,
              height: constraints.maxHeight,
              child: Scrollbar(
                controller: widget.verticalController,
                child: _buildTextField(),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTextField() {
    return TextField(
      key: const ValueKey('sftp-editor-text-field'),
      controller: widget.controller,
      scrollController: widget.verticalController,
      expands: true,
      maxLines: null,
      minLines: null,
      readOnly: widget.readOnly,
      autocorrect: false,
      enableSuggestions: false,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      keyboardType: TextInputType.multiline,
      textAlignVertical: TextAlignVertical.top,
      onChanged: _handleTextChanged,
      decoration: InputDecoration(
        border: InputBorder.none,
        filled: false,
        hintText: widget.strings.remoteFileContent,
        contentPadding: const EdgeInsets.all(18),
      ),
      style: TextStyle(
        fontFamily: 'monospace',
        fontFamilyFallback: AppTheme.monospaceFallback,
        fontSize: widget.fontSize,
        height: 1.45,
      ),
    );
  }
}

double _estimatedUnwrappedWidth(
  double longestColumns,
  double fontSize,
  double viewportWidth,
) {
  final estimated = longestColumns * fontSize * 0.82 + 48;
  final practicalWidth = estimated.clamp(1600.0, 40000.0).toDouble();
  return math.max(viewportWidth, practicalWidth);
}

double _measureLongestColumns(String text) {
  var currentColumns = 0.0;
  var longestColumns = 0.0;
  for (final rune in text.runes) {
    if (rune == 0x0A || rune == 0x0D) {
      longestColumns = math.max(longestColumns, currentColumns);
      currentColumns = 0;
    } else if (rune == 0x09) {
      currentColumns += 4;
    } else {
      currentColumns += rune > 0x7F ? 2 : 1;
    }
  }
  longestColumns = math.max(longestColumns, currentColumns);
  return longestColumns;
}
