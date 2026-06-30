import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

class TerminalViewArea extends StatefulWidget {
  final GlobalKey<TerminalViewState> terminalViewKey;
  final Terminal terminal;
  final TerminalController controller;
  final FocusNode focusNode;
  final TerminalTheme theme;
  final double fontSize;
  final double minFontSize;
  final double maxFontSize;
  final ValueChanged<double> onFontSizeChanged;
  final VoidCallback onScaleEnd;
  final PointerDownEventListener onPointerDown;
  final PointerMoveEventListener onPointerMove;
  final PointerUpEventListener onPointerUp;
  final PointerCancelEventListener onPointerCancel;
  final void Function(TapUpDetails details)? onSecondaryTapUp;
  final bool useWindowsCommandInput;

  const TerminalViewArea({
    super.key,
    required this.terminalViewKey,
    required this.terminal,
    required this.controller,
    required this.focusNode,
    required this.theme,
    required this.fontSize,
    required this.minFontSize,
    required this.maxFontSize,
    required this.onFontSizeChanged,
    required this.onScaleEnd,
    required this.onPointerDown,
    required this.onPointerMove,
    required this.onPointerUp,
    required this.onPointerCancel,
    this.onSecondaryTapUp,
    this.useWindowsCommandInput = false,
  });

  @override
  State<TerminalViewArea> createState() => _TerminalViewAreaState();
}

class _TerminalViewAreaState extends State<TerminalViewArea> {
  static const double _scaleDeadZone = 0.015;
  static const double _minFontSizeStep = 0.24;
  static const double _fontSizeStep = 0.25;
  static const double _bottomTolerance = 10.0;

  late final ScrollController _scrollController;
  final Map<int, Offset> _activePointers = <int, Offset>{};
  bool _trackingPinch = false;
  double _pinchStartDistance = 0;
  double _pinchStartFontSize = 0;
  double _lastAppliedFontSize = 0;
  final ValueNotifier<_TerminalScrollMetrics> _scrollMetrics =
      ValueNotifier(const _TerminalScrollMetrics());
  TerminalStyle? _cachedTerminalStyle;
  double? _cachedStyleFontSize;
  double? _cachedStyleLineHeight;
  String? _cachedStyleFontFamily;
  List<String>? _cachedStyleFontFallback;
  bool _draggingScrollbar = false;
  bool _userReadingHistory = false;
  bool _metricsUpdateScheduled = false;
  bool _isSyncing = false;
  bool _jumpScheduled = false;

  bool get _isWindowsTerminalTarget {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  }

  bool get _useHardwareKeyboardOnlyTerminalInput {
    return !kIsWeb &&
        (widget.useWindowsCommandInput ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux);
  }

  String get _terminalFontFamily {
    if (_isWindowsTerminalTarget) {
      return 'Cascadia Mono';
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
      return 'Menlo';
    }
    return 'monospace';
  }

  List<String> get _terminalFontFallback {
    if (_isWindowsTerminalTarget) {
      return const [
        'Consolas',
        'Courier New',
        'Microsoft YaHei Mono',
        'Noto Sans Mono CJK SC',
        'monospace',
      ];
    }
    return const [
      'Roboto Mono',
      'Noto Sans Mono',
      'Noto Sans Mono CJK SC',
      'Droid Sans Mono',
      'monospace',
    ];
  }

  double get _terminalLineHeight {
    if (_isWindowsTerminalTarget) {
      return 1.05;
    }
    return 1.2;
  }

  TerminalStyle get _terminalStyle {
    final fontSize = widget.fontSize;
    final lineHeight = _terminalLineHeight;
    final fontFamily = _terminalFontFamily;
    final fontFallback = _terminalFontFallback;
    final cached = _cachedTerminalStyle;
    if (cached != null &&
        _cachedStyleFontSize == fontSize &&
        _cachedStyleLineHeight == lineHeight &&
        _cachedStyleFontFamily == fontFamily &&
        listEquals(_cachedStyleFontFallback, fontFallback)) {
      return cached;
    }

    final style = TerminalStyle(
      fontSize: fontSize,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFallback,
      height: lineHeight,
    );
    _cachedTerminalStyle = style;
    _cachedStyleFontSize = fontSize;
    _cachedStyleLineHeight = lineHeight;
    _cachedStyleFontFamily = fontFamily;
    _cachedStyleFontFallback = fontFallback;
    return style;
  }

  TextInputType get _terminalKeyboardType {
    return _isWindowsTerminalTarget
        ? TextInputType.text
        : TextInputType.emailAddress;
  }

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _scrollController.addListener(_syncScrollMetrics);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_syncScrollMetrics);
    _scrollController.dispose();
    _scrollMetrics.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TerminalViewArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.fontSize - widget.fontSize).abs() > 0.01) {
      _scheduleTerminalLayoutRefresh();
    }
  }

  void _syncScrollMetrics() {
    if (!mounted || _isSyncing) return;
    _isSyncing = true;
    try {
      _metricsUpdateScheduled = false;
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      final nextMax = position.maxScrollExtent;
      var nextPixels = position.pixels.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );

      final shouldFollowOutput = !_draggingScrollbar && !_userReadingHistory;
      if (shouldFollowOutput && nextMax > 0) {
        final distanceFromBottom = nextMax - nextPixels;
        if (distanceFromBottom > _bottomTolerance) {
          nextPixels = nextMax;
          _scheduleFollowOutputJump();
        }
      }

      final current = _scrollMetrics.value;
      if ((nextPixels - current.pixels).abs() < 0.5 &&
          (nextMax - current.maxScrollExtent).abs() < 0.5) {
        return;
      }
      _scrollMetrics.value = _TerminalScrollMetrics(
        pixels: nextPixels,
        maxScrollExtent: nextMax,
      );
    } finally {
      _isSyncing = false;
    }
  }

  void _scheduleFollowOutputJump() {
    if (_jumpScheduled) return;
    _jumpScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpScheduled = false;
      if (!mounted ||
          !_scrollController.hasClients ||
          _draggingScrollbar ||
          _userReadingHistory) {
        return;
      }
      final max = _scrollController.position.maxScrollExtent;
      _isSyncing = true;
      try {
        _scrollController.jumpTo(max);
      } finally {
        _isSyncing = false;
      }
      _syncScrollMetrics();
    });
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    _scheduleMetricsUpdate();
    if (_draggingScrollbar) return false;

    final metrics = notification.metrics;
    final atBottom =
        (metrics.maxScrollExtent - metrics.pixels).abs() <= _bottomTolerance;
    final isUserScroll = notification is UserScrollNotification ||
        (notification is ScrollUpdateNotification &&
            notification.dragDetails != null);
    if (isUserScroll) {
      _userReadingHistory = !atBottom;
    }
    return false;
  }

  bool _handleScrollMetricsNotification(
      ScrollMetricsNotification notification) {
    _scheduleMetricsUpdate();
    return false;
  }

  void _resetPinch() {
    _trackingPinch = false;
    _pinchStartDistance = 0;
    _pinchStartFontSize = 0;
    _lastAppliedFontSize = 0;
  }

  @override
  Widget build(BuildContext context) {
    _scheduleMetricsUpdate();

    return Stack(
      children: [
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _handlePointerDown,
            onPointerMove: _handlePointerMove,
            onPointerUp: _handlePointerUp,
            onPointerCancel: _handlePointerCancel,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 20, 4),
              child: NotificationListener<ScrollMetricsNotification>(
                onNotification: _handleScrollMetricsNotification,
                child: NotificationListener<ScrollNotification>(
                  onNotification: _handleScrollNotification,
                  child: RepaintBoundary(
                    child: ClipRect(
                      child: TerminalView(
                        key: widget.terminalViewKey,
                        widget.terminal,
                        controller: widget.controller,
                        focusNode: widget.focusNode,
                        scrollController: _scrollController,
                        autofocus: true,
                        backgroundOpacity: 1,
                        simulateScroll: false,
                        hardwareKeyboardOnly:
                            _useHardwareKeyboardOnlyTerminalInput,
                        onKeyEvent: _handleWindowsCtrlCSelectionCopy,
                        keyboardType: _terminalKeyboardType,
                        onSecondaryTapUp: widget.onSecondaryTapUp == null
                            ? null
                            : (details, _) => widget.onSecondaryTapUp!(details),
                        textStyle: _terminalStyle,
                        textScaler: TextScaler.noScaling,
                        theme: widget.theme,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 8,
          right: 4,
          bottom: 8,
          child: ValueListenableBuilder<_TerminalScrollMetrics>(
            valueListenable: _scrollMetrics,
            builder: (context, metrics, _) {
              return _TerminalHistoryScrollbar(
                pixels: metrics.pixels,
                maxScrollExtent: metrics.maxScrollExtent,
                onInteractionStart: _startScrollbarInteraction,
                onInteractionEnd: _endScrollbarInteraction,
                onScrollFractionChanged: _jumpToScrollFraction,
              );
            },
          ),
        ),
      ],
    );
  }

  KeyEventResult _handleWindowsCtrlCSelectionCopy(
    FocusNode focusNode,
    KeyEvent event,
  ) {
    if (!_isWindowsTerminalTarget ||
        event is KeyUpEvent ||
        event.logicalKey != LogicalKeyboardKey.keyC ||
        !HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return KeyEventResult.ignored;
    }

    final selection = widget.controller.selection;
    if (selection == null) return KeyEventResult.ignored;

    final text = widget.terminal.buffer.getText(selection);
    if (text.isEmpty) return KeyEventResult.ignored;

    Clipboard.setData(ClipboardData(text: text));
    return KeyEventResult.handled;
  }

  void _jumpToScrollFraction(double fraction) {
    final maxScrollExtent = _scrollMetrics.value.maxScrollExtent;
    if (!_scrollController.hasClients || maxScrollExtent <= 0) return;
    final target = (maxScrollExtent * fraction).clamp(0.0, maxScrollExtent);
    _userReadingHistory = (maxScrollExtent - target) > _bottomTolerance;
    _isSyncing = true;
    try {
      _jumpToScrollOffset(target);
    } finally {
      _isSyncing = false;
    }
    _syncScrollMetrics();
  }

  void _handlePointerDown(PointerDownEvent event) {
    _activePointers[event.pointer] = event.localPosition;
    if (_activePointers.length < 2) _resetPinch();
    widget.onPointerDown(event);
  }

  void _handlePointerMove(PointerMoveEvent event) {
    _activePointers[event.pointer] = event.localPosition;
    widget.onPointerMove(event);
    if (_activePointers.length < 2) {
      return;
    }

    final points = _activePointers.values.take(2).toList(growable: false);
    final distance = (points[0] - points[1]).distance;
    if (distance <= 0) return;

    if (!_trackingPinch) {
      _trackingPinch = true;
      _pinchStartDistance = distance;
      _pinchStartFontSize = widget.fontSize;
      _lastAppliedFontSize = widget.fontSize;
      return;
    }

    final relativeScale = distance / _pinchStartDistance;
    if ((relativeScale - 1).abs() < _scaleDeadZone) return;

    final rawSize = (_pinchStartFontSize * relativeScale).clamp(
      widget.minFontSize,
      widget.maxFontSize,
    );
    final nextSize = _quantizeFontSize(rawSize);
    if ((nextSize - _lastAppliedFontSize).abs() < _minFontSizeStep) return;

    _lastAppliedFontSize = nextSize;
    widget.onFontSizeChanged(nextSize);
    _scheduleTerminalLayoutRefresh();
  }

  void _handlePointerUp(PointerUpEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.length < 2) {
      final changed = _trackingPinch;
      _resetPinch();
      if (changed) widget.onScaleEnd();
    }
    widget.onPointerUp(event);
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.length < 2) {
      final changed = _trackingPinch;
      _resetPinch();
      if (changed) widget.onScaleEnd();
    }
    widget.onPointerCancel(event);
  }

  void _jumpToScrollOffset(double offset) {
    if (!_scrollController.hasClients) return;
    final target = offset.clamp(
      _scrollController.position.minScrollExtent,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.jumpTo(target);
  }

  double _quantizeFontSize(double size) {
    final stepped = (size / _fontSizeStep).round() * _fontSizeStep;
    return stepped.clamp(widget.minFontSize, widget.maxFontSize);
  }

  void _startScrollbarInteraction() {
    _draggingScrollbar = true;
  }

  void _endScrollbarInteraction() {
    _draggingScrollbar = false;
    _syncScrollMetrics();
  }

  void _scheduleMetricsUpdate() {
    if (_metricsUpdateScheduled) return;
    _metricsUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncScrollMetrics();
    });
  }

  void _scheduleTerminalLayoutRefresh() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        final renderTerminal =
            widget.terminalViewKey.currentState?.renderTerminal;
        renderTerminal?.markNeedsLayout();
        renderTerminal?.markNeedsPaint();
      } catch (_) {
        // The xterm render object may be briefly detached during page switches.
      }
      if (!_userReadingHistory && _scrollController.hasClients) {
        final max = _scrollController.position.maxScrollExtent;
        _isSyncing = true;
        try {
          _scrollController.jumpTo(max);
        } finally {
          _isSyncing = false;
        }
      }
      _scheduleMetricsUpdate();
    });
  }
}

class _TerminalScrollMetrics {
  final double pixels;
  final double maxScrollExtent;

  const _TerminalScrollMetrics({
    this.pixels = 0,
    this.maxScrollExtent = 0,
  });
}

class _TerminalHistoryScrollbar extends StatelessWidget {
  final double pixels;
  final double maxScrollExtent;
  final VoidCallback onInteractionStart;
  final VoidCallback onInteractionEnd;
  final ValueChanged<double> onScrollFractionChanged;

  const _TerminalHistoryScrollbar({
    required this.pixels,
    required this.maxScrollExtent,
    required this.onInteractionStart,
    required this.onInteractionEnd,
    required this.onScrollFractionChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final enabled = maxScrollExtent > 1;
    final fraction = enabled ? (pixels / maxScrollExtent).clamp(0.0, 1.0) : 1.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final trackHeight = constraints.maxHeight;
        final visibleRatio = enabled
            ? (trackHeight / (trackHeight + maxScrollExtent)).clamp(0.08, 1.0)
            : 1.0;
        final thumbHeight = (trackHeight * visibleRatio).clamp(
          36.0,
          trackHeight,
        );
        final travel = (trackHeight - thumbHeight).clamp(0.0, trackHeight);
        final thumbTop = travel * fraction;

        void updateFromLocalY(double y) {
          if (!enabled || trackHeight <= thumbHeight) return;
          final next = ((y - thumbHeight / 2) / travel).clamp(0.0, 1.0);
          onScrollFractionChanged(next);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            onInteractionStart();
            updateFromLocalY(details.localPosition.dy);
          },
          onTapUp: (_) => onInteractionEnd(),
          onTapCancel: onInteractionEnd,
          onVerticalDragStart: (details) {
            onInteractionStart();
            updateFromLocalY(details.localPosition.dy);
          },
          onVerticalDragUpdate: (details) =>
              updateFromLocalY(details.localPosition.dy),
          onVerticalDragEnd: (_) => onInteractionEnd(),
          onVerticalDragCancel: onInteractionEnd,
          child: SizedBox(
            width: 16,
            child: Stack(
              alignment: Alignment.topCenter,
              children: [
                Positioned.fill(
                  left: 6,
                  right: 6,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colorScheme.onSurface.withValues(
                        alpha: enabled ? 0.16 : 0.06,
                      ),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                Positioned(
                  top: thumbTop,
                  width: 12,
                  height: thumbHeight,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: enabled
                          ? colorScheme.primary.withValues(alpha: 0.88)
                          : colorScheme.onSurface.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
