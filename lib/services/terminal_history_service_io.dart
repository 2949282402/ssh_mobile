import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'data_protection_service.dart';

class TerminalHistoryService {
  static const int defaultLoadBytes = 2 * 1024 * 1024;
  static const int _encryptedChunkChars = 32 * 1024;

  final Map<String, Future<void>> _writeQueues = {};
  final DataProtectionService _dataProtection = DataProtectionService.instance;
  Future<Directory>? _historyDirectory;

  Future<void> append(String sessionId, String data) {
    if (data.isEmpty) return Future.value();

    final previous = _writeQueues[sessionId] ?? Future<void>.value();
    final next =
        previous.catchError((_) {}).then((_) => _appendNow(sessionId, data));

    late final Future<void> queued;
    queued = next.whenComplete(() {
      if (identical(_writeQueues[sessionId], queued)) {
        _writeQueues.remove(sessionId);
      }
    });

    _writeQueues[sessionId] = queued;
    return queued;
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
      } catch (_) {
        // Ignore incomplete or damaged tail chunks.
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
    await Future.wait(_writeQueues.values);
  }

  Future<void> _appendNow(String sessionId, String data) async {
    final file = await _historyFile(sessionId);
    await _migratePlainHistoryIfNeeded(file);
    await _writeEncryptedChunks(file, data, mode: FileMode.append);
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
      final sample =
          utf8.decode(await raf.read(sampleLength), allowMalformed: true);
      if (sample.startsWith(DataProtectionService.encryptedPrefix)) return;
    } finally {
      await raf.close();
    }

    final plaintext = await file.readAsString();
    await _writeEncryptedChunks(file, plaintext, mode: FileMode.write);
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
