import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/add_edit_screen.dart';
import 'screens/home_screen.dart';
import 'screens/terminal_screen.dart';
import 'services/ssh_service.dart';
import 'services/storage_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final storageService = StorageService();
  await storageService.init();

  final sshService = SshService(storageService);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: storageService),
        ChangeNotifierProvider.value(value: sshService),
      ],
      child: const SshMobileApp(),
    ),
  );
}

class SshMobileApp extends StatelessWidget {
  const SshMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SSH Mobile',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      initialRoute: '/',
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case '/':
            return MaterialPageRoute(
              builder: (_) => const HomeScreen(),
            );
          case '/terminal':
            final config = settings.arguments as Map<String, dynamic>;
            return MaterialPageRoute(
              builder: (_) => TerminalScreen(
                connectionId: config['id'] as String,
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
