part of '../storage_service.dart';

/// Extension defining the buffered write operations for storage service.
///
/// Note: Methods starting with underscore in an extension can only be called
/// within the library (since it's a part of `storage_service.dart`), which is perfect.
/// Public methods like `flushPendingWrites` must be declared on the class itself
/// or as a public extension method, but since Dart extension methods are resolved statically,
/// a public method on `extension _BufferedWriteOps` might not be visible as a member of `StorageService`
/// if `_BufferedWriteOps` is a private extension. Let's make the extension public or move public method to StorageService.
/// Actually, making the extension public (e.g. `extension BufferedWriteOps on StorageService`)
/// solves the issue, as long as it's imported or part of the same library (which it is, since it's a `part`).
/// Even better, we can declare `flushPendingWrites` directly in `StorageService` in `storage_service.dart` and let it delegate to
/// a helper, or just make the extension public!
/// Wait, in Dart, if a client does `context.read<StorageService>().flushPendingWrites()`, and `flushPendingWrites()`
/// is defined in a public extension `extension BufferedWriteOps on StorageService` inside the same library,
/// it will be visible to external users as long as they import `storage_service.dart`!
/// Yes, a public extension on a public class adds public methods to that class.
/// Let's make it `extension BufferedWriteOps on StorageService`.
extension BufferedWriteOps on StorageService {
  /// 加密读取：从 SharedPreferences 读取后，如果已加密则自动解密
  Future<String?> _readProtectedPref(String key) async {
    final value = _prefs?.getString(key);
    if (value == null || value.isEmpty) return value;
    if (!_dataProtection.isEncrypted(value)) return value;
    return _dataProtection.decryptString(value);
  }

  /// 加密写入：先加密再写入 SharedPreferences
  Future<void> _writeProtectedPref(String key, String value) async {
    final encrypted = await _dataProtection.encryptString(value);
    await _prefs!.setString(key, encrypted);
  }

  /// 带防抖的加密写入。
  /// immediate=true：跳过防抖立即写入（用于导出/导入等紧急场景）。
  /// immediate=false：700ms 内多次调用只执行最后一次写入。
  Future<void> _writeProtectedPrefBuffered(
    String key,
    String value, {
    required bool immediate,
  }) {
    if (immediate) {
      final pending = _pendingProtectedPrefWrites[key];
      pending?.timer?.cancel();
      if (pending == null) {
        return _writeProtectedPref(key, value);
      }
      pending.value = value;
      pending.generation++;
      return _flushProtectedPrefWrite(key);
    }

    final pending = _pendingProtectedPrefWrites.putIfAbsent(
      key,
      () => _PendingProtectedPrefWrite(value),
    );
    pending.value = value;
    pending.generation++;
    pending.timer?.cancel();
    pending.timer = Timer(StorageService._protectedPrefWriteDebounce, () {
      unawaited(_flushProtectedPrefWrite(key));
    });
    return Future.value();
  }

  Future<void> flushPendingWrites() async {
    final keys = _pendingProtectedPrefWrites.keys.toList(growable: false);
    await Future.wait(keys.map(_flushProtectedPrefWrite));
  }

  Future<void> _flushProtectedPrefWrite(String key) {
    final pending = _pendingProtectedPrefWrites[key];
    if (pending == null) return Future.value();
    pending.timer?.cancel();
    pending.timer = null;
    final generation = pending.generation;
    final value = pending.value;
    final previous = pending.writeChain;
    final next = previous.catchError((_) {}).then((_) async {
      try {
        await _writeProtectedPref(key, value);
      } catch (e, stackTrace) {
        AppLogService.instance.error(
          'Failed to flush buffered write',
          error: e,
          stackTrace: stackTrace,
          details: 'key=$key',
        );
        rethrow;
      }
    });
    pending.writeChain = next.whenComplete(() {
      final current = _pendingProtectedPrefWrites[key];
      if (!identical(current, pending)) return;
      if (current!.generation == generation && current.timer == null) {
        _pendingProtectedPrefWrites.remove(key);
      }
    });
    return pending.writeChain;
  }
}

/// 带生成计数的延迟写入请求，用于防抖机制。
/// generation 避免竞争条件：如果某 key 在防抖期内被更新多次，
/// 前序 of flush 执行完毕后检测 generation 已变，则不自销毁。
class _PendingProtectedPrefWrite {
  String value;
  Timer? timer;
  Future<void> writeChain = Future<void>.value();
  int generation = 0;

  _PendingProtectedPrefWrite(this.value);
}
