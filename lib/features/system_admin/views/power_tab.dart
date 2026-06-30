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
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.power_settings_new,
                size: 96, color: widget.colorScheme.error),
            const SizedBox(height: 24),
            Text(
              widget.strings.systemPower,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              widget.strings.systemPowerHint,
              textAlign: TextAlign.center,
              style: TextStyle(color: widget.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 36),
            SizedBox(
              width: 250,
              child: FilledButton.icon(
                icon: const Icon(Icons.cached),
                label: Text(widget.strings.rebootServer),
                style: FilledButton.styleFrom(
                  backgroundColor: widget.colorScheme.tertiary,
                  padding: const EdgeInsets.all(16),
                ),
                onPressed: () => _confirmPowerAction(SystemPowerAction.reboot),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: 250,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.power_off),
                label: Text(widget.strings.shutdownServer),
                style: OutlinedButton.styleFrom(
                  foregroundColor: widget.colorScheme.error,
                  side: BorderSide(color: widget.colorScheme.error),
                  padding: const EdgeInsets.all(16),
                ),
                onPressed: () =>
                    _confirmPowerAction(SystemPowerAction.shutdown),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmPowerAction(SystemPowerAction action) async {
    final language = context.read<AppSettings>().language;
    final token = await confirmSystemPowerAction(
      context,
      action: action,
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
      widget.viewModel.disconnect();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to execute power action: $e')),
      );
    }
  }
}
