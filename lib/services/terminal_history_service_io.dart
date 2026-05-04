import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class TerminalHistoryService {
  static const int defaultLoadBytes = 2 * 1024 * 1024;

  final Map<String, Future<void>> _writeQueues = {};
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

    final raf = await file.open(mode: FileMode.read);
    try {
      final length = await raf.length();
      final readLength = length > maxBytes ? maxBytes : length;
      await raf.setPosition(length - readLength);
      final bytes = await raf.read(readLength);
      return utf8.decode(bytes, allowMalformed: true);
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
    await file.writeAsString(data, mode: FileMode.append, flush: false);
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
}
