import 'package:flutter/animation.dart';

/// 统一动效规范常量。
///
/// 集中定义骨架屏与界面微交互所需的基础时长和缓动曲线。
abstract final class AppMotion {
  /// 快速微交互（如按钮反馈、点击反馈）: 150ms
  static const Duration fast = Duration(milliseconds: 150);

  /// 标准状态切换与淡入淡出: 200ms
  static const Duration standard = Duration(milliseconds: 200);

  /// 骨架屏微光循环周期: 1200ms
  static const Duration shimmer = Duration(milliseconds: 1200);

  /// 标准缓动曲线
  static const Curve standardEasing = Curves.easeOutCubic;
}
