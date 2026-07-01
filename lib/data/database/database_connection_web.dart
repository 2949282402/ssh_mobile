import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

QueryExecutor openDatabaseConnection() {
  return driftDatabase(name: 'ssh_mobile');
}

QueryExecutor openTestDatabaseConnection() =>
    driftDatabase(name: 'ssh_mobile_test');

bool get isFlutterTestEnvironment => false;
