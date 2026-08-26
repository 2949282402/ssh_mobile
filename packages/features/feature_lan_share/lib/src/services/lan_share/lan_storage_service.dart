import 'dart:async';
import 'dart:io';
import 'package:disk_space_2/disk_space_2.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import '../../domain/lan_share_ports.dart';
import 'lan_share_models.dart';

/// Port for querying available storage space on a given directory.
abstract interface class LanDiskSpacePort {
  Future<int?> getFreeBytes(Directory targetDirectory);
}

/// Service responsible for sandbox storage management, disk space pre-flight checks,
/// manual exports to system photo gallery/downloads, and 7-day TTL auto-cleanup (GC).
class LanStorageService {
  static const String _cacheFolderName = 'lan_share_cache';
  static const int safetyBufferBytes =
      100 * 1024 * 1024; // 100 MiB safety buffer

  final Future<Directory> Function()? sandboxDirectoryProvider;
  final Future<int?> Function()? freeDiskSpaceBytesProvider;
  final Future<double?> Function()? freeDiskSpaceMbProvider;
  final LanDiskSpacePort? diskSpacePort;
  final Future<String?> Function()? desktopExportDirectoryProvider;
  final Future<File> Function(File source, File target)? renameOverride;
  final LanShareLoggerPort? logger;

  LanStorageService({
    this.sandboxDirectoryProvider,
    this.freeDiskSpaceBytesProvider,
    this.freeDiskSpaceMbProvider,
    this.diskSpacePort,
    this.desktopExportDirectoryProvider,
    this.renameOverride,
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

  /// Adopts an incoming file downloaded by the neutral App runtime inbox into
  /// the LAN sandbox cache. Moves or copies the file and deletes the source.
  Future<File> adoptIncomingNetworkFile({
    required String nativePath,
    required String fileName,
  }) async {
    final sourceFile = File(nativePath);
    if (!await sourceFile.exists()) {
      throw FileSystemException(
        'Native incoming file does not exist',
        nativePath,
      );
    }
    final sourceLength = await sourceFile.length();
    final cacheDir = await getSandboxDirectory();
    final targetFile = await _reserveUniqueFile(cacheDir, fileName);

    var adopted = false;
    try {
      // Try rename/move first
      try {
        await targetFile.delete(); // clear the 0-byte reservation placeholder
        final moved = renameOverride != null
            ? await renameOverride!(sourceFile, targetFile)
            : await sourceFile.rename(targetFile.path);
        if (await moved.length() == sourceLength) {
          adopted = true;
          return moved;
        }
      } on FileSystemException {
        // Cross-filesystem or rename not supported, fallback to stream copy
      }

      // Re-create target file if deleted during rename attempt
      if (!await targetFile.exists()) {
        await targetFile.create(exclusive: true);
      }
      final sink = targetFile.openWrite();
      await sourceFile.openRead().pipe(sink);
      await sink.flush();
      await sink.close();

      final adoptedLength = await targetFile.length();
      if (adoptedLength != sourceLength) {
        throw FileSystemException(
          'Adopted file size mismatch (expected $sourceLength, got $adoptedLength)',
          targetFile.path,
        );
      }

      try {
        await sourceFile.delete();
      } catch (error, stackTrace) {
        logger?.warning(
          'Failed to delete source incoming file after adoption: $nativePath',
          details: '$error\n$stackTrace',
        );
      }

      adopted = true;
      return targetFile;
    } finally {
      if (!adopted && await targetFile.exists()) {
        try {
          await targetFile.delete();
        } catch (_) {}
      }
    }
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

  Future<int?> _queryFreeDiskBytes(Directory directory) async {
    final port = diskSpacePort;
    if (port != null) {
      return await port.getFreeBytes(directory);
    }
    final bytesProvider = freeDiskSpaceBytesProvider;
    if (bytesProvider != null) {
      return await bytesProvider();
    }
    final mbProvider = freeDiskSpaceMbProvider;
    if (mbProvider != null) {
      final mb = await mbProvider();
      return mb != null ? (mb * 1024 * 1024).toInt() : null;
    }
    if (Platform.isMacOS || Platform.isLinux) {
      try {
        final result = await Process.run('df', ['-k', directory.path]);
        if (result.exitCode == 0) {
          final lines = (result.stdout as String).split('\n');
          if (lines.length > 1) {
            final parts = lines[1].split(RegExp(r'\s+'));
            if (parts.length >= 4) {
              final availableKb = int.tryParse(parts[3]);
              if (availableKb != null) {
                return availableKb * 1024;
              }
            }
          }
        }
      } catch (_) {
        return null;
      }
    } else {
      try {
        final freeMb = await DiskSpace.getFreeDiskSpace;
        if (freeMb != null) {
          return (freeMb * 1024 * 1024).toInt();
        }
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Disk space pre-flight check before accepting large file downloads
  Future<bool> hasSufficientSpace(int requiredBytes) async {
    try {
      final dir = await getSandboxDirectory();
      final freeBytes = await _queryFreeDiskBytes(dir);
      if (freeBytes == null) {
        logger?.warning(
          'LAN storage space check failed: unable to determine free disk space',
        );
        return false;
      }
      return (freeBytes - requiredBytes) >= safetyBufferBytes;
    } catch (e, st) {
      logger?.warning('LAN storage space check failed', details: '$e\n$st');
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
        final provided = desktopExportDirectoryProvider;
        final outputDirectory = provided != null
            ? await provided()
            : await FilePicker.getDirectoryPath(
                dialogTitle: 'Select export folder',
              );
        if (outputDirectory == null) return false;
        final directory = Directory(outputDirectory);
        if (!await directory.exists()) return false;
        await _copyToDirectory(file, directory);
        return true;
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

        await _copyToDirectory(file, downloadsDir);
        return true;
      }
    } catch (e) {
      logger?.warning(
        'LAN file export failed',
        details: 'errorType=${e.runtimeType}',
      );
      return false;
    }
  }

  /// 使用有界流式 I/O 将沙箱文件复制到目标目录。
  Future<File> _copyToDirectory(File source, Directory directory) async {
    final target = await _reserveUniqueFile(directory, p.basename(source.path));
    var copied = false;
    try {
      await source.openRead().pipe(target.openWrite());
      copied = true;
      return target;
    } finally {
      if (!copied && await target.exists()) {
        await target.delete();
      }
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
              logger?.info('LAN storage GC removed an expired file');
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      logger?.warning(
        'LAN storage garbage collection failed',
        details: 'errorType=${e.runtimeType}',
      );
    }
    return deletedCount;
  }
}
