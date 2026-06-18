part of '../terminal_screen.dart';

extension _TerminalDialogs on _TerminalScreenState {
  Future<void> _openSiblingSession(BuildContext context) async {
    final strings = _strings(context);
    final action = await showDialog<_NewWindowAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.openNewWindow),
        content: Text(
          strings.createFrom(_serverName ?? strings.currentServer),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _NewWindowAction.editCurrent),
            child: Text(strings.editServer),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _NewWindowAction.addNew),
            child: Text(strings.addServer),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _NewWindowAction.current),
            child: Text(strings.create),
          ),
        ],
      ),
    );

    if (!context.mounted || action == null) return;

    switch (action) {
      case _NewWindowAction.current:
        await _openSessionWindow(context, widget.connectionId);
        break;
      case _NewWindowAction.editCurrent:
        final result = await Navigator.pushNamed(
          context,
          '/edit',
          arguments: widget.connectionId,
        );
        if (!context.mounted || result == null) return;
        await _openSessionWindow(context, widget.connectionId);
        break;
      case _NewWindowAction.addNew:
        final result = await Navigator.pushNamed(context, '/add');
        if (!context.mounted || result is! String) return;
        await _openSessionWindow(context, result);
        break;
    }
  }

  Future<void> _openSessionWindow(
    BuildContext context,
    String connectionId,
  ) async {
    final windowName = await _askWindowName(context, connectionId);
    if (!context.mounted || windowName == null) return;
    await _openSessionWindowWithOptions(context, connectionId, windowName);
  }

  Future<void> _openSessionWindowWithOptions(
    BuildContext context,
    String connectionId,
    String windowName,
  ) async {
    final colorScheme = Theme.of(context).colorScheme;
    final strings = _strings(context);
    final ssh = context.read<SshService>();
    final storage = context.read<StorageService>();
    final config = storage.getConnection(connectionId);
    final connectionName = config?.name ?? _serverName ?? strings.currentServer;

    showDialog(
      context: context,
      barrierDismissible: false,
      useSafeArea: false,
      builder: (ctx) => ConnectionProgressDialog(
        title: strings.connectingTo(connectionName),
        message: strings.openingNewWindow,
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _formatConnectionFailure(
              strings,
              ssh.errorMessage,
            ),
          ),
          backgroundColor: colorScheme.error,
        ),
      );
      return;
    }

    final session = ssh.getSession(sessionId);
    if (session == null) return;

    _replaceWithTerminalSession(session, animated: true);
  }

  Future<String?> _askWindowName(
    BuildContext context,
    String connectionId,
  ) async {
    final ssh = context.read<SshService>();
    return showDialog<String>(
      context: context,
      builder: (_) => WindowNameDialog(
        initialName: ssh.defaultDisplayNameForConnection(connectionId),
        isNameAvailable: ssh.isSessionNameAvailable,
      ),
    );
  }

  String _formatConnectionFailure(TerminalStrings strings, String? message) {
    final text = message ?? strings.unknown;
    final lower = text.toLowerCase();
    if (lower.contains('tmux is not installed') ||
        lower.contains('unable to check tmux')) {
      return strings.tmuxMissingHint(text);
    }
    return strings.connectionFailed(text);
  }

  Future<void> _showSessionSwitcher(BuildContext context) async {
    final strings = _strings(context);
    final ssh = context.read<SshService>();
    final sessions = ssh.sessions;
    if (sessions.isEmpty) return;

    final action = await showModalBottomSheet<_SessionSwitcherAction>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) => SafeArea(
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: sessions.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final session = sessions[index];
            final current = session.id == widget.sessionId;
            return ListTile(
              leading: Icon(
                session.isConnected ? Icons.link : Icons.link_off,
                color: session.isConnected
                    ? AppTheme.terminalGreen
                    : Theme.of(context).colorScheme.error,
              ),
              title: OverflowScrollText(
                session.displayName,
                selectable: false,
                maxLines: 1,
              ),
              subtitle: OverflowScrollText(
                current
                    ? strings.currentWindow
                    : '${session.connectionName} - '
                        '${session.isConnected ? strings.connected : session.errorMessage ?? strings.disconnected}',
                selectable: false,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.58),
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (current) const Icon(Icons.check),
                  IconButton(
                    icon: const Icon(Icons.close),
                    color: Theme.of(context).colorScheme.error,
                    tooltip: session.isConnected
                        ? strings.disconnect
                        : strings.closeDisconnected,
                    onPressed: () => Navigator.pop(
                      ctx,
                      _SessionSwitcherAction.close(session.id),
                    ),
                  ),
                ],
              ),
              onTap: () => Navigator.pop(
                ctx,
                _SessionSwitcherAction.switchTo(session.id),
              ),
            );
          },
        ),
      ),
    );

    if (!context.mounted || action == null) return;

    if (action.close) {
      final closingCurrent = action.sessionId == widget.sessionId;
      await ssh.disconnectSession(action.sessionId);
      if (!context.mounted) return;

      if (closingCurrent) {
        final nextSession = _nextSessionAfterClose(ssh);
        if (nextSession != null) {
          _replaceWithTerminalSession(nextSession, animated: true);
        } else {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      }
      return;
    }

    if (action.sessionId == widget.sessionId) return;

    final target = ssh.getSession(action.sessionId);
    if (target == null) return;

    _replaceWithTerminalSession(target);
  }

  SshSession? _nextSessionAfterClose(SshService ssh) {
    final otherSessions = ssh.sessions
        .where((session) => session.id != widget.sessionId)
        .toList()
        .reversed;
    for (final session in otherSessions) {
      if (session.isConnected) return session;
    }
    return otherSessions.isEmpty ? null : otherSessions.first;
  }

  Future<void> _showTerminalEditMenu(TerminalSessionViewModel viewModel) async {
    if (_terminalMenuOpen) return;
    _terminalMenuOpen = true;
    _requestWindowsAwareTerminalFocus(viewModel);
    final strings = _strings(context);

    final selectedText = viewModel.getSelectedText();
    final action = await showMenu<_TerminalEditAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        _lastLongPressPosition.dx,
        _lastLongPressPosition.dy,
        _lastLongPressPosition.dx,
        _lastLongPressPosition.dy,
      ),
      items: [
        PopupMenuItem(
          value: _TerminalEditAction.selectCopy,
          child: Text(strings.selectCopy),
        ),
        PopupMenuItem(
          value: _TerminalEditAction.copy,
          enabled: selectedText.trim().isNotEmpty,
          child: Text(strings.copy),
        ),
        PopupMenuItem(
          value: _TerminalEditAction.paste,
          child: Text(strings.paste),
        ),
        if (!_isWindowsTerminalTarget) // Non-Windows selects all text from terminal view anchor
          PopupMenuItem(
            value: _TerminalEditAction.selectAll,
            child: Text(_selectAllLabel(context)),
          ),
      ],
    );

    _terminalMenuOpen = false;

    if (!mounted || action == null) return;

    switch (action) {
      case _TerminalEditAction.selectCopy:
        viewModel.clearSelection();
        await _showSelectableCopyLayer(viewModel);
        break;
      case _TerminalEditAction.copy:
        if (selectedText.trim().isEmpty) return;
        await viewModel.copySelectedText();
        viewModel.clearSelection();
        break;
      case _TerminalEditAction.paste:
        await viewModel.pasteClipboardText();
        break;
      case _TerminalEditAction.selectAll:
        viewModel.selectAllText();
        break;
    }
  }

  Future<void> _showSelectableCopyLayer(
      TerminalSessionViewModel viewModel) async {
    final strings = _strings(context);
    final text = viewModel.terminal.buffer.getText().trimRight();
    if (text.isEmpty) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => TerminalCopyScreen(
          title: _serverName ?? strings.defaultTerminal,
          text: text,
          copyAllTooltip: strings.copyAll,
        ),
      ),
    );

    _requestWindowsAwareTerminalFocus(viewModel);
  }

  void _confirmDisconnect(BuildContext context) {
    final strings = _strings(context);
    final ssh = context.read<SshService>();
    final session = ssh.getSession(widget.sessionId);
    final windowName =
        session?.displayName ?? _serverName ?? strings.defaultTerminal;
    final isConnected = session?.isConnected == true;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          isConnected ? strings.disconnect : strings.closeDisconnectedTitle,
        ),
        content: Text(
          isConnected
              ? strings.disconnectContent(windowName)
              : strings.closeDisconnectedContent(windowName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await ssh.disconnectSession(widget.sessionId);
              if (!context.mounted) return;

              final nextSession = _nextSessionAfterClose(ssh);
              if (nextSession != null) {
                _replaceWithTerminalSession(nextSession, animated: true);
              } else {
                Navigator.of(context).popUntil((route) => route.isFirst);
              }
            },
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(
              isConnected ? strings.disconnect : strings.closeDisconnected,
            ),
          ),
        ],
      ),
    );
  }

  String _selectAllLabel(BuildContext context) {
    return AppStrings(context.read<AppSettings>().language).selectAll;
  }
}
