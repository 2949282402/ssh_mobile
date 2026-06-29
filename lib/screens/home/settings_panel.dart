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
                TextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'MB',
                    helperText: strings.sftpLimitDialogHint,
                    errorText: errorText,
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
    final settings = context.read<SettingsViewModel>();
    final storage = context.read<SettingsViewModel>();
    final strings = AppStrings(appSnapshot.language);
    final colorScheme = Theme.of(context).colorScheme;
    final cacheEnabled = secretSnapshot.cacheEnabled;
    final cacheTimeoutMinutes = secretSnapshot.cacheTimeoutMinutes;
    final cacheOptions = secretSnapshot.cacheOptions;

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
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
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
