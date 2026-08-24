import 'package:flutter/material.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../theme/app_motion.dart';

/// 统一骨架屏包装组件。
///
/// 具备主题多调色板自适应微光、Reduced Motion 无障碍降级、读屏语义管理和点击拦截能力。
class AppSkeletonizer extends StatelessWidget {
  /// 是否处于骨架屏占位状态。
  final bool enabled;

  /// 是否启用骨架屏与真实内容之间的平滑切换动画。默认为 true。
  final bool animateTransition;

  /// 骨架屏状态下的读屏无障碍提示文本（非空必填）。
  final String semanticsLabel;

  /// 是否为手工 Bone 区域模式。
  final bool zone;

  /// 被包装的子组件。
  final Widget child;

  /// 默认声明式构造函数（自动将子 Widget 的 Text/Icon/Container 转换为骨架）。
  const AppSkeletonizer({
    super.key,
    required this.enabled,
    required this.semanticsLabel,
    this.animateTransition = true,
    required this.child,
  }) : zone = false;

  /// 手工区域构造函数（配合 [Bone] 组件构建定制化占位布局）。
  const AppSkeletonizer.zone({
    super.key,
    required this.enabled,
    required this.semanticsLabel,
    this.animateTransition = true,
    required this.child,
  }) : zone = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final scheme = theme.colorScheme;

    final baseColor = Color.alphaBlend(
      scheme.primary.withValues(alpha: isDark ? 0.04 : 0.025),
      scheme.surfaceContainerHighest,
    );
    final highlightColor = Color.alphaBlend(
      scheme.primary.withValues(alpha: isDark ? 0.08 : 0.05),
      isDark ? scheme.surface : Colors.white.withValues(alpha: 0.85),
    );

    final effect = reduceMotion
        ? SolidColorEffect(color: baseColor)
        : ShimmerEffect(
            baseColor: baseColor,
            highlightColor: highlightColor,
            duration: AppMotion.shimmer,
          );

    final enableSwitch = animateTransition && !reduceMotion;
    const switchConfig = SwitchAnimationConfig(
      duration: AppMotion.standard,
      switchInCurve: AppMotion.standardEasing,
    );

    final skeletonChild = zone
        ? Skeletonizer.zone(
            enabled: enabled,
            effect: effect,
            enableSwitchAnimation: enableSwitch,
            switchAnimationConfig: switchConfig,
            child: child,
          )
        : Skeletonizer(
            enabled: enabled,
            effect: effect,
            enableSwitchAnimation: enableSwitch,
            switchAnimationConfig: switchConfig,
            child: child,
          );

    return Semantics(
      container: enabled,
      liveRegion: enabled,
      excludeSemantics: enabled,
      label: enabled ? semanticsLabel : null,
      child: IgnorePointer(ignoring: enabled, child: skeletonChild),
    );
  }
}
