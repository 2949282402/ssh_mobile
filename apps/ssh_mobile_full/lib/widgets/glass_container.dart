import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:app_ui/app_ui.dart';

/// A restrained translucent surface for compact floating controls.
///
/// Avoid using this for large scrolling panels because backdrop blur is more
/// expensive than the tonal surfaces used by the primary page shell.
class GlassmorphicContainer extends StatelessWidget {
  final Widget? child;
  final double borderRadius;
  final double blurX;
  final double blurY;
  final Color? backgroundColor;
  final Color? borderColor;
  final double borderWidth;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final AlignmentGeometry? alignment;

  const GlassmorphicContainer({
    super.key,
    this.child,
    this.borderRadius = AppTheme.radiusLarge,
    this.blurX = 18.0,
    this.blurY = 18.0,
    this.backgroundColor,
    this.borderColor,
    this.borderWidth = 1.0,
    this.padding,
    this.margin,
    this.width,
    this.height,
    this.alignment,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final extColors = theme.extension<ExtendedColors>();

    final defaultBgColor =
        extColors?.glassBg ??
        (isDark
            ? theme.colorScheme.surface.withValues(alpha: 0.65)
            : theme.colorScheme.surface.withValues(alpha: 0.70));

    final defaultBorderColor =
        extColors?.glassBorder ??
        (isDark
            ? Colors.white.withValues(alpha: 0.08)
            : theme.colorScheme.primary.withValues(alpha: 0.12));

    return Container(
      width: width,
      height: height,
      margin: margin,
      alignment: alignment,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.06),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blurX, sigmaY: blurY),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: backgroundColor ?? defaultBgColor,
              borderRadius: BorderRadius.circular(borderRadius),
              border: Border.all(
                color: borderColor ?? defaultBorderColor,
                width: borderWidth,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
