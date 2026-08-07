part of 'app_log_service.dart';

/// 等待 AppLogService 绑定数据库时的日志变更。
sealed class _DatabaseLogMutation {
  /// 创建一条数据库变更。
  const _DatabaseLogMutation();
}

/// 表示新增一条日志。
final class _AddDatabaseLogMutation extends _DatabaseLogMutation {
  /// 创建新增日志变更。
  const _AddDatabaseLogMutation(this.entry);

  /// 尚未分配数据库最终 ID 的内存日志。
  final AppLogEntry entry;
}

/// 表示删除一组日志，并区分数据库 ID 与绑定期间的临时 ID。
final class _DeleteDatabaseLogMutation extends _DatabaseLogMutation {
  /// 创建删除日志变更。
  _DeleteDatabaseLogMutation({
    required Set<int> databaseIds,
    required Set<int> temporaryIds,
  }) : databaseIds = Set.unmodifiable(databaseIds),
       temporaryIds = Set.unmodifiable(temporaryIds);

  /// 已经持久化到数据库的 ID。
  final Set<int> databaseIds;

  /// 绑定期间由内存缓冲区生成的临时 ID。
  final Set<int> temporaryIds;
}

/// 表示清空全部日志。
final class _ClearDatabaseLogMutation extends _DatabaseLogMutation {
  /// 创建清空日志变更。
  const _ClearDatabaseLogMutation();
}

/// 面向日志页面和数据库适配器的不可变日志条目。
final class AppLogEntry {
  /// 创建一条日志条目。
  const AppLogEntry({
    required this.id,
    required this.time,
    required this.level,
    required this.message,
    required this.sourceLocation,
    required this.stackTrace,
    required this.details,
  });

  /// 条目的内存或数据库 ID。
  final int id;

  /// 条目产生时间。
  final DateTime time;

  /// 兼容现有 UI 和数据库的级别名称。
  final String level;

  /// 已脱敏的主要消息。
  final String message;

  /// 调用位置或模块作用域。
  final String? sourceLocation;

  /// 已脱敏的堆栈信息。
  final String? stackTrace;

  /// 已脱敏的补充诊断信息。
  final String? details;

  /// 返回用于磁盘和复制操作的可读文本。
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

  /// 将任意级别名称归一化为 UI 使用的旧枚举值。
  AppLogLevel get normalizedLevel => AppLogLevel.fromName(level);

  static String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    String three(int value) => value.toString().padLeft(3, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}.'
        '${three(time.millisecond)}';
  }
}

/// 现有日志页面使用的展示级别。
enum AppLogLevel {
  /// 全部级别。
  all('all', 'All', '全部'),

  /// 错误级别。
  error('error', 'Error', '错误'),

  /// 警告级别。
  warning('warning', 'Warning', '警告'),

  /// 普通信息级别。
  info('info', 'Info', '信息'),

  /// 后台服务级别。
  service('service', 'Service', '后台'),

  /// 调试输出级别。
  debug('debug', 'Debug', '调试'),

  /// Flutter 框架错误级别。
  flutter('flutter', 'Flutter', 'Flutter'),

  /// 平台未捕获错误级别。
  platform('platform', 'Platform', '平台'),

  /// 应用启动级别。
  app('app', 'App', '应用');

  /// 创建展示级别。
  const AppLogLevel(this.name, this.englishLabel, this.chineseLabel);

  /// 稳定的存储和筛选名称。
  final String name;

  /// 英文展示文本。
  final String englishLabel;

  /// 中文展示文本。
  final String chineseLabel;

  /// 按当前语言返回展示文本。
  String labelFor(AppLanguage language) {
    return language == AppLanguage.en ? englishLabel : chineseLabel;
  }

  /// 从存储或工具参数解析级别，未知值回退到普通信息。
  static AppLogLevel fromName(String name) {
    final normalized = name.toLowerCase();
    for (final level in AppLogLevel.values) {
      if (level.name == normalized) return level;
    }
    return AppLogLevel.info;
  }
}
