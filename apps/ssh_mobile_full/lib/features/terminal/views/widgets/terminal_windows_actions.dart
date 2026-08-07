part of '../terminal_windows_screen.dart';

extension _TerminalWindowsActions on _TerminalWindowsPageState {
  void _openWindow(BuildContext context, SshSession session) {
    Navigator.pushNamedAndRemoveUntil(
      context,
      '/terminal',
      (route) => route.isFirst,
      arguments: {'id': session.connectionId, 'sessionId': session.id},
    );
  }

  Future<void> _openNewWindow(BuildContext context, AppStrings strings) async {
    final connectionId = page.connectionId;
    if (connectionId == null) return;
    final ssh = context.read<SshService>();
    final windowName = ssh.defaultDisplayNameForConnection(connectionId);

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useSafeArea: false,
      builder: (_) => ConnectionProgressDialog(
        title: strings.connectingTo(windowName),
        message: strings.establishingConnection,
      ),
    );
    await waitForConnectionProgressFrame();
    if (!context.mounted) return;

    final sessionId = await ssh.openSession(
      connectionId,
      displayName: windowName,
      onUnknownHostKey: (request) =>
          showSshHostKeyTrustDialog(context, request),
    );
    if (!context.mounted) return;
    Navigator.of(context).pop();

    if (sessionId == null) {
      final message = ssh.errorMessage ?? strings.unknown;
      final lower = message.toLowerCase();
      final displayMessage =
          lower.contains('tmux is not installed') ||
              lower.contains('unable to check tmux')
          ? strings.tmuxMissingHint(message)
          : strings.connectionFailed(message);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(displayMessage),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
      return;
    }

    final session = ssh.getSession(sessionId);
    if (session != null && context.mounted) {
      _openWindow(context, session);
    }
  }

  Future<void> _renameWindow(
    BuildContext context,
    TerminalWindowsViewModel viewModel,
    SshSession session,
    AppStrings strings,
  ) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => WindowNameDialog(
        initialName: session.displayName,
        isNameAvailable: (name) =>
            viewModel.isSessionNameAvailable(session.id, name),
        title: strings.renameTerminalWindow,
        confirmLabel: strings.save,
      ),
    );
    if (!context.mounted || name == null) return;
    final renamed = viewModel.renameSession(session.id, name);
    if (!renamed && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.duplicateWindowName)));
    }
  }

  Future<void> _closeWindow(
    BuildContext context,
    TerminalWindowsViewModel viewModel,
    SshSession session,
    AppStrings strings,
  ) async {
    final cleanupCommand = session.tmuxKillCommand;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.closeTerminalWindow),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(strings.closeWindowTitle(session.displayName)),
            if (cleanupCommand != null) ...[
              const SizedBox(height: 12),
              Text(strings.staleTmuxHint),
              const SizedBox(height: 8),
              SelectableText(
                cleanupCommand,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontFamilyFallback: [
                    'Consolas',
                    'Microsoft YaHei',
                    'PingFang SC',
                    'sans-serif',
                  ],
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
        actions: [
          if (cleanupCommand != null)
            TextButton.icon(
              onPressed: () {
                _copyCleanupCommand(
                  context,
                  viewModel,
                  cleanupCommand,
                  strings,
                );
                Navigator.pop(ctx, false);
              },
              icon: const Icon(Icons.content_copy_rounded),
              label: Text(strings.copyCommand),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(strings.close),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await viewModel.closeSession(session.id);
    }
  }

  Future<void> _copyCleanupCommand(
    BuildContext context,
    TerminalWindowsViewModel viewModel,
    String command,
    AppStrings strings,
  ) async {
    await viewModel.copyCleanupCommand(command);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(strings.copiedCleanupCommand)));
  }

  Future<void> _closeSelectedWindows(
    BuildContext context,
    TerminalWindowsViewModel viewModel,
  ) async {
    final count = viewModel.selectedSessionIds.length;
    final strings = AppStrings(viewModel.language);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.closeSelectedWindows),
        content: Text(strings.closeSelectedContent(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(strings.close),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await viewModel.closeSelectedSessions();
    }
  }
}
