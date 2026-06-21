import 'app_database.dart';

Future<void> ensureAppDatabaseOpen(AppDatabase database) async {
  await database.customSelect('SELECT 1').getSingle();
}
