part of '../sftp_service.dart';

class SftpDirectoryCacheEntry {
  final List<SftpEntry> entries;
  final DateTime cachedAt;

  SftpDirectoryCacheEntry(this.entries) : cachedAt = DateTime.now();

  bool get isExpired {
    return DateTime.now().difference(cachedAt) > const Duration(seconds: 30);
  }
}

class SftpDirectoryCache {
  final Map<String, SftpDirectoryCacheEntry> _cache = {};

  List<SftpEntry>? get(String connectionId, String path) {
    final key = '$connectionId:$path';
    final entry = _cache[key];
    if (entry == null) return null;
    if (entry.isExpired) {
      _cache.remove(key);
      return null;
    }
    return entry.entries;
  }

  void set(String connectionId, String path, List<SftpEntry> entries) {
    final key = '$connectionId:$path';
    _cache[key] = SftpDirectoryCacheEntry(entries);
  }

  void invalidate(String connectionId, [String? path]) {
    if (path != null) {
      _cache.remove('$connectionId:$path');
    } else {
      _cache.removeWhere((key, _) => key.startsWith('$connectionId:'));
    }
  }

  void clear() {
    _cache.clear();
  }
}

class SftpFileCache {
  const SftpFileCache._();

  static String _getPathHash(String connectionId, String path) {
    final key = '$connectionId:$path';
    return sha256.convert(utf8.encode(key)).toString();
  }

  static Future<File?> _findCachedFile(String connectionId, String path) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final hash = _getPathHash(connectionId, path);
      final prefix = 'sftp_cache_${hash}_';
      final list = tempDir.listSync();
      for (final entity in list) {
        if (entity is File && p.basename(entity.path).startsWith(prefix)) {
          return entity;
        }
      }
    } catch (e) {
      // ignore
    }
    return null;
  }

  static Future<Uint8List?> get(
      String connectionId, String path, int? size, DateTime? modifiedAt) async {
    try {
      final cachedFile = await _findCachedFile(connectionId, path);
      if (cachedFile != null) {
        final filename = p.basename(cachedFile.path);
        final parts = filename.split('_');
        if (parts.length >= 5) {
          final cachedSize = int.tryParse(parts[3]);
          final cachedTime = int.tryParse(parts[4]);
          if (cachedSize == size &&
              cachedTime == (modifiedAt?.millisecondsSinceEpoch ?? 0)) {
            final bytes = await cachedFile.readAsBytes();
            AppLogService.instance.info('SFTP preview Cache hit',
                details: 'path=$path size=${bytes.length}');
            return bytes;
          }
        }
        await cachedFile.delete();
      }
    } catch (e) {
      AppLogService.instance.warning('SFTP Cache read failed: $e');
    }
    return null;
  }

  static Future<void> put(String connectionId, String path, int? size,
      DateTime? modifiedAt, Uint8List bytes) async {
    try {
      final stale = await _findCachedFile(connectionId, path);
      if (stale != null) {
        await stale.delete();
      }

      final tempDir = await getTemporaryDirectory();
      final hash = _getPathHash(connectionId, path);
      final sizeStr = (size ?? 0).toString();
      final timeStr = (modifiedAt?.millisecondsSinceEpoch ?? 0).toString();
      final file =
          File(p.join(tempDir.path, 'sftp_cache_${hash}_${sizeStr}_$timeStr'));
      await file.writeAsBytes(bytes);
      AppLogService.instance.info('SFTP preview Cache written',
          details: 'path=$path size=${bytes.length}');
    } catch (e) {
      AppLogService.instance.warning('SFTP Cache write failed: $e');
    }
  }

  static Future<void> invalidate(String connectionId, String path) async {
    try {
      final cachedFile = await _findCachedFile(connectionId, path);
      if (cachedFile != null) {
        await cachedFile.delete();
        AppLogService.instance
            .info('SFTP preview Cache invalidated', details: 'path=$path');
      }
    } catch (e) {
      // ignore
    }
  }
}
