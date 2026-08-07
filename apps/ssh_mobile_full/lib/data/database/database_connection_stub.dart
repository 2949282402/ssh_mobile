import 'package:drift/drift.dart';

QueryExecutor openDatabaseConnection() =>
    throw UnsupportedError('Cannot open database on this platform');
QueryExecutor openTestDatabaseConnection() =>
    throw UnsupportedError('Cannot open test database on this platform');
bool get isFlutterTestEnvironment => false;
