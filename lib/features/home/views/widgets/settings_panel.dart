part of '../home_screen.dart';

class _SettingsPanel extends StatelessWidget {
  final VoidCallback onExport;
  final VoidCallback onImport;

  const _SettingsPanel({required this.onExport, required this.onImport});

  @override
  Widget build(BuildContext context) {
    final appSnapshot = context.select<SettingsViewModel, _SettingsAppSnapshot>(
      _SettingsAppSnapshot.from,
    );
    final secretSnapshot = context
        .select<SettingsViewModel, _SettingsSecretSnapshot>(
          _SettingsSecretSnapshot.from,
        );
    final settings = context.read<SettingsViewModel>();
    final strings = AppStrings(appSnapshot.language);
    final colorScheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

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
              onExport: onExport,
              onImport: onImport,
            ),
            const SizedBox(height: 12),
            _DeveloperSettingsSection(strings: strings, settings: settings),
          ],
        ),
      ),
    );
  }
}

class _SettingsAppSnapshot {
  final AppLanguage language;
  final bool isDarkMode;
  final bool oledDark;
  final AppColorPalette colorPalette;
  final bool developerMode;
  final bool developerPanelFloating;

  const _SettingsAppSnapshot({
    required this.language,
    required this.isDarkMode,
    required this.oledDark,
    required this.colorPalette,
    required this.developerMode,
    required this.developerPanelFloating,
  });

  factory _SettingsAppSnapshot.from(SettingsViewModel settings) {
    return _SettingsAppSnapshot(
      language: settings.language,
      isDarkMode: settings.isDarkMode,
      oledDark: settings.oledDark,
      colorPalette: settings.colorPalette,
      developerMode: settings.developerMode,
      developerPanelFloating: settings.developerPanelFloating,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _SettingsAppSnapshot &&
        other.language == language &&
        other.isDarkMode == isDarkMode &&
        other.oledDark == oledDark &&
        other.colorPalette == colorPalette &&
        other.developerMode == developerMode &&
        other.developerPanelFloating == developerPanelFloating;
  }

  @override
  int get hashCode => Object.hash(
    language,
    isDarkMode,
    oledDark,
    colorPalette,
    developerMode,
    developerPanelFloating,
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
