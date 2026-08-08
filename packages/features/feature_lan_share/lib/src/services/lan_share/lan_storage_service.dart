import 'dart:async';
import 'dart:io';
import 'package:disk_space_2/disk_space_2.dart';
import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import '../../domain/lan_share_ports.dart';
import 'lan_share_models.dart';

/// Service responsible for sandbox storage management, disk space pre-flight checks,
/// manual exports to system photo gallery/downloads, and 7-day TTL auto-cleanup (GC).
class LanStorageService {
  static const String _cacheFolderName = 'lan_share_cache';
  final Future<Directory> Function()? sandboxDirectoryProvider;
  final Future<double?> Function()? freeDiskSpaceMbProvider;
  final LanShareLoggerPort? logger;

  LanStorageService({
    this.sandboxDirectoryProvider,
    this.freeDiskSpaceMbProvider,
    this.logger,
  });

  /// Get or create internal app sandbox cache directory
  Future<Directory> getSandboxDirectory() async {
    final provided = sandboxDirectoryProvider;
    if (provided != null) {
      final directory = await provided();
      if (!await directory.exists()) await directory.create(recursive: true);
      return directory;
    }
    final docsDir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory(p.join(docsDir.path, _cacheFolderName));
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir;
  }

  /// Get target file path inside sandbox for an incoming payload
  Future<File> getSandboxTargetFile(String fileName) async {
    final dir = await getSandboxDirectory();
    return _reserveUniqueFile(dir, fileName);
  }

  Future<File> _reserveUniqueFile(Directory directory, String fileName) async {
    var sanitized = p
        .basename(fileName)
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
    if (sanitized.isEmpty || sanitized == '.' || sanitized == '..') {
      sanitized = 'file.bin';
    }
    if (Platform.isWindows) {
      final stem = p.basenameWithoutExtension(sanitized).toUpperCase();
      if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$').hasMatch(stem)) {
        sanitized = '_$sanitized';
      }
    }

    final nameWithoutExt = p.basenameWithoutExtension(sanitized);
    final ext = p.extension(sanitized);
    FileSystemException? lastError;
    for (var counter = 0; counter < 10000; counter++) {
      final suffix = counter == 0 ? '' : ' ($counter)';
      final target = File(p.join(directory.path, '$nameWithoutExt$suffix$ext'));
      try {
        return await target.create(exclusive: true);
      } on FileSystemException catch (error) {
        lastError = error;
        if (!await target.exists()) rethrow;
      }
    }
    throw lastError ??
        FileSystemException('Unable to reserve a unique LAN file name.');
  }

  /// Deletes only a file that is contained by the LAN cache directory.
  /// Sender-provided paths and exported copies are never eligible.
  Future<bool> deleteSandboxFile(String localPath) async {
    final cacheDir = await getSandboxDirectory();
    var rootPath = p.normalize(p.absolute(cacheDir.path));
    var candidatePath = p.normalize(p.absolute(localPath));
    if (Platform.isWindows) {
      rootPath = rootPath.toLowerCase();
      candidatePath = candidatePath.toLowerCase();
    }
    if (!p.isWithin(rootPath, candidatePath)) return false;

    final type = await FileSystemEntity.type(localPath, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.link) {
      return false;
    }
    await File(localPath).delete();
    return true;
  }

  /// Disk space pre-flight check before accepting large file downloads
  Future<bool> hasSufficientSpace(int requiredBytes) async {
    try {
      double freeMb = 0.0;
      final provided = freeDiskSpaceMbProvider;
      if (provided != null) {
        freeMb = await provided() ?? 0.0;
      } else if (Platform.isMacOS) {
        // macOS fallback via df -k
        final result = await Process.run('df', ['-k', '/']);
        if (result.exitCode == 0) {
          final lines = (result.stdout as String).split('\n');
          if (lines.length > 1) {
            final parts = lines[1].split(RegExp(r'\s+'));
            if (parts.length >= 4) {
              final availableKb = double.tryParse(parts[3]) ?? 0.0;
              freeMb = availableKb / 1024.0;
            }
          }
        }
      } else {
        final free = await DiskSpace.getFreeDiskSpace;
        if (free != null) {
          freeMb = free;
        }
      }

      final requiredMb = requiredBytes / (1024.0 * 1024.0);
      // Keep 100MB safety buffer
      return (freeMb - requiredMb) > 100.0;
    } catch (e) {
      logger?.warning('LAN storage space check failed', details: '$e');
      return false;
    }
  }

  /// Export file from sandbox to system photo gallery or public Downloads
  Future<bool> exportToPublic(
    String localPath,
    LanPayloadType payloadType,
  ) async {
    final file = File(localPath);
    if (!await file.exists()) return false;

    try {
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        final bytes = await file.readAsBytes();
        final outputPath = await FilePicker.saveFile(
          dialogTitle: 'Save File',
          fileName: p.basename(localPath),
          bytes: bytes,
        );
        return outputPath != null;
      }

      if (payloadType == LanPayloadType.image) {
        final hasAccess = await Gal.hasAccess();
        if (!hasAccess) {
          final granted = await Gal.requestAccess();
          if (!granted) return false;
        }
        await Gal.putImage(localPath);
        return true;
      } else if (payloadType == LanPayloadType.video) {
        final hasAccess = await Gal.hasAccess();
        if (!hasAccess) {
          final granted = await Gal.requestAccess();
          if (!granted) return false;
        }
        await Gal.putVideo(localPath);
        return true;
      } else {
        // Copy to system Downloads folder (Mobile)
        Directory? downloadsDir = await getExternalStorageDirectory();
        downloadsDir ??= await getApplicationDocumentsDirectory();

        final target = await _reserveUniqueFile(
          downloadsDir,
          p.basename(localPath),
        );
        var copied = false;
        try {
          await file.openRead().pipe(target.openWrite());
          copied = true;
        } finally {
          if (!copied && await target.exists()) {
            await target.delete();
          }
        }
        return true;
      }
    } catch (e) {
      debugPrint('[LanStorageService] Export error: $e');
      return false;
    }
  }

  /// Perform 7-day TTL Garbage Collection (delete files older than 7 days)
  Future<int> perform7DayGarbageCollection({
    Duration ttl = const Duration(days: 7),
  }) async {
    int deletedCount = 0;
    try {
      final cacheDir = await getSandboxDirectory();
      if (!await cacheDir.exists()) return 0;

      final now = DateTime.now();
      final cutoff = now.subtract(ttl);

      await for (final entity in cacheDir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          try {
            final stat = await entity.stat();
            if (stat.modified.isBefore(cutoff)) {
              await entity.delete();
              deletedCount++;
              debugPrint(
                '[LanStorageService] GC deleted expired file: ${entity.path}',
              );
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[LanStorageService] Garbage collection error: $e');
    }
    return deletedCount;
  }
}
