part of 'sftp_service_io.dart';

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
  static const ToolSecretPolicy _secretPolicy = ToolSecretPolicy();

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static String _getConnectionHash(String connectionId) => _hash(connectionId);

  static String _getPathHash(String connectionId, String path) =>
      _hash('$connectionId:$path');

  static bool isCacheablePath(String path) =>
      _secretPolicy.suspiciousPathReason(path) == null;

  static Future<File?> _findCachedFile(String connectionId, String path) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final connectionHash = _getConnectionHash(connectionId);
      final pathHash = _getPathHash(connectionId, path);
      final prefix = 'sftp_cache_${connectionHash}_${pathHash}_';
      final legacyPrefix = 'sftp_cache_${pathHash}_';
      final list = tempDir.listSync();
      for (final entity in list) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.startsWith(prefix) || name.startsWith(legacyPrefix)) {
          return entity;
        }
      }
    } catch (_) {
      // ignore
    }
    return null;
  }

  static Future<Uint8List?> get(
      String connectionId, String path, int? size, DateTime? modifiedAt) async {
    if (!isCacheablePath(path)) {
      await invalidate(connectionId, path);
      return null;
    }
    try {
      final cachedFile = await _findCachedFile(connectionId, path);
      if (cachedFile != null) {
        final filename = p.basename(cachedFile.path);
        final parts = filename.split('_');
        if (parts.length >= 6) {
          final cachedSize = int.tryParse(parts[4]);
          final cachedTime = int.tryParse(parts[5]);
          if (cachedSize == size &&
              cachedTime == (modifiedAt?.millisecondsSinceEpoch ?? 0)) {
            final encryptedBytes = await cachedFile.readAsBytes();
            if (!DataProtectionService.instance
                .isEncryptedBytes(encryptedBytes)) {
              await cachedFile.delete();
              return null;
            }
            try {
              final bytes = await DataProtectionService.instance
                  .decryptBytes(encryptedBytes);
              AppLogService.instance.info('SFTP preview Cache hit',
                  details: 'path=$path size=${bytes.length}');
              return bytes;
            } catch (_) {
              await cachedFile.delete();
              return null;
            }
          }
        } else if (parts.length >= 5) {
          final cachedSize = int.tryParse(parts[3]);
          final cachedTime = int.tryParse(parts[4]);
          if (cachedSize == size &&
              cachedTime == (modifiedAt?.millisecondsSinceEpoch ?? 0)) {
            await cachedFile.delete();
            return null;
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
    if (!isCacheablePath(path)) {
      await invalidate(connectionId, path);
      AppLogService.instance.info(
        'SFTP preview Cache skipped for sensitive path',
        details: 'path=$path',
      );
      return;
    }
    try {
      final stale = await _findCachedFile(connectionId, path);
      if (stale != null) {
        await stale.delete();
      }

      final tempDir = await getTemporaryDirectory();
      final connectionHash = _getConnectionHash(connectionId);
      final pathHash = _getPathHash(connectionId, path);
      final sizeStr = (size ?? 0).toString();
      final timeStr = (modifiedAt?.millisecondsSinceEpoch ?? 0).toString();
      final file = File(p.join(tempDir.path,
          'sftp_cache_${connectionHash}_${pathHash}_${sizeStr}_$timeStr'));
      final encryptedBytes =
          await DataProtectionService.instance.encryptBytes(bytes);
      await file.writeAsBytes(encryptedBytes);
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
    } catch (_) {
      // ignore
    }
  }

  static Future<void> clearConnection(String connectionId) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final connectionPrefix =
          'sftp_cache_${_getConnectionHash(connectionId)}_';
      for (final entity in tempDir.listSync()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.startsWith(connectionPrefix) ||
            _isLegacyUnscopedCacheName(name)) {
          await entity.delete();
        }
      }
      AppLogService.instance.info(
        'SFTP preview Cache cleared for connection',
        details: 'connectionId=$connectionId',
      );
    } catch (_) {
      // ignore
    }
  }

  static Future<void> clearAll() async {
    try {
      final tempDir = await getTemporaryDirectory();
      for (final entity in tempDir.listSync()) {
        if (entity is File &&
            p.basename(entity.path).startsWith('sftp_cache_')) {
          await entity.delete();
        }
      }
      AppLogService.instance.info('SFTP preview Cache cleared');
    } catch (_) {
      // ignore
    }
  }

  static bool _isLegacyUnscopedCacheName(String name) {
    if (!name.startsWith('sftp_cache_')) return false;
    final parts = name.split('_');
    return parts.length == 5;
  }
}
