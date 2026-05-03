import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

Future<void> waitForConnectionProgressFrame() async {
  await WidgetsBinding.instance.endOfFrame;
  await Future<void>.delayed(const Duration(milliseconds: 90));
}

class ConnectionProgressDialog extends StatelessWidget {
  final String title;
  final String message;

  const ConnectionProgressDialog({
    super.key,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: false,
      child: Center(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          builder: (context, value, child) {
            return Opacity(
              opacity: value,
              child: Transform.scale(
                scale: 0.96 + value * 0.04,
                child: child,
              ),
            );
          },
          child: Material(
            color: colorScheme.surface,
            elevation: 16,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _SmoothSpinner(size: 42),
                    const SizedBox(height: 18),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurface.withValues(alpha: 0.7),
                            height: 1.35,
                          ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SmoothSpinner extends StatefulWidget {
  final double size;

  const _SmoothSpinner({required this.size});

  @override
  State<_SmoothSpinner> createState() => _SmoothSpinnerState();
}

class _SmoothSpinnerState extends State<_SmoothSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Transform.rotate(
            angle: _controller.value * math.pi * 2,
            child: CustomPaint(
              size: Size.square(widget.size),
              painter: _SpinnerPainter(
                color: AppTheme.terminalGreen,
                trackColor: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.12),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class _SpinnerPainter extends CustomPainter {
  final Color color;
  final Color trackColor;

  const _SpinnerPainter({
    required this.color,
    required this.trackColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final strokeWidth = size.width * 0.1;
    final rect = Offset.zero & size;
    final insetRect = rect.deflate(strokeWidth / 2);

    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(insetRect, 0, math.pi * 2, false, trackPaint);

    final arcPaint = Paint()
      ..shader = SweepGradient(
        colors: [
          color.withValues(alpha: 0.08),
          color.withValues(alpha: 0.35),
          color,
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(insetRect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(insetRect, -math.pi / 2, math.pi * 1.45, false, arcPaint);
  }

  @override
  bool shouldRepaint(covariant _SpinnerPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.trackColor != trackColor;
  }
}
