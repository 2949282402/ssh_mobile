import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/services/data_protection_service.dart';
import 'app_log_service.dart';

class TerminalHistoryService {
  static const int defaultLoadBytes = 2 * 1024 * 1024;
  static const int _encryptedChunkChars = 32 * 1024;
  static const int _maxBufferedWriteChars = 64 * 1024;
  static const Duration _writeFlushDelay = Duration(milliseconds: 220);

  final Map<String, Future<void>> _writeQueues = {};
  final Map<String, _PendingHistoryWrite> _pendingWrites = {};
  final DataProtectionService _dataProtection = DataProtectionService.instance;
  Future<Directory>? _historyDirectory;

  Future<void> append(String sessionId, String data) {
    if (data.isEmpty) return Future.value();

    final pending = _pendingWrites.putIfAbsent(
      sessionId,
      _PendingHistoryWrite.new,
    );
    pending.buffer.write(data);
    pending.timer?.cancel();

    if (pending.buffer.length >= _maxBufferedWriteChars) {
      _flushPendingWrite(sessionId);
    } else {
      pending.timer = Timer(
        _writeFlushDelay,
        () => _flushPendingWrite(sessionId),
      );
    }

    return pending.completer.future;
  }

  void _flushPendingWrite(String sessionId) {
    final pending = _pendingWrites.remove(sessionId);
    if (pending == null) return;
    pending.timer?.cancel();
    final data = pending.buffer.toString();
    if (data.isEmpty) {
      if (!pending.completer.isCompleted) pending.completer.complete();
      return;
    }

    final previous = _writeQueues[sessionId] ?? Future<void>.value();
    final next = previous
        .catchError((_) {})
        .then((_) => _appendNow(sessionId, data));

    late final Future<void> queued;
    queued = next.whenComplete(() {
      if (identical(_writeQueues[sessionId], queued)) {
        _writeQueues.remove(sessionId);
      }
    });

    _writeQueues[sessionId] = queued;
    queued.then(
      (_) {
        if (!pending.completer.isCompleted) pending.completer.complete();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!pending.completer.isCompleted) {
          pending.completer.completeError(error, stackTrace);
        }
      },
    );
  }

  Future<String> readTail(
    String sessionId, {
    int maxBytes = defaultLoadBytes,
  }) async {
    final file = await _historyFile(sessionId);
    if (!await file.exists()) return '';

    final bytes = await _readTailBytes(file, maxBytes);
    if (bytes.isEmpty) return '';
    final text = utf8.decode(bytes, allowMalformed: true);
    if (!_looksEncryptedHistory(text)) return text;

    final lines = text.split('\n');
    final completeLines = text.startsWith(DataProtectionService.encryptedPrefix)
        ? lines
        : lines.skip(1);
    final buffer = StringBuffer();
    for (final line in completeLines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (!_dataProtection.isEncrypted(trimmed)) continue;
      try {
        buffer.write(await _dataProtection.decryptString(trimmed));
      } catch (e, stackTrace) {
        AppLogService.instance.add(
          'warning',
          'Failed to decrypt terminal history chunk: $e',
          stackTrace: stackTrace,
        );
      }
    }
    return buffer.toString();
  }

  Future<List<int>> _readTailBytes(File file, int maxBytes) async {
    final raf = await file.open(mode: FileMode.read);
    try {
      final length = await raf.length();
      final readLength = length > maxBytes ? maxBytes : length;
      await raf.setPosition(length - readLength);
      return raf.read(readLength);
    } finally {
      await raf.close();
    }
  }

  Future<File> historyFile(String sessionId) => _historyFile(sessionId);

  Future<void> flush() async {
    for (final sessionId in _pendingWrites.keys.toList()) {
      _flushPendingWrite(sessionId);
    }
    await Future.wait(_writeQueues.values);
  }

  Future<void> _appendNow(String sessionId, String data) async {
    try {
      final file = await _historyFile(sessionId);
      await _migratePlainHistoryIfNeeded(file);
      await _writeEncryptedChunks(file, data, mode: FileMode.append);
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Failed to append terminal history',
        error: e,
        stackTrace: stackTrace,
        details: 'sessionId=$sessionId',
      );
      rethrow;
    }
  }

  Future<File> _historyFile(String sessionId) async {
    final dir = await _getHistoryDirectory();
    return File(p.join(dir.path, '${_safeFileName(sessionId)}.log'));
  }

  Future<Directory> _getHistoryDirectory() {
    return _historyDirectory ??= _createHistoryDirectory();
  }

  Future<Directory> _createHistoryDirectory() async {
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(supportDir.path, 'terminal_history'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String _safeFileName(String value) {
    final sanitized = value.replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '_');
    return sanitized.isEmpty ? 'session' : sanitized;
  }

  bool _looksEncryptedHistory(String text) {
    return text.contains(DataProtectionService.encryptedPrefix);
  }

  Future<void> _migratePlainHistoryIfNeeded(File file) async {
    if (!await file.exists()) return;
    final length = await file.length();
    if (length == 0) return;

    final raf = await file.open(mode: FileMode.read);
    try {
      final sampleLength = length > 128 ? 128 : length;
      final sample = utf8.decode(
        await raf.read(sampleLength),
        allowMalformed: true,
      );
      if (sample.startsWith(DataProtectionService.encryptedPrefix)) return;
    } finally {
      await raf.close();
    }

    try {
      final plaintext = await file.readAsString();
      await _writeEncryptedChunks(file, plaintext, mode: FileMode.write);
      AppLogService.instance.info(
        'Migrated plain-text terminal history to encrypted format',
        details: 'path=${file.path}',
      );
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Failed to migrate plain-text terminal history',
        error: e,
        stackTrace: stackTrace,
        details: 'path=${file.path}',
      );
      rethrow;
    }
  }

  Future<void> _writeEncryptedChunks(
    File file,
    String plaintext, {
    required FileMode mode,
  }) async {
    if (plaintext.isEmpty) return;
    final sink = file.openWrite(mode: mode);
    try {
      for (var offset = 0; offset < plaintext.length;) {
        final end = (offset + _encryptedChunkChars).clamp(0, plaintext.length);
        final chunk = plaintext.substring(offset, end);
        final encrypted = await _dataProtection.encryptString(chunk);
        sink.writeln(encrypted);
        offset = end;
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
  }
}

class _PendingHistoryWrite {
  final StringBuffer buffer = StringBuffer();
  final Completer<void> completer = Completer<void>();
  Timer? timer;
}
