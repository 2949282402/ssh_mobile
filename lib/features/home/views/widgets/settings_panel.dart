part of '../home_screen.dart';

class _SettingsPanel extends StatefulWidget {
  final VoidCallback onExport;
  final VoidCallback onImport;

  const _SettingsPanel({required this.onExport, required this.onImport});

  @override
  State<_SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<_SettingsPanel> {
  final TextEditingController _mcpPortController = TextEditingController();
  final FocusNode _mcpPortFocusNode = FocusNode();
  Timer? _mcpPortDebounce;
  bool _checkingMcpPort = false;
  String? _mcpPortMessage;
  int? _lastSyncedMcpPort;

  final TextEditingController _terminalFontController = TextEditingController();
  final FocusNode _terminalFontFocusNode = FocusNode();
  Timer? _terminalFontDebounce;
  String? _lastSyncedTerminalFont;

  @override
  void dispose() {
    _mcpPortDebounce?.cancel();
    _mcpPortController.dispose();
    _mcpPortFocusNode.dispose();
    _terminalFontDebounce?.cancel();
    _terminalFontController.dispose();
    _terminalFontFocusNode.dispose();
    super.dispose();
  }

  void _onTerminalFontChanged(SettingsViewModel settings, String value) {
    _terminalFontDebounce?.cancel();
    _terminalFontDebounce = Timer(const Duration(milliseconds: 400), () {
      unawaited(settings.setTerminalFontFamily(value));
    });
  }

  Future<void> _editSftpLimit({
    required String title,
    required int currentBytes,
    required Future<void> Function(int bytes) onChanged,
  }) async {
    final settings = context.read<AppSettings>();
    final strings = AppStrings(settings.language);
    final controller = TextEditingController(
      text: _initialLimitMbText(currentBytes),
    );
    String? errorText;
    final bytes = await showDialog<int>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ShadInput(
                  controller: controller,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  placeholder: const Text('MB'),
                ),
                if (errorText != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    errorText!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  strings.sftpLimitDialogHint,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  strings.sftpLimitRange(
                    _formatLimitBytes(AppSettings.minSftpLimitBytes),
                    _formatLimitBytes(AppSettings.maxSftpLimitBytes),
                  ),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(strings.cancel),
            ),
            TextButton(
              onPressed: () {
                final value = double.tryParse(controller.text.trim());
                if (value == null || value <= 0) {
                  setDialogState(() => errorText = strings.sftpLimitInvalid);
                  return;
                }
                Navigator.pop(dialogContext, (value * 1024 * 1024).round());
              },
              child: Text(strings.save),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (bytes == null || !mounted) return;
    await onChanged(bytes);
  }

  void _syncMcpPortController(SettingsViewModel settings) {
    if (_lastSyncedMcpPort == settings.mcpServerPort) return;
    _lastSyncedMcpPort = settings.mcpServerPort;
    if (!_mcpPortFocusNode.hasFocus) {
      _mcpPortController.text = '${settings.mcpServerPort}';
    }
  }

  void _onMcpPortChanged(SettingsViewModel settings, String value) {
    _mcpPortDebounce?.cancel();
    final port = int.tryParse(value.trim());
    if (port == null || !McpServerSettings.isValidPort(port)) {
      setState(() {
        _mcpPortMessage = AppStrings(settings.language).mcpPortInvalidMessage;
      });
      return;
    }
    setState(() => _mcpPortMessage = null);
    _mcpPortDebounce = Timer(const Duration(milliseconds: 300), () {
      unawaited(_applyMcpPort(settings, port));
    });
  }

  Future<void> _applyMcpPort(SettingsViewModel settings, int port) async {
    try {
      await settings.setMcpServerPort(port);
      if (!mounted) return;
      if (settings.mcpServerRunning) {
        setState(() {
          _mcpPortMessage = AppStrings(settings.language).mcpPortRestartNeeded;
        });
        return;
      }
      await _checkMcpPort(settings);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _mcpPortMessage = AppStrings(settings.language).mcpPortInvalidMessage;
      });
    }
  }

  Future<void> _checkMcpPort(SettingsViewModel settings) async {
    setState(() => _checkingMcpPort = true);
    try {
      final result = await settings.checkMcpPort();
      if (!mounted || result == null) return;
      setState(() {
        _mcpPortMessage = _mcpPortProbeMessage(
          AppStrings(settings.language),
          result,
        );
      });
    } finally {
      if (mounted) {
        setState(() => _checkingMcpPort = false);
      }
    }
  }

  String _mcpPortProbeMessage(AppStrings strings, McpPortProbeResult result) {
    if (result.available) return strings.mcpPortAvailable;
    if (result.reason == McpPortProbeReason.invalidHostOrPort) {
      return strings.mcpPortInvalidMessage;
    }
    return strings.mcpPortOccupied;
  }

  String _mcpStatusText(AppStrings strings, SettingsViewModel settings) {
    final snapshot = settings.mcpServerStatus;
    final status = snapshot?.status ?? McpServerRunStatus.stopped;
    switch (status) {
      case McpServerRunStatus.checkingPort:
        return strings.mcpCheckingPort;
      case McpServerRunStatus.starting:
        return strings.mcpStarting;
      case McpServerRunStatus.running:
        if (settings.mcpPortRequiresRestart) {
          return '${strings.mcpRunningAt(snapshot!.url)}\n${strings.mcpPortRestartNeeded}';
        }
        return strings.mcpRunningAt(snapshot!.url);
      case McpServerRunStatus.failed:
        return snapshot?.lastError ?? strings.mcpFailed;
      case McpServerRunStatus.stopped:
        return strings.mcpStopped;
    }
  }

  Future<void> _copyMcpText(String text, String message) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _initialLimitMbText(int bytes) {
    final mb = bytes / 1024 / 1024;
    if (mb >= 1 && mb == mb.roundToDouble()) return mb.toStringAsFixed(0);
    return mb.toStringAsFixed(mb < 1 ? 2 : 1);
  }

  String _formatLimitBytes(int bytes) {
    const kb = 1024;
    const mb = 1024 * 1024;
    const gb = 1024 * 1024 * 1024;
    if (bytes >= gb) {
      final value = bytes / gb;
      return '${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1)} GB';
    }
    if (bytes >= mb) {
      final value = bytes / mb;
      return '${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1)} MB';
    }
    final value = bytes / kb;
    return '${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1)} KB';
  }

  @override
  Widget build(BuildContext context) {
    final appSnapshot = context.select<SettingsViewModel, _SettingsAppSnapshot>(
      _SettingsAppSnapshot.from,
    );
    final secretSnapshot = context
        .select<SettingsViewModel, _SettingsSecretSnapshot>(
          _SettingsSecretSnapshot.from,
        );
    context.select<SettingsViewModel, _SettingsMcpSnapshot>(
      _SettingsMcpSnapshot.from,
    );
    final settings = context.read<SettingsViewModel>();
    final strings = AppStrings(appSnapshot.language);
    final colorScheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    _syncMcpPortController(settings);

    if (_lastSyncedTerminalFont != appSnapshot.terminalFontFamily) {
      _lastSyncedTerminalFont = appSnapshot.terminalFontFamily;
      if (!_terminalFontFocusNode.hasFocus) {
        _terminalFontController.text = appSnapshot.terminalFontFamily;
      }
    }

    return ListTileTheme(
      dense: false,
      minLeadingWidth: 28,
      horizontalTitleGap: 10,
      iconColor: colorScheme.onSurfaceVariant,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      ),
      child: DefaultTextStyle.merge(
        style: const TextStyle(fontSize: 14),
        child: ListView(
          padding: EdgeInsets.fromLTRB(18, 14, 18, 20 + bottomInset),
          children: [
            _AppearanceSettingsSection(
              appSnapshot: appSnapshot,
              strings: strings,
              settings: settings,
              terminalFontController: _terminalFontController,
              terminalFontFocusNode: _terminalFontFocusNode,
              onTerminalFontChanged: (val) =>
                  _onTerminalFontChanged(settings, val),
            ),
            const SizedBox(height: 12),
            _McpSettingsSection(
              strings: strings,
              settings: settings,
              mcpPortController: _mcpPortController,
              mcpPortFocusNode: _mcpPortFocusNode,
              checkingMcpPort: _checkingMcpPort,
              mcpPortMessage: _mcpPortMessage,
              onCheckMcpPort: () => _checkMcpPort(settings),
              onMcpPortChanged: (value) => _onMcpPortChanged(settings, value),
              onRestartMcp: () async {
                await settings.restartMcpServer();
                if (mounted) setState(() {});
              },
              onRegenerateToken: () async {
                final messenger = ScaffoldMessenger.of(context);
                final message = strings.mcpTokenRegenerated;
                await settings.regenerateMcpServerToken();
                if (!mounted) return;
                messenger.showSnackBar(SnackBar(content: Text(message)));
              },
              onCopyText: _copyMcpText,
              getMcpStatusText: _mcpStatusText,
            ),
            const SizedBox(height: 12),
            _SftpLimitsSettingsSection(
              appSnapshot: appSnapshot,
              strings: strings,
              settings: settings,
              formatLimitBytes: _formatLimitBytes,
              editSftpLimit: _editSftpLimit,
            ),
            const SizedBox(height: 12),
            _SecuritySettingsSection(
              secretSnapshot: secretSnapshot,
              strings: strings,
              settings: settings,
            ),
            const SizedBox(height: 12),
            _BackupSettingsSection(
              strings: strings,
              onExport: widget.onExport,
              onImport: widget.onImport,
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsAppSnapshot {
  final AppLanguage language;
  final bool isEnglish;
  final bool isDarkMode;
  final int sftpDownloadLimitBytes;
  final int sftpTextPreviewLimitBytes;
  final int sftpRichPreviewLimitBytes;
  final int sftpTextEditLimitBytes;
  final bool oledDark;
  final String terminalThemeId;
  final String terminalFontFamily;
  final String serverListLayoutMode;

  const _SettingsAppSnapshot({
    required this.language,
    required this.isEnglish,
    required this.isDarkMode,
    required this.sftpDownloadLimitBytes,
    required this.sftpTextPreviewLimitBytes,
    required this.sftpRichPreviewLimitBytes,
    required this.sftpTextEditLimitBytes,
    required this.oledDark,
    required this.terminalThemeId,
    required this.terminalFontFamily,
    required this.serverListLayoutMode,
  });

  factory _SettingsAppSnapshot.from(SettingsViewModel settings) {
    return _SettingsAppSnapshot(
      language: settings.language,
      isEnglish: settings.isEnglish,
      isDarkMode: settings.isDarkMode,
      sftpDownloadLimitBytes: settings.sftpDownloadLimitBytes,
      sftpTextPreviewLimitBytes: settings.sftpTextPreviewLimitBytes,
      sftpRichPreviewLimitBytes: settings.sftpRichPreviewLimitBytes,
      sftpTextEditLimitBytes: settings.sftpTextEditLimitBytes,
      oledDark: settings.oledDark,
      terminalThemeId: settings.terminalThemeId,
      terminalFontFamily: settings.terminalFontFamily,
      serverListLayoutMode: settings.serverListLayoutMode,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _SettingsAppSnapshot &&
        other.language == language &&
        other.isEnglish == isEnglish &&
        other.isDarkMode == isDarkMode &&
        other.sftpDownloadLimitBytes == sftpDownloadLimitBytes &&
        other.sftpTextPreviewLimitBytes == sftpTextPreviewLimitBytes &&
        other.sftpRichPreviewLimitBytes == sftpRichPreviewLimitBytes &&
        other.sftpTextEditLimitBytes == sftpTextEditLimitBytes &&
        other.oledDark == oledDark &&
        other.terminalThemeId == terminalThemeId &&
        other.terminalFontFamily == terminalFontFamily &&
        other.serverListLayoutMode == serverListLayoutMode;
  }

  @override
  int get hashCode => Object.hash(
    language,
    isEnglish,
    isDarkMode,
    sftpDownloadLimitBytes,
    sftpTextPreviewLimitBytes,
    sftpRichPreviewLimitBytes,
    sftpTextEditLimitBytes,
    oledDark,
    terminalThemeId,
    terminalFontFamily,
    serverListLayoutMode,
  );
}

class _SettingsSecretSnapshot {
  final bool cacheEnabled;
  final int cacheTimeoutMinutes;
  final List<int> cacheOptions;
  final bool showServerNamesInNotifications;

  const _SettingsSecretSnapshot({
    required this.cacheEnabled,
    required this.cacheTimeoutMinutes,
    required this.cacheOptions,
    required this.showServerNamesInNotifications,
  });

  factory _SettingsSecretSnapshot.from(SettingsViewModel settings) {
    return _SettingsSecretSnapshot(
      cacheEnabled: settings.secretCacheEnabled,
      cacheTimeoutMinutes: settings.secretCacheTtlMinutes,
      cacheOptions: settings.secretCacheTtlOptionsMinutes,
      showServerNamesInNotifications: settings.showServerNamesInNotifications,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _SettingsSecretSnapshot &&
        other.cacheEnabled == cacheEnabled &&
        other.cacheTimeoutMinutes == cacheTimeoutMinutes &&
        listEquals(other.cacheOptions, cacheOptions) &&
        other.showServerNamesInNotifications == showServerNamesInNotifications;
  }

  @override
  int get hashCode => Object.hash(
    cacheEnabled,
    cacheTimeoutMinutes,
    Object.hashAll(cacheOptions),
    showServerNamesInNotifications,
  );
}

class _SettingsMcpSnapshot {
  final bool enabled;
  final String host;
  final int port;
  final bool allowWriteTools;
  final bool requireApprovalForWriteTools;
  final bool running;
  final bool portRequiresRestart;
  final McpServerRunStatus status;
  final String? lastError;
  final bool? lastPortAvailable;
  final String token;

  const _SettingsMcpSnapshot({
    required this.enabled,
    required this.host,
    required this.port,
    required this.allowWriteTools,
    required this.requireApprovalForWriteTools,
    required this.running,
    required this.portRequiresRestart,
    required this.status,
    required this.lastError,
    required this.lastPortAvailable,
    required this.token,
  });

  factory _SettingsMcpSnapshot.from(SettingsViewModel settings) {
    final status = settings.mcpServerStatus;
    return _SettingsMcpSnapshot(
      enabled: settings.mcpServerEnabled,
      host: settings.mcpServerHost,
      port: settings.mcpServerPort,
      allowWriteTools: settings.mcpAllowWriteTools,
      requireApprovalForWriteTools: settings.mcpRequireApprovalForWriteTools,
      running: settings.mcpServerRunning,
      portRequiresRestart: settings.mcpPortRequiresRestart,
      status: status?.status ?? McpServerRunStatus.stopped,
      lastError: status?.lastError,
      lastPortAvailable: settings.mcpLastPortProbe?.available,
      token: settings.mcpServerToken,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _SettingsMcpSnapshot &&
        other.enabled == enabled &&
        other.host == host &&
        other.port == port &&
        other.allowWriteTools == allowWriteTools &&
        other.requireApprovalForWriteTools == requireApprovalForWriteTools &&
        other.running == running &&
        other.portRequiresRestart == portRequiresRestart &&
        other.status == status &&
        other.lastError == lastError &&
        other.lastPortAvailable == lastPortAvailable &&
        other.token == token;
  }

  @override
  int get hashCode => Object.hash(
    enabled,
    host,
    port,
    allowWriteTools,
    requireApprovalForWriteTools,
    running,
    portRequiresRestart,
    status,
    lastError,
    lastPortAvailable,
    token,
  );
}

class _SettingsPage extends StatelessWidget {
  final VoidCallback onExport;
  final VoidCallback onImport;

  const _SettingsPage({required this.onExport, required this.onImport});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final strings = AppStrings(context.read<AppSettings>().language);
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.settings),
        leading: IconButton(
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        backgroundColor: colorScheme.surface.withValues(alpha: 0.92),
        shape: Border(
          bottom: BorderSide(color: colorScheme.outline.withValues(alpha: 0.7)),
        ),
      ),
      body: AppPageSurface(
        child: _SettingsPanel(onExport: onExport, onImport: onImport),
      ),
    );
  }
}
