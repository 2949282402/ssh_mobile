import 'package:flutter/material.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../theme/app_motion.dart';

/// 终端专用纯视觉占位骨架组件。
///
/// 具备终端主题自适应对比度与响应式代码行比例排版。
/// 本组件不拥有读屏语义，状态文案与 Semantics 由外层指示器统一负责。
class AppTerminalSkeleton extends StatelessWidget {
  /// 终端实际背景颜色（适配 Monokai、Nord、Solarized、Light 等不同终端配色方案）。
  final Color backgroundColor;

  const AppTerminalSkeleton({super.key, required this.backgroundColor});

  @override
  Widget build(BuildContext context) {
    final isDark =
        ThemeData.estimateBrightnessForColor(backgroundColor) ==
        Brightness.dark;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    final boneColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.08);
    final highlightColor = isDark
        ? Colors.white.withValues(alpha: 0.18)
        : Colors.black.withValues(alpha: 0.18);

    final effect = reduceMotion
        ? SolidColorEffect(color: boneColor)
        : ShimmerEffect(
            baseColor: boneColor,
            highlightColor: highlightColor,
            duration: AppMotion.shimmer,
          );

    return Container(
      color: backgroundColor,
      padding: const EdgeInsets.all(16),
      child: Skeletonizer.zone(
        enabled: true,
        effect: effect,
        child: LayoutBuilder(
          builder: (context, constraints) {
            Widget line(double factor) {
              return Bone(width: constraints.maxWidth * factor, height: 14);
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                line(0.62),
                const SizedBox(height: 10),
                line(0.88),
                const SizedBox(height: 10),
                line(0.51),
                const SizedBox(height: 10),
                line(0.24),
              ],
            );
          },
        ),
      ),
    );
  }
}
