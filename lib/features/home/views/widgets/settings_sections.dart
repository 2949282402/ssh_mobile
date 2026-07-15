part of '../home_screen.dart';

// --- Shared Internal Settings Widgets ---

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

  const _SettingsSection({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return AppSectionCard(
      title: title,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      contentGap: 8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

// --- Specific Settings Domain Sections ---

class _AppearanceSettingsSection extends StatelessWidget {
  final _SettingsAppSnapshot appSnapshot;
  final AppStrings strings;
  final SettingsViewModel settings;
  final TextEditingController terminalFontController;
  final FocusNode terminalFontFocusNode;
  final ValueChanged<String>? onTerminalFontChanged;

  const _AppearanceSettingsSection({
    required this.appSnapshot,
    required this.strings,
    required this.settings,
    required this.terminalFontController,
    required this.terminalFontFocusNode,
    required this.onTerminalFontChanged,
  });

  @override
  Widget build(BuildContext context) {
    void changeLanguage() {
      settings.changeLanguage(
        settings.language == AppLanguage.en ? AppLanguage.zh : AppLanguage.en,
      );
    }

    return _SettingsSection(
      title: strings.appearance,
      children: [
        Semantics(
          container: true,
          button: true,
          label: '${strings.languageLabel}: ${strings.currentLanguageName}',
          onTap: changeLanguage,
          child: ExcludeSemantics(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.translate_rounded, size: 20),
              title: Text(
                strings.languageLabel,
                style: const TextStyle(fontSize: 13),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    strings.currentLanguageName,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.chevron_right_rounded, size: 18),
                ],
              ),
              onTap: changeLanguage,
            ),
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
        if (appSnapshot.isDarkMode)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.brightness_2, size: 20),
            title: Text(
              strings.oledDarkMode,
              style: const TextStyle(fontSize: 13),
            ),
            value: appSnapshot.oledDark,
            onChanged: (val) => settings.setOledDark(val),
          ),
        const Divider(height: 18),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.palette_outlined, size: 20),
          title: Text(
            strings.terminalTheme,
            style: const TextStyle(fontSize: 13),
          ),
          trailing: SizedBox(
            width: 140,
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isDense: true,
                isExpanded: true,
                value: appSnapshot.terminalThemeId,
                items: [
                  DropdownMenuItem(
                    value: 'default',
                    child: Text(strings.defaultOption),
                  ),
                  const DropdownMenuItem(
                    value: 'monokai',
                    child: Text('Monokai'),
                  ),
                  const DropdownMenuItem(value: 'nord', child: Text('Nord')),
                  const DropdownMenuItem(
                    value: 'gruvbox',
                    child: Text('Gruvbox'),
                  ),
                  const DropdownMenuItem(
                    value: 'solarized',
                    child: Text('Solarized Dark'),
                  ),
                ],
                onChanged: (val) {
                  if (val != null) {
                    settings.setTerminalThemeId(val);
                  }
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(left: 30, bottom: 8),
          child: TextField(
            controller: terminalFontController,
            focusNode: terminalFontFocusNode,
            decoration: InputDecoration(
              isDense: true,
              labelText: strings.customTerminalFont,
              helperText: strings.customTerminalFontHint,
              helperMaxLines: 2,
              border: const OutlineInputBorder(),
            ),
            onChanged: onTerminalFontChanged,
          ),
        ),
        const Divider(height: 18),
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.grid_view, size: 20),
            title: Text(
              strings.serverListLayout,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 30, bottom: 6),
          child: SegmentedButton<String>(
            expandedInsets: EdgeInsets.zero,
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: 'list',
                label: Text(strings.layoutList),
                icon: const Icon(Icons.list_rounded, size: 16),
              ),
              ButtonSegment(
                value: 'grid',
                label: Text(strings.layoutGrid),
                icon: const Icon(Icons.grid_view_rounded, size: 16),
              ),
            ],
            selected: {appSnapshot.serverListLayoutMode},
            onSelectionChanged: (selection) {
              settings.setServerListLayoutMode(selection.first);
            },
          ),
        ),
      ],
    );
  }
}

class _McpSettingsSection extends StatelessWidget {
  final AppStrings strings;
  final SettingsViewModel settings;
  final TextEditingController mcpPortController;
  final FocusNode mcpPortFocusNode;
  final bool checkingMcpPort;
  final String? mcpPortMessage;
  final VoidCallback onCheckMcpPort;
  final ValueChanged<String>? onMcpPortChanged;
  final VoidCallback onRestartMcp;
  final VoidCallback onRegenerateToken;
  final void Function(String, String) onCopyText;
  final String Function(AppStrings, SettingsViewModel) getMcpStatusText;

  const _McpSettingsSection({
    required this.strings,
    required this.settings,
    required this.mcpPortController,
    required this.mcpPortFocusNode,
    required this.checkingMcpPort,
    required this.mcpPortMessage,
    required this.onCheckMcpPort,
    required this.onMcpPortChanged,
    required this.onRestartMcp,
    required this.onRegenerateToken,
    required this.onCopyText,
    required this.getMcpStatusText,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return _SettingsSection(
      title: strings.toolsAndAutomation,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.auto_awesome, size: 20),
          title: Text(
            strings.language == AppLanguage.en ? 'AI Skills' : 'AI Skills',
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
          title: Text(strings.mcpServer, style: const TextStyle(fontSize: 13)),
          subtitle: Text(
            getMcpStatusText(strings, settings),
            style: const TextStyle(fontSize: 11),
          ),
          value: settings.mcpServerEnabled,
          onChanged: (value) async {
            await settings.setMcpServerEnabled(value);
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
                controller: mcpPortController,
                focusNode: mcpPortFocusNode,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: strings.mcpPort,
                  border: const OutlineInputBorder(),
                  suffixIcon: checkingMcpPort
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          tooltip: strings.mcpCheckPort,
                          icon: const Icon(Icons.search_rounded),
                          onPressed: onCheckMcpPort,
                        ),
                ),
                onChanged: onMcpPortChanged,
              ),
              if (mcpPortMessage != null) ...[
                const SizedBox(height: 6),
                Text(
                  mcpPortMessage!,
                  style: TextStyle(
                    color: mcpPortMessage == strings.mcpPortAvailable
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
                    onPressed: onRestartMcp,
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.key_rounded, size: 16),
                    label: Text(strings.mcpRegenerateToken),
                    onPressed: onRegenerateToken,
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    label: Text(strings.mcpCopyCodex),
                    onPressed: () =>
                        onCopyText(settings.mcpCodexConfig, strings.mcpCopied),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    label: Text(strings.mcpCopyClaude),
                    onPressed: () => onCopyText(
                      settings.mcpClaudeCodeCommand,
                      strings.mcpCopied,
                    ),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    label: Text(strings.mcpCopyGemini),
                    onPressed: () => onCopyText(
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
    );
  }
}

class _SftpLimitsSettingsSection extends StatelessWidget {
  final _SettingsAppSnapshot appSnapshot;
  final AppStrings strings;
  final SettingsViewModel settings;
  final String Function(int) formatLimitBytes;
  final Future<void> Function({
    required String title,
    required int currentBytes,
    required Future<void> Function(int) onChanged,
  })
  editSftpLimit;

  const _SftpLimitsSettingsSection({
    required this.appSnapshot,
    required this.strings,
    required this.settings,
    required this.formatLimitBytes,
    required this.editSftpLimit,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return _SettingsSection(
      title: strings.sftpLimits,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            strings.sftpLimitsHint,
            style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 11),
          ),
        ),
        _SftpLimitTile(
          icon: Icons.download_outlined,
          title: strings.sftpDownloadLimit,
          value: formatLimitBytes(appSnapshot.sftpDownloadLimitBytes),
          onTap: () => editSftpLimit(
            title: strings.sftpDownloadLimit,
            currentBytes: appSnapshot.sftpDownloadLimitBytes,
            onChanged: (bytes) => settings.setSftpLimits(downloadLimit: bytes),
          ),
        ),
        _SftpLimitTile(
          icon: Icons.article_outlined,
          title: strings.sftpTextPreviewLimit,
          value: formatLimitBytes(appSnapshot.sftpTextPreviewLimitBytes),
          onTap: () => editSftpLimit(
            title: strings.sftpTextPreviewLimit,
            currentBytes: appSnapshot.sftpTextPreviewLimitBytes,
            onChanged: (bytes) =>
                settings.setSftpLimits(textPreviewLimit: bytes),
          ),
        ),
        _SftpLimitTile(
          icon: Icons.preview_outlined,
          title: strings.sftpRichPreviewLimit,
          value: formatLimitBytes(appSnapshot.sftpRichPreviewLimitBytes),
          onTap: () => editSftpLimit(
            title: strings.sftpRichPreviewLimit,
            currentBytes: appSnapshot.sftpRichPreviewLimitBytes,
            onChanged: (bytes) =>
                settings.setSftpLimits(richPreviewLimit: bytes),
          ),
        ),
        _SftpLimitTile(
          icon: Icons.edit_note_outlined,
          title: strings.sftpEditLimit,
          value: formatLimitBytes(appSnapshot.sftpTextEditLimitBytes),
          onTap: () => editSftpLimit(
            title: strings.sftpEditLimit,
            currentBytes: appSnapshot.sftpTextEditLimitBytes,
            onChanged: (bytes) => settings.setSftpLimits(textEditLimit: bytes),
          ),
        ),
      ],
    );
  }
}

class _SecuritySettingsSection extends StatelessWidget {
  final _SettingsSecretSnapshot secretSnapshot;
  final AppStrings strings;
  final SettingsViewModel settings;

  const _SecuritySettingsSection({
    required this.secretSnapshot,
    required this.strings,
    required this.settings,
  });

  @override
  Widget build(BuildContext context) {
    return _SettingsSection(
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
          value: secretSnapshot.cacheEnabled,
          onChanged: (value) async {
            await settings.configureSecretCache(
              value,
              secretSnapshot.cacheTimeoutMinutes,
            );
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.timer_outlined, size: 20),
          title: Text(
            strings.credentialCacheTimeout,
            style: const TextStyle(fontSize: 13),
          ),
          trailing: SizedBox(
            width: 110,
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                isDense: true,
                isExpanded: true,
                value: secretSnapshot.cacheTimeoutMinutes,
                items: [
                  for (final minutes in secretSnapshot.cacheOptions)
                    DropdownMenuItem(
                      value: minutes,
                      child: Text(
                        '${minutes}m',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: secretSnapshot.cacheEnabled
                    ? (minutes) async {
                        if (minutes == null) return;
                        await settings.configureSecretCache(
                          secretSnapshot.cacheEnabled,
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
          secondary: const Icon(Icons.notifications_off_outlined, size: 20),
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
    );
  }
}

class _BackupSettingsSection extends StatelessWidget {
  final AppStrings strings;
  final VoidCallback onExport;
  final VoidCallback onImport;

  const _BackupSettingsSection({
    required this.strings,
    required this.onExport,
    required this.onImport,
  });

  @override
  Widget build(BuildContext context) {
    return _SettingsSection(
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
          onTap: onExport,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.download_for_offline_outlined, size: 20),
          title: Text(
            strings.importAppData,
            style: const TextStyle(fontSize: 13),
          ),
          subtitle: Text(
            strings.importAppDataWarning,
            style: const TextStyle(fontSize: 11),
          ),
          onTap: onImport,
        ),
      ],
    );
  }
}
