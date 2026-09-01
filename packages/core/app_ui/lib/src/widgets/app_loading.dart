import 'package:flutter/material.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../theme/app_theme.dart';

/// 统一的页面与操作加载指示器。
///
/// 具备克制的尺寸、笔触宽度与微光/旋转动效，符合开发者工作区标准。
class AppLoadingIndicator extends StatelessWidget {
  const AppLoadingIndicator({
    super.key,
    this.value,
    this.size = 24.0,
    this.strokeWidth = 2.0,
    this.color,
    this.backgroundColor,
    this.semanticsLabel,
  });

  final double? value;
  final double size;
  final double strokeWidth;
  final Color? color;
  final Color? backgroundColor;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final indicatorColor = color ?? theme.colorScheme.primary;

    return Semantics(
      label: semanticsLabel ?? 'Loading',
      child: Center(
        child: SizedBox(
          width: size,
          height: size,
          child: CircularProgressIndicator(
            value: value,
            strokeWidth: strokeWidth,
            valueColor: AlwaysStoppedAnimation<Color>(indicatorColor),
            backgroundColor: backgroundColor,
          ),
        ),
      ),
    );
  }
}

/// 行内操作进度指示器，用于按钮、标签或状态行旁的轻量反馈。
class AppInlineProgress extends StatelessWidget {
  const AppInlineProgress({
    super.key,
    this.size = 14.0,
    this.strokeWidth = 1.8,
    this.color,
    this.message,
  });

  final double size;
  final double strokeWidth;
  final Color? color;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final indicatorColor = color ?? theme.colorScheme.primary;

    final spinner = SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(
        strokeWidth: strokeWidth,
        valueColor: AlwaysStoppedAnimation<Color>(indicatorColor),
      ),
    );

    if (message == null || message!.isEmpty) {
      return spinner;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        spinner,
        const SizedBox(width: 6),
        Text(
          message!,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// 标准的骨架屏单行占位组件。
class AppSkeletonRow extends StatelessWidget {
  const AppSkeletonRow({
    super.key,
    this.hasLeading = true,
    this.leadingSize = 36.0,
    this.titleWidth = 140.0,
    this.subtitleWidth = 220.0,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  });

  final bool hasLeading;
  final double leadingSize;
  final double titleWidth;
  final double subtitleWidth;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (hasLeading) ...[
            Bone.square(
              size: leadingSize,
              borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Bone(width: titleWidth, height: 14),
                const SizedBox(height: 6),
                Bone(width: subtitleWidth, height: 11),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 标准的骨架屏列表占位组件。
class AppSkeletonList extends StatelessWidget {
  const AppSkeletonList({
    super.key,
    this.itemCount = 6,
    this.hasLeading = true,
    this.leadingSize = 36.0,
    this.padding = const EdgeInsets.symmetric(vertical: 8),
    this.itemPadding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  });

  final int itemCount;
  final bool hasLeading;
  final double leadingSize;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry itemPadding;

  @override
  Widget build(BuildContext context) {
    const titleWidths = [120.0, 160.0, 140.0, 180.0, 130.0, 150.0];
    const subWidths = [200.0, 240.0, 180.0, 220.0, 260.0, 190.0];

    return ListView.builder(
      padding: padding,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        final titleW = titleWidths[index % titleWidths.length];
        final subW = subWidths[index % subWidths.length];
        return AppSkeletonRow(
          hasLeading: hasLeading,
          leadingSize: leadingSize,
          titleWidth: titleW,
          subtitleWidth: subW,
          padding: itemPadding,
        );
      },
    );
  }
}
