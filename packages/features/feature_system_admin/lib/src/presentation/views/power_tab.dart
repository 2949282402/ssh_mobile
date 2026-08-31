// System Admin Power Tab：执行受确认 Token 保护的重启和关机操作。

part of 'system_admin_screen.dart';

class _PowerTab extends StatefulWidget {
  final AppStrings strings;
  final ColorScheme colorScheme;
  final SystemAdminViewModel viewModel;

  const _PowerTab({
    required this.strings,
    required this.colorScheme,
    required this.viewModel,
  });

  @override
  State<_PowerTab> createState() => _PowerTabState();
}

class _PowerTabState extends State<_PowerTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: widget.colorScheme.error.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                  border: Border.all(
                    color: widget.colorScheme.error.withValues(alpha: 0.2),
                  ),
                ),
                child: Icon(
                  Icons.power_settings_new,
                  size: 28,
                  color: widget.colorScheme.error,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                widget.strings.systemPower,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                widget.strings.systemPowerHint,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: widget.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: 240,
                child: FilledButton.icon(
                  icon: const Icon(Icons.cached, size: 18),
                  label: Text(widget.strings.rebootServer),
                  style: FilledButton.styleFrom(
                    backgroundColor: widget.colorScheme.tertiary,
                    foregroundColor: widget.colorScheme.onTertiary,
                    minimumSize: const Size.fromHeight(44),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                    ),
                  ),
                  onPressed: () =>
                      _confirmPowerAction(SystemPowerAction.reboot),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: 240,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.power_off, size: 18),
                  label: Text(widget.strings.shutdownServer),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: widget.colorScheme.error,
                    side: BorderSide(color: widget.colorScheme.error),
                    minimumSize: const Size.fromHeight(44),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                    ),
                  ),
                  onPressed: () =>
                      _confirmPowerAction(SystemPowerAction.shutdown),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmPowerAction(SystemPowerAction action) async {
    final target = widget.viewModel.activeManagementTarget;
    if (target == null) return;
    final language = context.read<AppSettings>().language;
    final token = await confirmSystemPowerAction(
      context,
      action: action,
      target: target,
      isEnglish: language == AppLanguage.en,
    );

    if (!mounted || token == null) return;

    try {
      if (action == SystemPowerAction.reboot) {
        await widget.viewModel.rebootServer(token);
      } else {
        await widget.viewModel.shutdownServer(token);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Command executed. Disconnecting...')),
      );
      await widget.viewModel.disconnectTarget(token.target);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to execute power action: $e')),
      );
    }
  }
}
