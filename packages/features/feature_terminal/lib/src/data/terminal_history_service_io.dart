// IO 平台的 Terminal 原始输出历史实现。
//
// 输出按加密块写入独立文件，按 session 串行排队并限制读取尾部大小；
// 这样既不会让单次输出阻塞 UI，也不会把明文终端内容长期留在磁盘。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/terminal_ports.dart';

/// IO 平台的加密终端输出历史服务。
class TerminalHistoryService {
  /// 默认输出历史加载上限。
  static const int defaultLoadBytes = 2 * 1024 * 1024;
  static const int _encryptedChunkChars = 32 * 1024;
  static const int _maxBufferedWriteChars = 64 * 1024;
  static const Duration _writeFlushDelay = Duration(milliseconds: 220);

  /// 创建输出历史服务；安全能力和日志能力均由 App 注入。
  TerminalHistoryService({
    required this._dataProtection,
    required this._logger,
    this.historyDirectoryProvider,
  });

  final Map<String, Future<void>> _writeQueues = {};
  final Map<String, _PendingHistoryWrite> _pendingWrites = {};
  final TerminalHistoryOutputProtector _dataProtection;
  final TerminalLoggerPort _logger;

  /// 可注入的目录来源；测试使用临时目录，生产默认使用应用支持目录。
  final Future<Directory> Function()? historyDirectoryProvider;
  Future<Directory>? _historyDirectory;
  bool _disposed = false;

  /// 追加输出并在短时间窗口内合并小块写入。
  Future<void> append(String sessionId, String data) {
    if (_disposed || data.isEmpty) return Future.value();

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

  /// 读取指定 session 的尾部输出并解密完整块。
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
    final completeLines = text.startsWith(_dataProtection.encryptedPrefix)
        ? lines
        : lines.skip(1);
    final buffer = StringBuffer();
    for (final line in completeLines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || !_dataProtection.isEncrypted(trimmed)) continue;
      try {
        buffer.write(await _dataProtection.decryptString(trimmed));
      } catch (error, stackTrace) {
        _logger.warning(
          'Failed to decrypt terminal history chunk',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    return buffer.toString();
  }

  Future<List<int>> _readTailBytes(File file, int maxBytes) async {
    final length = await file.length();
    final readLength = length > maxBytes ? maxBytes : length;
    if (readLength <= 0) return const <int>[];

    // openRead 自己管理底层句柄，避免 Windows 上 read/close 竞态；流的
    // 起止范围仍限制在 maxBytes 内，不会为了读取尾部加载整个历史文件。
    final bytes = <int>[];
    await for (final chunk in file.openRead(length - readLength, length)) {
      bytes.addAll(chunk);
    }
    return bytes;
  }

  /// 返回指定 session 的历史文件句柄。
  Future<Object?> historyFile(String sessionId) async =>
      _historyFile(sessionId);

  /// 刷新所有待写缓冲和串行队列。
  Future<void> flush() async {
    for (final sessionId in _pendingWrites.keys.toList()) {
      _flushPendingWrite(sessionId);
    }
    await Future.wait(_writeQueues.values);
  }

  /// 停止新写入并排空队列；重复调用安全。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await flush();
  }

  Future<void> _appendNow(String sessionId, String data) async {
    try {
      final file = await _historyFile(sessionId);
      await _migratePlainHistoryIfNeeded(file);
      await _writeEncryptedChunks(file, data, mode: FileMode.append);
    } catch (error, stackTrace) {
      _logger.error(
        'Failed to append terminal history',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<File> _historyFile(String sessionId) async {
    final dir = await _getHistoryDirectory();
    return File(p.join(dir.path, '${_safeFileName(sessionId)}.log'));
  }

  Future<Directory> _getHistoryDirectory() {
    return _historyDirectory ??=
        historyDirectoryProvider?.call() ?? _createHistoryDirectory();
  }

  Future<Directory> _createHistoryDirectory() async {
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(supportDir.path, 'terminal_history'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _safeFileName(String value) {
    final sanitized = value.replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '_');
    return sanitized.isEmpty ? 'session' : sanitized;
  }

  bool _looksEncryptedHistory(String text) {
    return text.contains(_dataProtection.encryptedPrefix);
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
      if (sample.startsWith(_dataProtection.encryptedPrefix)) return;
    } finally {
      await raf.close();
    }

    try {
      final plaintext = await file.readAsString();
      await _writeEncryptedChunks(file, plaintext, mode: FileMode.write);
      _logger.info('Migrated plain-text terminal history to encrypted format');
    } catch (error, stackTrace) {
      _logger.error(
        'Failed to migrate plain-text terminal history',
        error: error,
        stackTrace: stackTrace,
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
        sink.writeln(await _dataProtection.encryptString(chunk));
        offset = end;
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
  }
}

final class _PendingHistoryWrite {
  final StringBuffer buffer = StringBuffer();
  final Completer<void> completer = Completer<void>();
  Timer? timer;
}
