part of '../home_screen.dart';

class _SettingsPanel extends StatefulWidget {
  final String appTitle;
  final VoidCallback onExport;
  final VoidCallback onImport;

  const _SettingsPanel({
    required this.appTitle,
    required this.onExport,
    required this.onImport,
  });

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

  @override
  void dispose() {
    _mcpPortDebounce?.cancel();
    _mcpPortController.dispose();
    _mcpPortFocusNode.dispose();
    super.dispose();
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
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
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
                Navigator.pop(
                  dialogContext,
                  (value * 1024 * 1024).round(),
                );
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
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
    final secretSnapshot =
        context.select<SettingsViewModel, _SettingsSecretSnapshot>(
      _SettingsSecretSnapshot.from,
    );
    context.select<SettingsViewModel, _SettingsMcpSnapshot>(
      _SettingsMcpSnapshot.from,
    );
    final settings = context.read<SettingsViewModel>();
    final storage = context.read<SettingsViewModel>();
    final strings = AppStrings(appSnapshot.language);
    final colorScheme = Theme.of(context).colorScheme;
    final cacheEnabled = secretSnapshot.cacheEnabled;
    final cacheTimeoutMinutes = secretSnapshot.cacheTimeoutMinutes;
    final cacheOptions = secretSnapshot.cacheOptions;
    _syncMcpPortController(settings);

    return ListTileTheme(
      dense: false,
      minLeadingWidth: 28,
      horizontalTitleGap: 10,
      iconColor: colorScheme.onSurfaceVariant,
      child: DefaultTextStyle.merge(
        style: const TextStyle(fontSize: 14),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
          children: [
            Row(
              children: [
                Icon(
                  Icons.settings_outlined,
                  color: colorScheme.primary,
                  size: 21,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.appTitle,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        strings.settings,
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _SettingsSection(
              title: strings.appearance,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.translate_rounded, size: 20),
                  title: Text(
                    appSnapshot.isEnglish
                        ? strings.switchToChinese
                        : strings.switchToEnglish,
                    style: const TextStyle(fontSize: 13),
                  ),
                  onTap: () => settings.changeLanguage(
                    settings.language == AppLanguage.en
                        ? AppLanguage.zh
                        : AppLanguage.en,
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: Icon(
                    appSnapshot.isDarkMode ? Icons.dark_mode : Icons.light_mode,
                    size: 20,
                  ),
                  title: Text(
                    appSnapshot.isDarkMode
                        ? strings.switchToLightMode
                        : strings.switchToDarkMode,
                    style: const TextStyle(fontSize: 13),
                  ),
                  value: appSnapshot.isDarkMode,
                  onChanged: (_) => settings.changeThemeMode(
                    settings.isDarkMode ? ThemeMode.light : ThemeMode.dark,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _SettingsSection(
              title: strings.toolsAndAutomation,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.auto_awesome, size: 20),
                  title: Text(
                    strings.language == AppLanguage.en
                        ? 'AI Skills'
                        : 'AI Skills',
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    strings.aiSkillsHint,
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: () {
                    Navigator.pushNamed(context, '/ai-skills');
                  },
                ),
                const Divider(height: 18),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.hub_outlined, size: 20),
                  title: Text(
                    strings.mcpServer,
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    _mcpStatusText(strings, settings),
                    style: const TextStyle(fontSize: 11),
                  ),
                  value: settings.mcpServerEnabled,
                  onChanged: (value) async {
                    await settings.setMcpServerEnabled(value);
                    if (mounted) setState(() {});
                  },
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 30, bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        strings.mcpServerHint,
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${strings.mcpHost}: ${settings.mcpServerHost}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _mcpPortController,
                        focusNode: _mcpPortFocusNode,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: strings.mcpPort,
                          border: const OutlineInputBorder(),
                          suffixIcon: _checkingMcpPort
                              ? const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : IconButton(
                                  tooltip: strings.mcpCheckPort,
                                  icon: const Icon(Icons.search_rounded),
                                  onPressed: () => _checkMcpPort(settings),
                                ),
                        ),
                        onChanged: (value) =>
                            _onMcpPortChanged(settings, value),
                      ),
                      if (_mcpPortMessage != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          _mcpPortMessage!,
                          style: TextStyle(
                            color: _mcpPortMessage == strings.mcpPortAvailable
                                ? Colors.green
                                : colorScheme.error,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(
                          strings.mcpAllowWriteTools,
                          style: const TextStyle(fontSize: 12),
                        ),
                        subtitle: Text(
                          strings.mcpAllowWriteToolsHint,
                          style: const TextStyle(fontSize: 11),
                        ),
                        value: settings.mcpAllowWriteTools,
                        onChanged: settings.setMcpAllowWriteTools,
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(
                          strings.mcpRequireApproval,
                          style: const TextStyle(fontSize: 12),
                        ),
                        value: settings.mcpRequireApprovalForWriteTools,
                        onChanged: settings.setMcpRequireApprovalForWriteTools,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            icon: const Icon(Icons.refresh_rounded, size: 16),
                            label: Text(strings.mcpRestart),
                            onPressed: () async {
                              await settings.restartMcpServer();
                              if (mounted) setState(() {});
                            },
                          ),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.key_rounded, size: 16),
                            label: Text(strings.mcpRegenerateToken),
                            onPressed: () async {
                              final messenger = ScaffoldMessenger.of(context);
                              final message = strings.mcpTokenRegenerated;
                              await settings.regenerateMcpServerToken();
                              if (!mounted) return;
                              messenger.showSnackBar(
                                SnackBar(
                                  content: Text(message),
                                ),
                              );
                            },
                          ),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.copy_rounded, size: 16),
                            label: Text(strings.mcpCopyCodex),
                            onPressed: () => _copyMcpText(
                              settings.mcpCodexConfig,
                              strings.mcpCopied,
                            ),
                          ),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.copy_rounded, size: 16),
                            label: Text(strings.mcpCopyClaude),
                            onPressed: () => _copyMcpText(
                              settings.mcpClaudeCodeCommand,
                              strings.mcpCopied,
                            ),
                          ),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.copy_rounded, size: 16),
                            label: Text(strings.mcpCopyGemini),
                            onPressed: () => _copyMcpText(
                              settings.mcpGeminiCliConfig,
                              strings.mcpCopied,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _SettingsSection(
              title: strings.sftpLimits,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    strings.sftpLimitsHint,
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ),
                _SftpLimitTile(
                  icon: Icons.download_outlined,
                  title: strings.sftpDownloadLimit,
                  value: _formatLimitBytes(appSnapshot.sftpDownloadLimitBytes),
                  onTap: () => _editSftpLimit(
                    title: strings.sftpDownloadLimit,
                    currentBytes: appSnapshot.sftpDownloadLimitBytes,
                    onChanged: (bytes) =>
                        settings.setSftpLimits(downloadLimit: bytes),
                  ),
                ),
                _SftpLimitTile(
                  icon: Icons.article_outlined,
                  title: strings.sftpTextPreviewLimit,
                  value:
                      _formatLimitBytes(appSnapshot.sftpTextPreviewLimitBytes),
                  onTap: () => _editSftpLimit(
                    title: strings.sftpTextPreviewLimit,
                    currentBytes: appSnapshot.sftpTextPreviewLimitBytes,
                    onChanged: (bytes) =>
                        settings.setSftpLimits(textPreviewLimit: bytes),
                  ),
                ),
                _SftpLimitTile(
                  icon: Icons.preview_outlined,
                  title: strings.sftpRichPreviewLimit,
                  value:
                      _formatLimitBytes(appSnapshot.sftpRichPreviewLimitBytes),
                  onTap: () => _editSftpLimit(
                    title: strings.sftpRichPreviewLimit,
                    currentBytes: appSnapshot.sftpRichPreviewLimitBytes,
                    onChanged: (bytes) =>
                        settings.setSftpLimits(richPreviewLimit: bytes),
                  ),
                ),
                _SftpLimitTile(
                  icon: Icons.edit_note_outlined,
                  title: strings.sftpEditLimit,
                  value: _formatLimitBytes(appSnapshot.sftpTextEditLimitBytes),
                  onTap: () => _editSftpLimit(
                    title: strings.sftpEditLimit,
                    currentBytes: appSnapshot.sftpTextEditLimitBytes,
                    onChanged: (bytes) =>
                        settings.setSftpLimits(textEditLimit: bytes),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _SettingsSection(
              title: strings.security,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.security, size: 20),
                  title: Text(
                    strings.credentialCache,
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    strings.credentialCacheHint,
                    style: const TextStyle(fontSize: 11),
                  ),
                  value: cacheEnabled,
                  onChanged: (value) async {
                    await storage.configureSecretCache(
                        value, cacheTimeoutMinutes);
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.timer_outlined, size: 20),
                  title: Text(
                    strings.credentialCacheTimeoutLabel(
                      cacheTimeoutMinutes,
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                  trailing: SizedBox(
                    width: 110,
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        isDense: true,
                        isExpanded: true,
                        value: cacheTimeoutMinutes,
                        items: [
                          for (final minutes in cacheOptions)
                            DropdownMenuItem(
                              value: minutes,
                              child: Text(
                                '${minutes}m',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: cacheEnabled
                            ? (minutes) async {
                                if (minutes == null) return;
                                await storage.configureSecretCache(
                                  cacheEnabled,
                                  minutes,
                                );
                              }
                            : null,
                      ),
                    ),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary:
                      const Icon(Icons.notifications_off_outlined, size: 20),
                  title: Text(
                    strings.notificationServerNames,
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    strings.notificationServerNamesHint,
                    style: const TextStyle(fontSize: 11),
                  ),
                  value: secretSnapshot.showServerNamesInNotifications,
                  onChanged: settings.setShowServerNamesInNotifications,
                ),
              ],
            ),
            const SizedBox(height: 12),
            _SettingsSection(
              title: strings.dataBackup,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.upload_file_outlined, size: 20),
                  title: Text(
                    strings.exportAppData,
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    strings.backupContainsSecrets,
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: widget.onExport,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.download_for_offline_outlined,
                    size: 20,
                  ),
                  title: Text(
                    strings.importAppData,
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    strings.importAppDataWarning,
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: widget.onImport,
                ),
              ],
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

  const _SettingsAppSnapshot({
    required this.language,
    required this.isEnglish,
    required this.isDarkMode,
    required this.sftpDownloadLimitBytes,
    required this.sftpTextPreviewLimitBytes,
    required this.sftpRichPreviewLimitBytes,
    required this.sftpTextEditLimitBytes,
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
        other.sftpTextEditLimitBytes == sftpTextEditLimitBytes;
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

class _SftpLimitTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final VoidCallback onTap;

  const _SftpLimitTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, size: 20),
      title: Text(title, style: const TextStyle(fontSize: 13)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.edit_outlined, size: 18),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _SettingsSection extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SettingsSection({
    required this.title,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.32),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
              child: Text(
                title,
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Full-screen settings wrapper pushed via _openSettings.
class _SettingsPage extends StatelessWidget {
  final String appTitle;
  final VoidCallback onExport;
  final VoidCallback onImport;

  const _SettingsPage({
    required this.appTitle,
    required this.onExport,
    required this.onImport,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final strings = AppStrings(context.read<AppSettings>().language);
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.settings),
        backgroundColor: colorScheme.surface,
      ),
      body: _SettingsPanel(
        appTitle: appTitle,
        onExport: onExport,
        onImport: onImport,
      ),
    );
  }
}
