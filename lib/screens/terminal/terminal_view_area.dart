import 'package:flutter/material.dart';
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
  final PointerUpEventListener onPointerUp;
  final PointerCancelEventListener onPointerCancel;

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
    required this.onPointerUp,
    required this.onPointerCancel,
  });

  @override
  State<TerminalViewArea> createState() => _TerminalViewAreaState();
}

class _TerminalViewAreaState extends State<TerminalViewArea> {
  static const double _scaleDeadZone = 0.015;
  static const double _minFontSizeStep = 0.08;

  bool _trackingPinch = false;
  double _pinchStartFontSize = 0;
  double _pinchStartScale = 1;
  double _lastAppliedFontSize = 0;

  void _resetPinch() {
    _trackingPinch = false;
    _pinchStartFontSize = 0;
    _pinchStartScale = 1;
    _lastAppliedFontSize = 0;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: widget.onPointerDown,
      onPointerUp: widget.onPointerUp,
      onPointerCancel: widget.onPointerCancel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: (_) => _resetPinch(),
        onScaleUpdate: (details) {
          if (details.pointerCount < 2) return;

          if (!_trackingPinch) {
            _trackingPinch = true;
            _pinchStartFontSize = widget.fontSize;
            _pinchStartScale = details.scale == 0 ? 1 : details.scale;
            _lastAppliedFontSize = widget.fontSize;
            return;
          }

          final relativeScale = details.scale / _pinchStartScale;
          if ((relativeScale - 1).abs() < _scaleDeadZone) return;

          final nextSize = (_pinchStartFontSize * relativeScale).clamp(
            widget.minFontSize,
            widget.maxFontSize,
          );
          if ((nextSize - _lastAppliedFontSize).abs() < _minFontSizeStep) {
            return;
          }

          _lastAppliedFontSize = nextSize;
          widget.onFontSizeChanged(nextSize);
        },
        onScaleEnd: (_) {
          final changed = _trackingPinch;
          _resetPinch();
          if (changed) widget.onScaleEnd();
        },
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: TerminalView(
            key: widget.terminalViewKey,
            widget.terminal,
            controller: widget.controller,
            focusNode: widget.focusNode,
            autofocus: true,
            backgroundOpacity: 1,
            textStyle: TerminalStyle(fontSize: widget.fontSize),
            theme: widget.theme,
          ),
        ),
      ),
    );
  }
}
