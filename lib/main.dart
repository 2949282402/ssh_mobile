import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/add_edit_screen.dart';
import 'screens/ai_skills_screen.dart';
import 'screens/home_screen.dart';
import 'screens/performance_monitor_screen.dart';
import 'screens/sftp_screen.dart';
import 'screens/startup_screen.dart';
import 'screens/terminal_history_screen.dart';
import 'screens/terminal_screen.dart';
import 'services/app_log_service.dart';
import 'services/background_service.dart';
import 'services/app_settings.dart';
import 'services/performance_monitor_service.dart';
import 'services/shortcut_command_service.dart';
import 'services/ssh_service.dart';
import 'services/sftp_service.dart';
import 'services/storage_service.dart';
import 'theme/app_theme.dart';
import 'utils/responsive.dart';

Future<void> main() async {
  final appLogService = AppLogService();

  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      appLogService.install();
      appLogService.info('Application bootstrap started');

      final storageService = StorageService();
      final sshService = SshService(storageService);
      final sftpService = SftpService(storageService);
      final performanceMonitorService =
          PerformanceMonitorService(sshService, storageService);
      final appSettings = AppSettings();
      final shortcutCommandService = ShortcutCommandService();

      runApp(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: appSettings),
            ChangeNotifierProvider.value(value: shortcutCommandService),
            ChangeNotifierProvider.value(value: appLogService),
            ChangeNotifierProvider.value(value: storageService),
            ChangeNotifierProvider.value(value: sshService),
            ChangeNotifierProvider.value(value: sftpService),
            ChangeNotifierProvider.value(value: performanceMonitorService),
          ],
          child: const SshMobileApp(),
        ),
      );

      unawaited(appSettings.init());
      unawaited(
        storageService.init().then((_) {
          appLogService.info('Storage initialized');
          return sshService.restoreTmuxSessions();
        }),
      );
      unawaited(shortcutCommandService.init());

      WidgetsBinding.instance.addPostFrameCallback((_) {
        Timer(const Duration(milliseconds: 900), () {
          unawaited(
            BackgroundServiceManager.prewarm().timeout(
              const Duration(seconds: 2),
              onTimeout: () {
                appLogService.warning('Background service prewarm timed out');
              },
            ),
          );
        });
      });
    },
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(context.read<StorageService>().flushPendingWrites());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(context.read<StorageService>().flushPendingWrites());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();

    return MaterialApp(
      title: 'SSH Mobile',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightThemeFor(settings.fontFamily),
      darkTheme: AppTheme.darkThemeFor(settings.fontFamily),
      themeMode: settings.themeMode,
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        final adaptedMediaQuery = adaptMobileMediaQuery(mediaQuery);
        final visualDensity = mobileVisualDensityFor(mediaQuery);
        final effectiveChild = child ?? const SizedBox.shrink();
        if (identical(adaptedMediaQuery, mediaQuery) &&
            visualDensity == VisualDensity.standard) {
          return effectiveChild;
        }

        return MediaQuery(
          data: adaptedMediaQuery,
          child: Theme(
            data: Theme.of(context).copyWith(
              visualDensity: visualDensity,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: effectiveChild,
          ),
        );
      },
      initialRoute: '/',
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case '/':
            return MaterialPageRoute(
              builder: (_) => const StartupScreen(),
            );
          case '/terminal':
            final config = settings.arguments as Map<String, dynamic>;
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
          case '/sftp':
            return MaterialPageRoute(
              builder: (_) => const SftpScreen(),
            );
          case '/performance':
            return MaterialPageRoute(
              builder: (_) => const PerformanceMonitorScreen(),
            );
          case '/ai-skills':
            return MaterialPageRoute(
              builder: (_) => const AiSkillsScreen(),
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
          default:
            return MaterialPageRoute(
              builder: (_) => const HomeScreen(),
            );
        }
      },
    );
  }
}
