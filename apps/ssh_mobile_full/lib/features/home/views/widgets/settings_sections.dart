part of '../home_screen.dart';

class _SettingsSection extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SettingsSection({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return AppSection(
      title: title,
      padding: const EdgeInsets.symmetric(vertical: 6),
      headerGap: 4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

class _AppearanceSettingsSection extends StatelessWidget {
  final _SettingsAppSnapshot appSnapshot;
  final AppStrings strings;
  final SettingsViewModel settings;

  const _AppearanceSettingsSection({
    required this.appSnapshot,
    required this.strings,
    required this.settings,
  });

  @override
  Widget build(BuildContext context) {
    void changeLanguage() {
      settings.changeLanguage(
        settings.language == AppLanguage.en ? AppLanguage.zh : AppLanguage.en,
      );
    }

    String paletteLabel(AppColorPalette palette) => switch (palette) {
      AppColorPalette.monochrome => strings.paletteMonochrome,
      AppColorPalette.indigo => strings.paletteIndigo,
      AppColorPalette.ocean => strings.paletteOcean,
      AppColorPalette.emerald => strings.paletteEmerald,
      AppColorPalette.rose => strings.paletteRose,
      AppColorPalette.amber => strings.paletteAmber,
    };

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
              title: Text(strings.languageLabel),
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
          ),
          value: appSnapshot.isDarkMode,
          onChanged: (_) => settings.changeThemeMode(
            settings.isDarkMode ? ThemeMode.light : ThemeMode.dark,
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.color_lens_outlined, size: 20),
          title: Text(strings.colorPalette),
        ),
        SingleChildScrollView(
          key: const ValueKey('app-color-palette-selector'),
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final palette in AppColorPalette.values) ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: ChoiceChip(
                    key: ValueKey('app-color-palette-${palette.name}'),
                    selected: appSnapshot.colorPalette == palette,
                    avatar: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppTheme.paletteColors(
                          palette,
                          Theme.of(context).brightness,
                        ).primary,
                        shape: BoxShape.circle,
                      ),
                      child: const SizedBox.square(dimension: 16),
                    ),
                    label: Text(paletteLabel(palette)),
                    onSelected: (_) => settings.setColorPalette(palette),
                  ),
                ),
                if (palette != AppColorPalette.values.last)
                  const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        if (appSnapshot.isDarkMode)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.brightness_2, size: 20),
            title: Text(strings.oledDarkMode),
            value: appSnapshot.oledDark,
            onChanged: settings.setOledDark,
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
          title: Text(strings.credentialCache),
          subtitle: Text(strings.credentialCacheHint),
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
          title: Text(strings.credentialCacheTimeout),
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
                      child: Text('${minutes}m', maxLines: 1),
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
          title: Text(strings.notificationServerNames),
          subtitle: Text(strings.notificationServerNamesHint),
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
          title: Text(strings.exportAppData),
          subtitle: Text(strings.backupContainsSecrets),
          onTap: onExport,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.download_for_offline_outlined, size: 20),
          title: Text(strings.importAppData),
          subtitle: Text(strings.importAppDataWarning),
          onTap: onImport,
        ),
      ],
    );
  }
}

class _DeveloperSettingsSection extends StatelessWidget {
  final AppStrings strings;
  final SettingsViewModel settings;

  const _DeveloperSettingsSection({
    required this.strings,
    required this.settings,
  });

  @override
  Widget build(BuildContext context) {
    return _SettingsSection(
      title: strings.developerMode,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(strings.developerMode),
          subtitle: Text(strings.developerModeHint),
          value: settings.developerMode,
          onChanged: settings.setDeveloperMode,
        ),
        if (settings.developerMode) ...[
          const Divider(height: 1),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(strings.developerPanelFloating),
            subtitle: Text(strings.developerPanelFloatingHint),
            value: settings.developerPanelFloating,
            onChanged: settings.setDeveloperPanelFloating,
          ),
          const Divider(height: 1),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.dashboard_outlined, size: 20),
            title: Text(strings.developerPanel),
            trailing: const Icon(Icons.chevron_right_rounded, size: 18),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      const feature_developer.DeveloperPanelScreen(),
                ),
              );
            },
          ),
        ],
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.bug_report_outlined, size: 20),
          title: Text(strings.developerLogs),
          trailing: const Icon(Icons.chevron_right_rounded, size: 18),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChangeNotifierProvider(
                  create: (context) => feature_developer.DeveloperLogViewModel(
                    logService: context
                        .read<feature_developer.DeveloperLogPort>(),
                    settings: context
                        .read<feature_developer.DeveloperSettingsPort>(),
                  ),
                  child: const feature_developer.DeveloperLogPage(),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Cross-links from the global settings page to the feature-owned settings
/// screens (SFTP limits, terminal appearance, LAN share, MCP). These only link
/// out; the settings themselves stay on their feature pages.
class _FeatureSettingsSection extends StatelessWidget {
  final AppStrings strings;

  const _FeatureSettingsSection({required this.strings});

  @override
  Widget build(BuildContext context) {
    return _SettingsSection(
      title: strings.featureSettings,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.folder_copy_outlined, size: 20),
          title: Text(strings.sftpSettings),
          trailing: const Icon(Icons.chevron_right_rounded, size: 18),
          onTap: () {
            final connectionViewModel = context.read<ConnectionViewModel?>();
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => connectionViewModel != null
                    ? ChangeNotifierProvider<ConnectionViewModel>.value(
                        value: connectionViewModel,
                        child: const AppSftpModuleScope(
                          child: feature_sftp.SftpSettingsScreen(),
                        ),
                      )
                    : const AppSftpModuleScope(
                        child: feature_sftp.SftpSettingsScreen(),
                      ),
              ),
            );
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.terminal_outlined, size: 20),
          title: Text(strings.terminalAppearance),
          trailing: const Icon(Icons.chevron_right_rounded, size: 18),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TerminalSettingsScreen()),
            );
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.cast_outlined, size: 20),
          title: Text(strings.lanShareSettings),
          trailing: const Icon(Icons.chevron_right_rounded, size: 18),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const feature_lan_share.LanShareFeatureScope(
                  child: feature_lan_share.LanShareSettingsScreen(),
                ),
              ),
            );
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.hub_outlined, size: 20),
          title: Text(strings.openMcpSettings),
          trailing: const Icon(Icons.chevron_right_rounded, size: 18),
          onTap: () => Navigator.pushNamed(context, '/mcp-settings'),
        ),
      ],
    );
  }
}
