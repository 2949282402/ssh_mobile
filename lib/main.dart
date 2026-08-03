import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'features/connection/views/add_edit_screen.dart';
import 'features/connection/viewmodels/connection_viewmodel.dart';
import 'features/ai_chat/services/ai_chat_runtime_factory.dart';
import 'features/settings/viewmodels/settings_viewmodel.dart';
import 'features/playbook/viewmodels/playbook_viewmodel.dart';
import 'features/rag/viewmodels/rag_knowledge_viewmodel.dart';
import 'features/ai_skills/viewmodels/ai_skills_viewmodel.dart';
import 'features/startup/viewmodels/startup_viewmodel.dart';
import 'features/sftp/sftp_feature_scope.dart';
import 'features/lan_share/services/lan_receiver_coordinator.dart';
import 'features/lan_share/views/lan_pairing_navigation_host.dart';
import 'features/lan_share/views/network_incoming_transfer_host.dart';
import 'features/developer_panel/views/developer_panel_floating.dart';
import 'package:ssh_mobile/features/ai_skills/views/ai_skills_screen.dart';
import 'package:ssh_mobile/features/ai_skills/views/ai_skill_edit_screen.dart';
import 'package:ssh_mobile/features/home/views/home_screen.dart';
import 'package:ssh_mobile/features/playbook/views/playbook_screen.dart';
import 'package:ssh_mobile/features/sftp/views/sftp_screen.dart';
import 'package:ssh_mobile/features/startup/views/startup_screen.dart';
import 'package:ssh_mobile/features/terminal/views/terminal_history_screen.dart';
import 'package:ssh_mobile/features/terminal/views/terminal_screen.dart';
import 'package:ssh_mobile/features/terminal/views/terminal_windows_screen.dart';
import 'package:ssh_mobile/features/rag/views/rag_knowledge_screen.dart';
import 'package:ssh_mobile/features/mcp_console/views/mcp_console_screen.dart';
import 'package:ssh_mobile/features/mcp_console/viewmodels/mcp_console_viewmodel.dart';
import 'package:ssh_mobile/features/mcp_console/views/mcp_settings_screen.dart';
import 'package:ssh_mobile/features/mcp_console/viewmodels/mcp_settings_viewmodel.dart';
import 'services/app_log_service.dart';
import 'services/display_mode_service.dart';
import 'services/app_settings.dart';
import 'services/performance_monitor_service.dart';
import 'services/shortcut_command_service.dart';
import 'services/playbook_service.dart';
import 'services/ssh_service.dart';
import 'services/sftp_service.dart';
import 'services/storage_service.dart';
import 'services/rag_service.dart';
import 'services/mcp/mcp_server_controller.dart';
import 'theme/app_theme.dart';
import 'services/app_bootstrap_coordinator.dart';
import 'utils/startup_instrumentation.dart';
import 'utils/responsive.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// 应用入口。在 runZonedGuarded 中初始化所有核心服务
/// 并通过 MultiProvider 注入 Widget 树。
///
/// 初始化顺序：依赖链从底向上。
/// AppBootstrapCoordinator 异步初始化核心设置与存储，避免阻塞首屏。
Future<void> main() async {
  final appLogService = AppLogService();

  // runZonedGuarded 捕获所有未处理的异步异常，避免应用直接崩溃
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      StartupInstrumentation.instance.recordMainStart();
      appLogService.install(); // 替换 debugPrint / FlutterError.onError 等全局钩子
      appLogService.info('Application bootstrap started');
      unawaited(SharedPreferences.getInstance());
      unawaited(DisplayModeService.enableHighRefreshRate());

      final appSettings = AppSettings();
      final storageService = StorageService();
      final bootstrapCoordinator = AppBootstrapCoordinator(
        appSettings: appSettings,
        storageService: storageService,
      );
      unawaited(bootstrapCoordinator.ensureBootstrap());

      storageService.registerOnImportCallback(appSettings.init);

      StartupInstrumentation.instance.recordRunAppStart();

      // --- 服务装配与异步加载通过 MultiProvider 懒加载自动完成 ---
      runApp(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: appLogService),
            ChangeNotifierProvider.value(value: storageService),
            ChangeNotifierProvider.value(value: appSettings),
            ChangeNotifierProvider.value(value: bootstrapCoordinator),
            ChangeNotifierProvider(
              create: (context) {
                final service = ShortcutCommandService()..init();
                context.read<StorageService>().registerOnImportCallback(
                  service.init,
                );
                return service;
              },
            ),
            ChangeNotifierProvider(
              create: (context) {
                final service = SshService(
                  context.read<StorageService>(),
                  appSettings: context.read<AppSettings>(),
                );
                unawaited(
                  service.ensureInitialized().catchError((
                    Object error,
                    StackTrace stackTrace,
                  ) {
                    appLogService.error(
                      'SSH service initialization failed',
                      error: error,
                      stackTrace: stackTrace,
                    );
                  }),
                );
                return service;
              },
            ),
            ChangeNotifierProvider(
              create: (context) => SftpService(context.read<StorageService>()),
            ),
            ChangeNotifierProvider(
              create: (context) => PerformanceMonitorService(
                context.read<SshService>(),
                context.read<StorageService>(),
                appSettings: context.read<AppSettings>(),
              ),
            ),
            ChangeNotifierProvider(
              create: (context) => PlaybookService(
                storageService: context.read<StorageService>(),
                sshService: context.read<SshService>(),
              ),
            ),
            ChangeNotifierProvider(
              create: (context) {
                final service = RagService(
                  storageService: context.read<StorageService>(),
                );
                context.read<StorageService>().registerOnImportCallback(() {
                  return service.init(force: true);
                });
                return service;
              },
            ),
            ChangeNotifierProvider(
              create: (context) => McpServerController(
                appSettings: context.read<AppSettings>(),
                activityRepository: context.read<StorageService>(),
                toolServiceFactory: () => AiChatRuntimeFactory(
                  storageService: context.read<StorageService>(),
                  sshService: context.read<SshService>(),
                  sftpService: context.read<SftpService>(),
                  performanceMonitorService: context
                      .read<PerformanceMonitorService>(),
                  playbookService: context.read<PlaybookService>(),
                  ragService: context.read<RagService>(),
                  appSettings: context.read<AppSettings>(),
                ).createToolService(),
              ),
            ),
            ChangeNotifierProvider(
              create: (context) => ConnectionViewModel(
                connectionRepository: context.read<StorageService>(),
                sshServiceFactory: () => context.read<SshService>(),
                sftpServiceFactory: () => context.read<SftpService>(),
                performanceServiceFactory: () =>
                    context.read<PerformanceMonitorService>(),
              )..fetchConnections(),
            ),
            ChangeNotifierProvider(
              create: (context) => SettingsViewModel(
                appSettings: context.read<AppSettings>(),
                storageService: context.read<StorageService>(),
              ),
            ),
            ChangeNotifierProvider(
              create: (context) => LanReceiverCoordinator(
                storageService: context.read<StorageService>(),
                appSettings: context.read<AppSettings>(),
              ),
            ),
          ],
          child: const SshMobileApp(),
        ),
      );
    },
    // 全局未捕获异常处理
    (error, stackTrace) {
      appLogService.error(
        'Uncaught zone error',
        error: error,
        stackTrace: stackTrace,
      );
    },
  );
}

class SshMobileApp extends StatefulWidget {
  const SshMobileApp({super.key});

  @override
  State<SshMobileApp> createState() => _SshMobileAppState();
}

class _SshMobileAppState extends State<SshMobileApp>
    with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

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
      unawaited(context.read<McpServerController>().startIfEnabled());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(context.read<StorageService>().flushPendingWrites());
    }
    if (state == AppLifecycleState.detached) {
      unawaited(context.read<McpServerController>().stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(context.read<StorageService>().flushPendingWrites());
    unawaited(context.read<McpServerController>().stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                      child: NetworkIncomingTransferHost(
                        child: LanPairingNavigationHost(
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
                          builder: (_) => TerminalScreen(
                            connectionId: config['id'] as String,
                            sessionId: config['sessionId'] as String,
                          ),
                        );
                      case '/history':
                        return MaterialPageRoute(
                          builder: (_) => const TerminalHistoryScreen(),
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
                          builder: (_) =>
                              TerminalWindowsScreen(connectionId: connectionId),
                        );
                      case '/sftp':
                        return MaterialPageRoute(
                          builder: (_) =>
                              const SftpFeatureScope(child: SftpScreen()),
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
                          builder: (_) => ChangeNotifierProvider(
                            create: (context) => PlaybookViewModel(
                              playbookService: context.read<PlaybookService>(),
                              storageService: context.read<StorageService>(),
                            ),
                            child: const PlaybookScreen(),
                          ),
                        );
                      case '/add':
                        return MaterialPageRoute(
                          builder: (_) => const AddEditScreen(),
                        );
                      case '/edit':
                        final id = settings.arguments as String;
                        return MaterialPageRoute(
                          builder: (_) => AddEditScreen(editId: id),
                        );
                      case '/rag-knowledge':
                        return MaterialPageRoute(
                          builder: (_) => ChangeNotifierProvider(
                            create: (context) => RagKnowledgeViewModel(
                              ragService: context.read<RagService>(),
                              storageService: context.read<StorageService>(),
                            ),
                            child: const RagKnowledgeScreen(),
                          ),
                        );
                      case '/mcp-console':
                        return MaterialPageRoute(
                          builder: (_) => ChangeNotifierProvider(
                            create: (context) => McpConsoleViewModel(
                              context.read<McpServerController>(),
                              context.read<AppSettings>(),
                            ),
                            child: const McpConsoleScreen(),
                          ),
                        );
                      case '/mcp-settings':
                        return MaterialPageRoute(
                          builder: (context) => ChangeNotifierProvider(
                            create: (_) => McpSettingsViewModel(
                              appSettings: context.read<AppSettings>(),
                              controller: context.read<McpServerController>(),
                            ),
                            child: const McpSettingsScreen(),
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
