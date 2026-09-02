import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_loading.dart';

/// 连接准备阶段使用的不可取消进度 UI 和动画时序工具。
const Duration _connectionProgressAnimationDuration = Duration(
  milliseconds: 180,
);

/// 等待进度框首帧与入场动画完成，避免连接流程抢占 UI 转场。
Future<void> waitForConnectionProgressFrame() async {
  await WidgetsBinding.instance.endOfFrame;
  // Let the entrance animation settle before SSH setup starts.
  await Future<void>.delayed(_connectionProgressAnimationDuration);
  await Future<void>.delayed(const Duration(milliseconds: 16));
}

/// 显示不可取消的连接进度，避免用户在 SSH 初始化中误触返回。
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
          duration: _connectionProgressAnimationDuration,
          curve: Curves.easeOutCubic,
          builder: (context, value, child) {
            return Opacity(
              opacity: value,
              child: Transform.scale(scale: 0.96 + value * 0.04, child: child),
            );
          },
          child: Material(
            color: colorScheme.surface,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
              side: BorderSide(color: colorScheme.outline, width: 1),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppLoadingIndicator(
                      size: 42,
                      strokeWidth: 3,
                      color:
                          Theme.of(
                            context,
                          ).extension<ExtendedColors>()?.success ??
                          AppTheme.terminalGreen,
                    ),
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
