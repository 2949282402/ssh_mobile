part of 'add_edit_screen.dart';

extension _AddEditAdvancedFields on _AddEditScreenState {
  Widget _buildLaunchModeSelector(ConnectionStrings strings) {
    final supportsTmux = _serverPlatform == ServerPlatform.linux;
    final selectedLaunchMode = supportsTmux
        ? _launchMode
        : TerminalLaunchMode.ssh;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<TerminalLaunchMode>(
            showSelectedIcon: false,
            segments: [
              const ButtonSegment(
                value: TerminalLaunchMode.ssh,
                label: Text('SSH', maxLines: 1),
                icon: Icon(Icons.terminal, size: 18),
              ),
              if (supportsTmux)
                const ButtonSegment(
                  value: TerminalLaunchMode.tmux,
                  label: Text('SSH + tmux', maxLines: 1),
                  icon: Icon(Icons.tab_rounded, size: 18),
                ),
            ],
            selected: {selectedLaunchMode},
            onSelectionChanged: (set) =>
                _updateState(() => _launchMode = set.first),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          !supportsTmux
              ? strings.windowsTmuxUnavailable
              : _launchMode == TerminalLaunchMode.tmux
              ? strings.tmuxModeDescription
              : strings.sshModeDescription,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.62),
          ),
        ),
      ],
    );
  }

  Widget _buildServerPlatformSelector(ConnectionStrings strings) {
    final isWindows = _serverPlatform == ServerPlatform.windows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          strings.serverSystem,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<ServerPlatform>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: ServerPlatform.linux,
                label: Text('Linux', maxLines: 1),
                icon: Icon(Icons.dns_outlined, size: 18),
              ),
              ButtonSegment(
                value: ServerPlatform.windows,
                label: Text('Windows', maxLines: 1),
                icon: Icon(Icons.desktop_windows_outlined, size: 18),
              ),
            ],
            selected: {_serverPlatform},
            onSelectionChanged: (set) {
              _updateState(() {
                _serverPlatform = set.first;
                if (_serverPlatform == ServerPlatform.windows) {
                  _launchMode = TerminalLaunchMode.ssh;
                }
              });
            },
          ),
        ),
        const SizedBox(height: 6),
        Text(
          isWindows
              ? strings.windowsMonitoringDescription
              : strings.linuxMonitoringDescription,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.62),
          ),
        ),
      ],
    );
  }

  Widget _buildTmuxAutoDeleteField(ConnectionStrings strings) {
    return ShadInputFormField(
      id: 'tmuxAutoDelete',
      controller: _tmuxAutoDeleteController,
      label: Text(strings.tmuxAutoDeleteMinutes),
      placeholder: const Text(ConnectionUiTokens.defaultTmuxDeleteMinutesText),
      description: Text(strings.tmuxAutoDeleteHelp),
      leading: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Icon(Icons.timer_outlined, size: 18),
      ),
      keyboardType: TextInputType.number,
      validator: (value) {
        if (_launchMode != TerminalLaunchMode.tmux) return null;
        final minutes = int.tryParse(value.trim());
        if (minutes == null ||
            minutes < ConnectionUiTokens.minTmuxDeleteMinutes) {
          return strings.minOneMinute;
        }
        if (minutes > ConnectionUiTokens.maxTmuxDeleteMinutes) {
          return strings.max1440Minutes;
        }
        return null;
      },
    );
  }

  Widget _buildKeepAliveSwitch(ConnectionStrings strings) {
    return Material(
      color: Colors.transparent,
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(strings.keepAliveTitle),
        subtitle: Text(
          strings.keepAliveSubtitle,
          style: const TextStyle(fontSize: 12),
        ),
        value: _keepAlive,
        onChanged: (value) => _updateState(() => _keepAlive = value),
      ),
    );
  }
}
