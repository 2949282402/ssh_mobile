part of 'app_log_service.dart';

/// AppLogService 的磁盘输出适配层。
///
/// 磁盘写入使用串行队列和固定数量的轮转文件；写入或轮转失败会被
/// 吞掉，避免日志系统在异常路径中递归产生日志或阻塞业务操作。
extension AppLogServiceDiskSink on AppLogService {
  Future<void> _writeToDisk(String logLine) async {
    if (kReleaseMode && !writeDiskLogsInRelease) return;
    _logWriteQueue.add(logLine);
    if (_isWriting) return;
    _isWriting = true;

    while (_logWriteQueue.isNotEmpty) {
      final line = _logWriteQueue.removeAt(0);
      try {
        if (_logFile == null) {
          final supportDir = await getApplicationSupportDirectory();
          _logFile = File(p.join(supportDir.path, AppLogService._logFileName));
        }

        // 先检查当前文件大小，再执行与旧实现一致的轮转策略。
        if (await _logFile!.exists()) {
          final length = await _logFile!.length();
          if (length > logSizeLimit) {
            await _rotateLogs();
          }
        }

        await _logFile!.writeAsString(
          '$line\n',
          mode: FileMode.append,
          flush: true,
        );
      } catch (_) {
        // 忽略日志文件写入错误，避免产生递归日志或阻塞业务路径。
      }
    }
    _isWriting = false;
    final completer = _writeCompleter;
    if (completer != null) {
      _writeCompleter = null;
      completer.complete();
    }
  }

  Future<void> _rotateLogs() async {
    try {
      final supportDir = await getApplicationSupportDirectory();
      final path = supportDir.path;
      final oldestFile = File(
        p.join(
          path,
          '${AppLogService._logFileName}.${AppLogService._logRotationCount}',
        ),
      );
      if (await oldestFile.exists()) await oldestFile.delete();

      for (
        var index = AppLogService._logRotationCount - 1;
        index >= 1;
        index--
      ) {
        final source = File(
          p.join(path, '${AppLogService._logFileName}.$index'),
        );
        final target = File(
          p.join(path, '${AppLogService._logFileName}.${index + 1}'),
        );
        if (await source.exists()) await source.rename(target.path);
      }

      final current = File(p.join(path, AppLogService._logFileName));
      if (await current.exists()) {
        await current.rename(p.join(path, '${AppLogService._logFileName}.1'));
      }
    } catch (_) {
      // 忽略轮转错误，保留当前写入流程的容错行为。
    }
  }

  /// 对日志正文进行统一脱敏。
  String _redact(String value) => _redactor.sanitizeText(value);

  /// 从错误堆栈或当前调用堆栈提取可读来源位置。
  String? _sourceLocation(StackTrace? errorStackTrace) {
    return _sourceFromStack(errorStackTrace) ??
        _sourceFromStack(StackTrace.current);
  }

  String? _sourceFromStack(StackTrace? stackTrace) {
    if (stackTrace == null) return null;
    final lines = stackTrace.toString().split('\n');
    for (final line in lines) {
      if (line.contains('app_log_service.dart')) continue;
      final packageMatch = RegExp(
        r'\((package:ssh_mobile/[^:]+\.dart):(\d+):(\d+)\)',
      ).firstMatch(line);
      if (packageMatch != null) {
        return '${packageMatch.group(1)}:${packageMatch.group(2)}';
      }
      final fileMatch = RegExp(
        r'\((file:///.*?/lib/[^:]+\.dart):(\d+):(\d+)\)',
      ).firstMatch(line.replaceAll('\\', '/'));
      if (fileMatch != null) {
        return '${fileMatch.group(1)}:${fileMatch.group(2)}';
      }
    }
    return null;
  }
}
