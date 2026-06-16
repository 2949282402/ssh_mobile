import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

const Duration _connectionProgressAnimationDuration = Duration(
  milliseconds: 180,
);

Future<void> waitForConnectionProgressFrame() async {
  await WidgetsBinding.instance.endOfFrame;
  // Let the entrance animation settle before SSH setup starts. Connection
  // preparation can parse keys or hit secure storage and otherwise steals the
  // spinner's first frames on the UI isolate.
  await Future<void>.delayed(_connectionProgressAnimationDuration);
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
          duration: _connectionProgressAnimationDuration,
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
                    const SizedBox(
                      width: 42,
                      height: 42,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: AppTheme.terminalGreen,
                      ),
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
