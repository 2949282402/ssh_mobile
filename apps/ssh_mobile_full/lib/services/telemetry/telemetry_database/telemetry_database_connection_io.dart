// Native 遥测数据库连接实现。
//
// 正式环境使用后台 isolate 打开 SQLite，测试环境使用内存数据库。

import 'dart:ffi';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 遥测数据库文件名（不含扩展名）。
const String telemetryDatabaseFileName = 'telemetry';

typedef _MallocC = Pointer<Uint8> Function(IntPtr size);
typedef _MallocDart = Pointer<Uint8> Function(int size);
typedef _FreeC = Void Function(Pointer<Uint8> ptr);
typedef _FreeDart = void Function(Pointer<Uint8> ptr);
typedef _DlopenC = Pointer<Void> Function(Pointer<Uint8> filename, Int32 flags);
typedef _DlopenDart =
    Pointer<Void> Function(Pointer<Uint8> filename, int flags);

bool _sqliteInitialized = false;

void _ensureSqliteInitialized() {
  if (_sqliteInitialized) return;
  _sqliteInitialized = true;
  if (Platform.isLinux) {
    try {
      final libc = DynamicLibrary.process();
      final malloc = libc.lookupFunction<_MallocC, _MallocDart>('malloc');
      final free = libc.lookupFunction<_FreeC, _FreeDart>('free');
      final dlopen = libc.lookupFunction<_DlopenC, _DlopenDart>('dlopen');
      const candidates = [
        'libsqlite3.so.0',
        'libsqlite3.so',
        '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
        '/usr/lib/x86_64-linux-gnu/libsqlite3.so',
      ];
      for (final soname in candidates) {
        final units = soname.codeUnits;
        final ptr = malloc(units.length + 1);
        for (var i = 0; i < units.length; i++) {
          ptr[i] = units[i];
        }
        ptr[units.length] = 0;
        final res = dlopen(ptr, 0x102); // RTLD_GLOBAL (0x100) | RTLD_NOW (0x2)
        free(ptr);
        if (res.address != 0) break;
      }
    } catch (_) {}
  }
}

/// 打开正式环境的遥测数据库。
QueryExecutor openTelemetryDatabaseConnection() {
  _ensureSqliteInitialized();
  if (isFlutterTestEnvironment) {
    return NativeDatabase.memory();
  }

  return LazyDatabase(() async {
    final directory = await getApplicationSupportDirectory();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final file = File(
      p.join(directory.path, '$telemetryDatabaseFileName.sqlite'),
    );
    return NativeDatabase.createInBackground(file);
  });
}

/// 打开内存测试数据库。
QueryExecutor openTelemetryTestDatabaseConnection() {
  _ensureSqliteInitialized();
  return NativeDatabase.memory();
}

/// 判断当前进程是否由 Flutter 测试 runner 执行。
bool get isFlutterTestEnvironment {
  return Platform.environment['FLUTTER_TEST'] == 'true' ||
      Platform.script.path.endsWith('flutter_tester');
}
