import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

QueryExecutor openDatabaseConnection() {
  if (isFlutterTestEnvironment) {
    return NativeDatabase.memory();
  }

  return LazyDatabase(() async {
    try {
      final directory = await getApplicationSupportDirectory();
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      final file = File(p.join(directory.path, 'ssh_mobile.sqlite'));
      return NativeDatabase.createInBackground(file);
    } catch (_) {
      return NativeDatabase.memory();
    }
  });
}

QueryExecutor openTestDatabaseConnection() => NativeDatabase.memory();

bool get isFlutterTestEnvironment {
  return Platform.environment['FLUTTER_TEST'] == 'true' ||
      Platform.script.path.endsWith('flutter_tester');
}
