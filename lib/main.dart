import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/add_edit_screen.dart';
import 'screens/home_screen.dart';
import 'screens/startup_screen.dart';
import 'screens/terminal_screen.dart';
import 'services/background_service.dart';
import 'services/app_settings.dart';
import 'services/shortcut_command_service.dart';
import 'services/ssh_service.dart';
import 'services/storage_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final storageService = StorageService();
  final sshService = SshService(storageService);
  final appSettings = AppSettings();
  final shortcutCommandService = ShortcutCommandService();

  await appSettings.init();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appSettings),
        ChangeNotifierProvider.value(value: shortcutCommandService),
        ChangeNotifierProvider.value(value: storageService),
        ChangeNotifierProvider.value(value: sshService),
      ],
      child: const SshMobileApp(),
    ),
  );

  unawaited(
    storageService.init().then((_) => sshService.restoreTmuxSessions()),
  );
  shortcutCommandService.init();

  WidgetsBinding.instance.addPostFrameCallback((_) {
    Timer(const Duration(milliseconds: 900), () {
      unawaited(
        BackgroundServiceManager.prewarm().timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        ),
      );
    });
  });
}

class SshMobileApp extends StatelessWidget {
  const SshMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();

    return MaterialApp(
      title: 'SSH Mobile',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: settings.themeMode,
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
