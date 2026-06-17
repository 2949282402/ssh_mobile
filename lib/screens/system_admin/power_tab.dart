part of '../system_admin_screen.dart';

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
                onPressed: () => _confirmPowerAction('reboot'),
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
                onPressed: () => _confirmPowerAction('shutdown'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmPowerAction(String action) async {
    final colorScheme = Theme.of(context).colorScheme;
    final language = context.read<AppSettings>().language;
    final strings = AppStrings(language);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
            action == 'reboot' ? strings.rebootServer : strings.shutdownServer),
        content: Text(strings.powerConfirmContent),
        actions: [
          TextButton(
            child: Text(strings.cancel),
            onPressed: () => Navigator.pop(context, false),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.confirm),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (confirm == true) {
      try {
        if (action == 'reboot') {
          await widget.viewModel.rebootServer();
        } else {
          await widget.viewModel.shutdownServer();
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
}
