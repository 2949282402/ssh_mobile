import 'dart:async';

import 'package:feature_connection/feature_connection.dart'
    as feature_connection;
import 'package:feature_lan_share/feature_lan_share.dart' as feature_lan_share;
import 'package:feature_mcp/feature_mcp.dart' as feature_mcp;
import 'package:feature_playbook/feature_playbook.dart' as feature_playbook;
import 'package:feature_rag/feature_rag.dart' as feature_rag;
import 'package:feature_sftp/feature_sftp.dart' as feature_sftp;
import 'package:feature_terminal/feature_terminal.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ssh_core/ssh_core.dart';

import '../features/settings/viewmodels/settings_viewmodel.dart';
import '../features/ai_skills/viewmodels/ai_skills_viewmodel.dart';
import '../features/startup/viewmodels/startup_viewmodel.dart';
import '../features/developer_panel/views/developer_panel_floating.dart';
import 'package:ssh_mobile/features/ai_skills/views/ai_skills_screen.dart';
import 'package:ssh_mobile/features/ai_skills/views/ai_skill_edit_screen.dart';
import 'package:ssh_mobile/features/home/views/home_screen.dart';
import 'package:ssh_mobile/features/startup/views/startup_screen.dart';
import '../services/app_settings.dart';
import '../services/storage_service.dart';
import 'package:app_ui/app_ui.dart';
import 'app_runtime.dart';
import 'connection_feature_adapters.dart';
import 'lan_share_feature_adapters.dart';
import 'terminal_feature_adapters.dart';
import 'sftp_feature_adapters.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// App Shell。它只消费由 [AppRuntime] 创建的 App Scope 实例。
class SshMobileApp extends StatefulWidget {
  const SshMobileApp({super.key, this.runtime});

  /// 真实入口始终传入 Runtime；可空仅保留旧的构造型 smoke test 兼容面。
  final AppRuntime? runtime;

  @override
  State<SshMobileApp> createState() => _SshMobileAppState();
}

class _SshMobileAppState extends State<SshMobileApp>
    with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  AppTerminalSettingsAdapter? _terminalSettingsAdapter;
  AppTerminalShortcutAdapter? _terminalShortcutAdapter;

  static final Map<AppColorPalette, ThemeData> _lightThemes = {
    for (final palette in AppColorPalette.values)
      palette: AppTheme.lightThemeFor(palette: palette),
  };
  static final Map<AppColorPalette, ThemeData> _darkThemes = {
    for (final palette in AppColorPalette.values)
      palette: AppTheme.darkThemeFor(palette: palette),
  };
  static final Map<AppColorPalette, ThemeData> _oledDarkThemes = {
    for (final palette in AppColorPalette.values)
      palette: AppTheme.darkThemeFor(oledDark: true, palette: palette),
  };
  static final Map<AppColorPalette, ShadThemeData> _shadLightThemes = {
    for (final palette in AppColorPalette.values)
      palette: _buildShadTheme(palette, Brightness.light),
  };
  static final Map<AppColorPalette, ShadThemeData> _shadDarkThemes = {
    for (final palette in AppColorPalette.values)
      palette: _buildShadTheme(palette, Brightness.dark),
  };

  static ShadThemeData _buildShadTheme(
    AppColorPalette palette,
    Brightness brightness,
  ) {
    final dark = brightness == Brightness.dark;
    final materialTheme = dark
        ? AppTheme.darkThemeFor(palette: palette)
        : AppTheme.lightThemeFor(palette: palette);
    final colors = materialTheme.colorScheme;
    final base = dark
        ? const ShadVioletColorScheme.dark()
        : const ShadVioletColorScheme.light();
    return ShadThemeData(
      brightness: brightness,
      radius: const BorderRadius.all(Radius.circular(AppTheme.radiusSmall)),
      colorScheme: base.copyWith(
        background: materialTheme.scaffoldBackgroundColor,
        foreground: colors.onSurface,
        card: colors.surface,
        cardForeground: colors.onSurface,
        popover: colors.surface,
        popoverForeground: colors.onSurface,
        primary: colors.primary,
        primaryForeground: colors.onPrimary,
        secondary: colors.surfaceContainer,
        secondaryForeground: colors.onSurface,
        muted: colors.surfaceContainer,
        mutedForeground: colors.onSurfaceVariant,
        accent: Color.alphaBlend(
          colors.primary.withValues(alpha: 0.14),
          colors.surfaceContainer,
        ),
        accentForeground: colors.onSurface,
        border: colors.outline,
        input: colors.outline,
        ring: colors.primary,
        selection: colors.primary.withValues(alpha: 0.2),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_runtime.mcpServerController.startIfEnabled());
    });
  }

  AppRuntime get _runtime {
    final runtime = widget.runtime;
    if (runtime == null) {
      throw StateError('SshMobileApp requires an AppRuntime to build.');
    }
    return runtime;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_runtime.storageService.flushPendingWrites());
    }
    if (state == AppLifecycleState.detached) {
      unawaited(_runtime.mcpServerController.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _terminalSettingsAdapter?.dispose();
    _terminalShortcutAdapter?.dispose();
    final runtime = widget.runtime;
    if (runtime != null) {
      unawaited(runtime.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final runtime = _runtime;
    final terminalSettings = _terminalSettingsAdapter ??=
        AppTerminalSettingsAdapter(runtime.appSettings);
    final terminalShortcuts = _terminalShortcutAdapter ??=
        AppTerminalShortcutAdapter(runtime.shortcutCommandService);
    final terminalConnections = AppTerminalConnectionAdapter(
      navigatorKey: _navigatorKey,
      storageService: runtime.storageService,
      sshService: runtime.sshService,
    );
    final terminalLogger = AppTerminalLoggerAdapter(runtime.appLogService);
    final lanLogger = AppLanShareLoggerAdapter(runtime.appLogService);
    final connectionRepository = AppConnectionRepositoryAdapter(
      primary: runtime.connectionRepository,
      legacy: runtime.storageService,
    );
    final credentialRepository = AppConnectionCredentialAdapter(
      primary: runtime.credentialRepository,
      legacy: runtime.storageService,
    );
    final hostKeyRepository = AppConnectionHostKeyAdapter(
      primary: runtime.hostKeyRepository,
      legacy: runtime.storageService,
    );
    final connectionRuntime = AppConnectionRuntimeAdapter(
      sshServiceFactory: () => runtime.sshService,
      sftpServiceFactory: () => runtime.sftpService,
      performanceServiceFactory: () => runtime.performanceMonitorService,
    );
    final connectionVerification = AppConnectionVerificationAdapter(
      runtime.storageService,
    );
    return MultiProvider(
      providers: [
        // Runtime 已经拥有这些实例，.value 防止 Provider 误替它们释放。
        Provider<AppRuntime>.value(value: runtime),
        Provider<SshSessionManager>.value(value: runtime.sshSessionManager),
        ListenableProvider<TerminalSettingsPort>.value(value: terminalSettings),
        ListenableProvider<TerminalShortcutPort>.value(
          value: terminalShortcuts,
        ),
        Provider<TerminalConnectionPort>.value(value: terminalConnections),
        Provider<TerminalLoggerPort>.value(value: terminalLogger),
        ChangeNotifierProvider.value(value: runtime.appLogService),
        ChangeNotifierProvider.value(value: runtime.storageService),
        ChangeNotifierProvider.value(value: runtime.appSettings),
        ListenableProvider<feature_lan_share.LanShareSettingsPort>.value(
          value: runtime.lanShareSettingsAdapter,
        ),
        Provider<feature_lan_share.LanShareLoggerPort>.value(value: lanLogger),
        Provider<feature_lan_share.LanShareModule>.value(
          value: runtime.lanShareModule,
        ),
        ListenableProvider<feature_playbook.PlaybookSettingsPort>.value(
          value: runtime.playbookSettingsAdapter,
        ),
        ListenableProvider<
          feature_playbook.PlaybookConnectionCatalogPort
        >.value(value: runtime.playbookConnectionCatalogAdapter),
        ChangeNotifierProxyProvider<
          AppSettings,
          feature_connection.ConnectionStrings
        >(
          create: (_) => feature_connection.ConnectionStrings(),
          update: (_, settings, strings) {
            final next = strings ?? feature_connection.ConnectionStrings();
            next.setLanguage(
              settings.language == AppLanguage.en
                  ? feature_connection.ConnectionLanguage.english
                  : feature_connection.ConnectionLanguage.chinese,
            );
            return next;
          },
        ),
        Provider<feature_connection.ConnectionUiAdapter>.value(
          value: AppConnectionUiAdapter(),
        ),
        ChangeNotifierProvider.value(value: runtime.bootstrapCoordinator),
        ChangeNotifierProvider.value(value: runtime.shortcutCommandService),
        ChangeNotifierProvider.value(value: runtime.sshService),
        ChangeNotifierProvider.value(value: runtime.sftpService),
        ChangeNotifierProvider.value(value: runtime.performanceMonitorService),
        ChangeNotifierProvider.value(value: runtime.playbookService),
        ListenableProvider<feature_playbook.PlaybookAutomationPort>.value(
          value: runtime.playbookService,
        ),
        ListenableProvider<feature_rag.RagSettingsPort>.value(
          value: runtime.ragSettingsAdapter,
        ),
        ChangeNotifierProvider<feature_rag.RagService>.value(
          value: runtime.ragService,
        ),
        ListenableProvider<feature_rag.RagCapability>.value(
          value: runtime.ragService,
        ),
        ChangeNotifierProvider<feature_mcp.McpServerController>.value(
          value: runtime.mcpModule.service,
        ),
        ListenableProvider<feature_mcp.McpSettingsPort>.value(
          value: runtime.mcpSettingsAdapter,
        ),
        ChangeNotifierProvider<feature_connection.ConnectionViewModel>(
          // ViewModel 仍由根页面提供，数据和运行时能力已通过公共契约注入。
          create: (_) => feature_connection.ConnectionViewModel(
            connectionRepository: connectionRepository,
            credentialRepository: credentialRepository,
            hostKeyRepository: hostKeyRepository,
            runtimePort: connectionRuntime,
            verificationPort: connectionVerification,
          )..fetchConnections(),
        ),
        ChangeNotifierProvider(
          create: (_) => SettingsViewModel(
            appSettings: runtime.appSettings,
            storageService: runtime.storageService,
          ),
        ),
        ChangeNotifierProvider<feature_lan_share.LanReceiverCoordinator>.value(
          value: runtime.lanReceiverCoordinator,
        ),
      ],
      child: Builder(builder: (context) => _buildApp(context)),
    );
  }

  /// 构建只依赖 AppRuntime Provider 的 Material/Shad Shell。
  Widget _buildApp(BuildContext context) {
    final visualSettings = context
        .select<AppSettings, AppVisualSettingsSnapshot>(
          (settings) => settings.visualSettings,
        );
    final darkMode = visualSettings.themeMode == ThemeMode.dark;
    final palette = visualSettings.colorPalette;

    return ScrollConfiguration(
      behavior: const ShadScrollBehavior(),
      child: ShadTheme(
        data: darkMode ? _shadDarkThemes[palette]! : _shadLightThemes[palette]!,
        child: ShadMouseAreaSurface(
          child: ShadMouseCursorProvider(
            child: Builder(
              builder: (context) {
                return MaterialApp(
                  navigatorKey: _navigatorKey,
                  title: 'SSH Mobile',
                  debugShowCheckedModeBanner: false,
                  theme: _lightThemes[palette],
                  darkTheme: visualSettings.oledDark
                      ? _oledDarkThemes[palette]
                      : _darkThemes[palette],
                  themeMode: visualSettings.themeMode,
                  themeAnimationDuration: Duration.zero,
                  builder: (context, child) {
                    final mediaQuery = MediaQuery.of(context);
                    final adaptedMediaQuery = adaptMobileMediaQuery(mediaQuery);
                    final visualDensity = mobileVisualDensityFor(mediaQuery);
                    final effectiveChild = child ?? const SizedBox.shrink();
                    final shadChild = DeveloperPanelFloatingHost(
                      child: feature_lan_share.NetworkIncomingTransferHost(
                        child: feature_lan_share.LanPairingNavigationHost(
                          navigatorKey: _navigatorKey,
                          child: ShadAppBuilder(child: effectiveChild),
                        ),
                      ),
                    );

                    final currentTheme = Theme.of(context);
                    if (identical(adaptedMediaQuery, mediaQuery) &&
                        visualDensity == currentTheme.visualDensity) {
                      return shadChild;
                    }

                    return MediaQuery(
                      data: adaptedMediaQuery,
                      child: currentTheme.visualDensity == visualDensity
                          ? shadChild
                          : Theme(
                              data: currentTheme.copyWith(
                                visualDensity: visualDensity,
                              ),
                              child: shadChild,
                            ),
                    );
                  },
                  initialRoute: '/',
                  onGenerateRoute: (settings) {
                    switch (settings.name) {
                      case '/':
                        return MaterialPageRoute(
                          builder: (_) => ChangeNotifierProvider(
                            create: (context) => StartupViewModel(
                              storageService: context.read<StorageService>(),
                              appSettings: context.read<AppSettings>(),
                            ),
                            child: const StartupScreen(),
                          ),
                        );
                      case '/terminal':
                        final config =
                            settings.arguments as Map<String, dynamic>;
                        return MaterialPageRoute(
                          builder: (_) => AppTerminalModuleScope(
                            child: TerminalScreen(
                              connectionId: config['id'] as String,
                              sessionId: config['sessionId'] as String,
                            ),
                          ),
                        );
                      case '/history':
                        return MaterialPageRoute(
                          builder: (_) => const AppTerminalModuleScope(
                            child: TerminalHistoryScreen(),
                          ),
                        );
                      case '/terminal-windows':
                        final args = settings.arguments;
                        String? connectionId;

                        if (args is String) {
                          connectionId = args;
                        } else if (args is Map<String, dynamic>) {
                          final value = args['connectionId'];
                          if (value is String) {
                            connectionId = value;
                          }
                        }

                        return MaterialPageRoute(
                          builder: (_) => AppTerminalModuleScope(
                            child: TerminalWindowsScreen(
                              connectionId: connectionId,
                            ),
                          ),
                        );
                      case '/sftp':
                        return MaterialPageRoute(
                          builder: (_) => const AppSftpModuleScope(
                            child: feature_sftp.SftpScreen(),
                          ),
                        );
                      case '/performance':
                        return MaterialPageRoute(
                          builder: (_) => const HomeScreen(initialIndex: 3),
                        );
                      case '/ai-skills':
                        return MaterialPageRoute(
                          builder: (_) => ChangeNotifierProvider(
                            create: (context) => AiSkillsViewModel(
                              storageService: context.read<StorageService>(),
                              appSettings: context.read<AppSettings>(),
                            ),
                            child: const AiSkillsScreen(),
                          ),
                        );
                      case '/ai-skills/edit':
                        final args = settings.arguments as Map<String, dynamic>;
                        final viewModel =
                            args['viewModel'] as AiSkillsViewModel;
                        return MaterialPageRoute(
                          builder: (_) => ChangeNotifierProvider.value(
                            value: viewModel,
                            child: const AiSkillEditScreen(),
                          ),
                        );
                      case '/playbooks':
                        return MaterialPageRoute(
                          builder: (context) =>
                              feature_playbook.PlaybookFeatureScope(
                                module: _runtime.playbookModule,
                                settings: context
                                    .read<
                                      feature_playbook.PlaybookSettingsPort
                                    >(),
                                connectionCatalog: context
                                    .read<
                                      feature_playbook.PlaybookConnectionCatalogPort
                                    >(),
                                child: const feature_playbook.PlaybookScreen(),
                              ),
                        );
                      case '/add':
                        return MaterialPageRoute(
                          builder: (_) =>
                              const feature_connection.AddEditScreen(),
                        );
                      case '/edit':
                        final id = settings.arguments as String;
                        return MaterialPageRoute(
                          builder: (_) =>
                              feature_connection.AddEditScreen(editId: id),
                        );
                      case '/rag-knowledge':
                        return MaterialPageRoute(
                          builder: (_) => feature_rag.RagFeatureScope(
                            module: _runtime.ragModule,
                            child: const feature_rag.RagKnowledgeScreen(),
                          ),
                        );
                      case '/mcp-console':
                        return MaterialPageRoute(
                          builder: (_) => feature_mcp.McpFeatureScope(
                            module: _runtime.mcpModule,
                            child: const feature_mcp.McpConsoleScreen(),
                          ),
                        );
                      case '/mcp-settings':
                        return MaterialPageRoute(
                          builder: (context) => ChangeNotifierProvider(
                            create: (_) => feature_mcp.McpSettingsViewModel(
                              settingsPort: context
                                  .read<feature_mcp.McpSettingsPort>(),
                              controller: context
                                  .read<feature_mcp.McpServerController>(),
                            ),
                            child: const feature_mcp.McpSettingsScreen(),
                          ),
                        );
                      default:
                        return MaterialPageRoute(
                          builder: (_) => const HomeScreen(),
                        );
                    }
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
