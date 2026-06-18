import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_settings.dart';
import 'tool_secret_policy.dart';

/// 应用级日志服务（单例）。
///
/// 功能：
/// 1. 全局 debugPrint / FlutterError.onError / PlatformDispatcher.onError 拦截
/// 2. 内存环形日志缓冲区（上限 1200 条）
/// 3. 日志脱敏：自动检测并替换私钥 PEM、Bearer Token、密码字段
/// 4. UI 通知合并：160ms 内多次 add() 合并为一次 notifyListeners()
/// 5. 多级缓存：entries、levelCounts、entriesByLevel 惰性计算+缓存
class AppLogService extends ChangeNotifier {
  static final AppLogService instance = AppLogService._();
  static const int _maxEntries = 1200;
  final ListQueue<AppLogEntry> _entries = ListQueue<AppLogEntry>();
  List<AppLogEntry>? _cachedNewestFirstEntries;
  Map<AppLogLevel, int>? _cachedLevelCounts;
  Map<AppLogLevel, List<AppLogEntry>>? _cachedEntriesByLevel;
  Set<int>? _cachedEntryIds;
  DebugPrintCallback? _previousDebugPrint;
  bool _installed = false;
  bool _notifyScheduled = false;
  Timer? _notifyTimer;
  int _nextEntryId = 1;
  File? _logFile;
  final List<String> _logWriteQueue = [];
  bool _isWriting = false;
  int logSizeLimit = 5 * 1024 * 1024;
  bool writeDiskLogsInRelease = false;
  final ToolSecretPolicy _secretPolicy = const ToolSecretPolicy();

  AppLogService._();

  factory AppLogService() => instance;

  List<AppLogEntry> get entries {
    return _cachedNewestFirstEntries ??= List.unmodifiable(
      _entries.toList().reversed,
    );
  }

  Map<AppLogLevel, int> get levelCounts {
    final cached = _cachedLevelCounts;
    if (cached != null) return cached;
    final counts = {for (final level in AppLogLevel.values) level: 0};
    counts[AppLogLevel.all] = _entries.length;
    for (final entry in _entries) {
      final level = entry.normalizedLevel;
      counts[level] = (counts[level] ?? 0) + 1;
    }
    return _cachedLevelCounts = Map.unmodifiable(counts);
  }

  List<AppLogEntry> entriesForLevel(AppLogLevel level) {
    if (level == AppLogLevel.all) return entries;
    final cached = _cachedEntriesByLevel;
    if (cached != null && cached.containsKey(level)) {
      return cached[level]!;
    }
    final map = Map<AppLogLevel, List<AppLogEntry>>.of(cached ?? const {});
    map[level] = List.unmodifiable(
      entries.where((entry) => entry.normalizedLevel == level),
    );
    _cachedEntriesByLevel = map;
    return map[level]!;
  }

  Set<int> get entryIds {
    return _cachedEntryIds ??= Set.unmodifiable(
      entries.map((entry) => entry.id),
    );
  }

  void install() {
    if (_installed) return;
    _installed = true;
    _previousDebugPrint ??= debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null && message.isNotEmpty) {
        add('debug', message, captureSource: false);
      }
      _previousDebugPrint?.call(message, wrapWidth: wrapWidth);
    };

    final previousFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      // Keep Flutter's full diagnostic tree in the log page. RenderFlex
      // overflows often hide the business widget in the short message, while
      // the full details include the ownership chain and relevant widget.
      add(
        'flutter',
        details.exceptionAsString(),
        stackTrace: details.stack,
        details: details.toString(),
      );
      previousFlutterError?.call(details);
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      add('platform', error.toString(), stackTrace: stack);
      return false;
    };

    add('app', 'Log service started');
  }

  void info(String message, {String? details}) {
    add('info', message, details: details);
  }

  void warning(String message, {String? details}) {
    add('warning', message, details: details);
  }

  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {
    add(
      'error',
      error == null ? message : '$message: $error',
      stackTrace: stackTrace,
      details: details,
    );
  }

  void add(
    String level,
    String message, {
    StackTrace? stackTrace,
    String? details,
    bool captureSource = true,
  }) {
    final safeMessage = _redact(message);
    final safeDetails = details == null ? null : _redact(details);
    final safeStackTrace =
        stackTrace == null ? null : _redact(stackTrace.toString());
    final entry = AppLogEntry(
      id: _nextEntryId++,
      time: DateTime.now(),
      level: level,
      message: safeMessage,
      sourceLocation: captureSource ? _sourceLocation(stackTrace) : null,
      stackTrace: safeStackTrace,
      details: safeDetails,
    );
    _entries.addLast(entry);
    while (_entries.length > _maxEntries) {
      _entries.removeFirst();
    }
    _invalidateCaches();
    _scheduleNotify();

    // Write log to disk asynchronously
    unawaited(_writeToDisk(entry.text));
  }

  void deleteEntriesById(Set<int> ids) {
    if (ids.isEmpty) return;
    _entries.removeWhere((entry) => ids.contains(entry.id));
    _invalidateCaches();
    _scheduleNotify();
  }

  void clear() {
    _entries.clear();
    _invalidateCaches();
    _scheduleNotify();
  }

  void _invalidateCaches() {
    _cachedNewestFirstEntries = null;
    _cachedLevelCounts = null;
    _cachedEntriesByLevel = null;
    _cachedEntryIds = null;
  }

  void _scheduleNotify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    // Logs can be produced while routes/dialogs are being torn down. Deferring
    // and batching the UI notification keeps provider dependents from
    // rebuilding every line during noisy SSH/LLM/server diagnostics.
    _notifyTimer = Timer(const Duration(milliseconds: 160), () {
      _notifyScheduled = false;
      notifyListeners();
    });
  }

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
          _logFile = File(p.join(supportDir.path, 'app.log'));
        }

        // Check size and rotate if needed
        if (await _logFile!.exists()) {
          final length = await _logFile!.length();
          if (length > logSizeLimit) {
            await _rotateLogs();
          }
        }

        await _logFile!
            .writeAsString('$line\n', mode: FileMode.append, flush: true);
      } catch (e) {
        // Ignore log file write errors to prevent infinite error logging loops
      }
    }
    _isWriting = false;
  }

  Future<void> _rotateLogs() async {
    try {
      final supportDir = await getApplicationSupportDirectory();
      final path = supportDir.path;

      final file3 = File(p.join(path, 'app.log.3'));
      final file2 = File(p.join(path, 'app.log.2'));
      final file1 = File(p.join(path, 'app.log.1'));
      final file0 = File(p.join(path, 'app.log'));

      if (await file3.exists()) await file3.delete();
      if (await file2.exists()) await file2.rename(file3.path);
      if (await file1.exists()) await file1.rename(file2.path);
      if (await file0.exists()) await file0.rename(file1.path);
    } catch (e) {
      // Ignore rotation errors
    }
  }

  String _redact(String value) => _secretPolicy.redactText(value);

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

  @override
  void dispose() {
    _notifyTimer?.cancel();
    super.dispose();
  }
}

class AppLogEntry {
  final int id;
  final DateTime time;
  final String level;
  final String message;
  final String? sourceLocation;
  final String? stackTrace;
  final String? details;

  const AppLogEntry({
    required this.id,
    required this.time,
    required this.level,
    required this.message,
    required this.sourceLocation,
    required this.stackTrace,
    required this.details,
  });

  String get text {
    final buffer = StringBuffer()
      ..write(_formatTime(time))
      ..write(' [')
      ..write(level)
      ..write('] ')
      ..write(message);
    if (sourceLocation?.isNotEmpty == true) {
      buffer
        ..write('\nsource: ')
        ..write(sourceLocation);
    }
    if (details?.isNotEmpty == true) {
      buffer
        ..write('\n')
        ..write(details);
    }
    if (stackTrace?.isNotEmpty == true) {
      buffer
        ..write('\n')
        ..write(stackTrace);
    }
    return buffer.toString();
  }

  AppLogLevel get normalizedLevel => AppLogLevel.fromName(level);

  static String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    String three(int value) => value.toString().padLeft(3, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}.'
        '${three(time.millisecond)}';
  }
}

enum AppLogLevel {
  all('all', 'All', '全部'),
  error('error', 'Error', '错误'),
  warning('warning', 'Warning', '警告'),
  info('info', 'Info', '信息'),
  service('service', 'Service', '后台'),
  debug('debug', 'Debug', '调试'),
  flutter('flutter', 'Flutter', 'Flutter'),
  platform('platform', 'Platform', '平台'),
  app('app', 'App', '应用');

  final String name;
  final String englishLabel;
  final String chineseLabel;

  const AppLogLevel(this.name, this.englishLabel, this.chineseLabel);

  String labelFor(AppLanguage language) {
    return language == AppLanguage.en ? englishLabel : chineseLabel;
  }

  static AppLogLevel fromName(String name) {
    final normalized = name.toLowerCase();
    for (final level in AppLogLevel.values) {
      if (level.name == normalized) return level;
    }
    return AppLogLevel.info;
  }
}
