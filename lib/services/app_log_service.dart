import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'app_settings.dart';

class AppLogService extends ChangeNotifier {
  static final AppLogService instance = AppLogService._();
  static const int _maxEntries = 1200;
  final ListQueue<AppLogEntry> _entries = ListQueue<AppLogEntry>();
  DebugPrintCallback? _previousDebugPrint;
  bool _installed = false;

  AppLogService._();

  factory AppLogService() => instance;

  List<AppLogEntry> get entries =>
      List.unmodifiable(_entries.toList().reversed);

  void install() {
    if (_installed) return;
    _installed = true;
    _previousDebugPrint ??= debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null && message.isNotEmpty) {
        add('debug', message);
      }
      _previousDebugPrint?.call(message, wrapWidth: wrapWidth);
    };

    final previousFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      add(
        'flutter',
        details.exceptionAsString(),
        stackTrace: details.stack,
        details: details.toStringShort(),
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
  }) {
    _entries.addLast(
      AppLogEntry(
        time: DateTime.now(),
        level: level,
        message: message,
        stackTrace: stackTrace?.toString(),
        details: details,
      ),
    );
    while (_entries.length > _maxEntries) {
      _entries.removeFirst();
    }
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }
}

class AppLogEntry {
  final DateTime time;
  final String level;
  final String message;
  final String? stackTrace;
  final String? details;

  const AppLogEntry({
    required this.time,
    required this.level,
    required this.message,
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
