import 'package:app_core/app_core.dart';
import 'package:flutter/foundation.dart';

import 'developer_diagnostics_models.dart';

/// Developer Feature 只读观察契约。
///
/// 这些接口描述开发者页面需要的最小数据，不暴露 App Shell、日志数据库或
/// 任意具体 Feature 的实现。适配器由 App Composition Root 创建并负责释放。

/// 日志页面支持的稳定筛选级别。
enum DeveloperLogLevel {
  /// 显示全部日志。
  all,

  /// 错误日志。
  error,

  /// 警告日志。
  warning,

  /// 普通信息日志。
  info,

  /// 后台服务日志。
  service,

  /// 调试输出日志。
  debug,

  /// Flutter 框架错误日志。
  flutter,

  /// 平台未捕获错误日志。
  platform,

  /// 应用启动日志。
  app,
}

/// 将日志级别转换为页面展示文本，避免 UI 散落协议字符串。
extension DeveloperLogLevelPresentation on DeveloperLogLevel {
  /// 返回当前语言下的级别名称。
  String labelFor(AppLanguage language) {
    if (language == AppLanguage.en) {
      return switch (this) {
        DeveloperLogLevel.all => 'All',
        DeveloperLogLevel.error => 'Error',
        DeveloperLogLevel.warning => 'Warning',
        DeveloperLogLevel.info => 'Info',
        DeveloperLogLevel.service => 'Service',
        DeveloperLogLevel.debug => 'Debug',
        DeveloperLogLevel.flutter => 'Flutter',
        DeveloperLogLevel.platform => 'Platform',
        DeveloperLogLevel.app => 'App',
      };
    }
    return switch (this) {
      DeveloperLogLevel.all => '全部',
      DeveloperLogLevel.error => '错误',
      DeveloperLogLevel.warning => '警告',
      DeveloperLogLevel.info => '信息',
      DeveloperLogLevel.service => '后台',
      DeveloperLogLevel.debug => '调试',
      DeveloperLogLevel.flutter => 'Flutter',
      DeveloperLogLevel.platform => '平台',
      DeveloperLogLevel.app => '应用',
    };
  }
}

/// 已脱敏的日志条目快照；日志存储和数据库仍由 App Scope Owner 管理。
final class DeveloperLogEntry {
  /// 创建一条供开发者页面展示的日志快照。
  const DeveloperLogEntry({
    required this.id,
    required this.time,
    required this.level,
    required this.text,
  });

  /// 条目稳定 ID，用于选择和删除。
  final int id;

  /// 日志产生时间。
  final DateTime time;

  /// 日志筛选级别。
  final DeveloperLogLevel level;

  /// 已格式化且脱敏的复制文本。
  final String text;
}

/// Developer Log 页面所需的最小日志能力。
abstract interface class DeveloperLogPort implements Listenable {
  /// 按最新到最旧顺序返回日志快照。
  List<DeveloperLogEntry> get entries;

  /// 返回各级别的条数。
  Map<DeveloperLogLevel, int> get levelCounts;

  /// 返回指定级别的日志快照。
  List<DeveloperLogEntry> entriesForLevel(DeveloperLogLevel level);

  /// 返回当前条目 ID，用于清理失效选择。
  Set<int> get entryIds;

  /// 删除指定条目；实际持久化由 App Scope Owner 决定。
  void deleteEntriesById(Set<int> ids);

  /// 清空日志。
  void clear();
}

/// Developer 页面读取的 App 设置最小契约。
abstract interface class DeveloperSettingsPort implements Listenable {
  /// 当前界面语言。
  AppLanguage get language;

  /// 是否开启开发者模式。
  bool get developerMode;

  /// 是否显示悬浮开发者面板。
  bool get floatingPanelEnabled;
}

/// 操作系统级内存分类快照，不暴露平台 MethodChannel 实现。
final class DeveloperNativeMemorySnapshot {
  /// 创建内存快照；字节数保持原始精度，页面负责格式化。
  const DeveloperNativeMemorySnapshot({
    required this.available,
    required this.javaHeapBytes,
    required this.nativeHeapBytes,
    required this.graphicsBytes,
    required this.codeBytes,
    required this.totalPssBytes,
  });

  /// 当前平台是否提供详细内存分类。
  final bool available;

  /// Java Heap 字节数。
  final int javaHeapBytes;

  /// Native Heap 字节数。
  final int nativeHeapBytes;

  /// Graphics 字节数。
  final int graphicsBytes;

  /// Code 字节数。
  final int codeBytes;

  /// PSS 总字节数。
  final int totalPssBytes;

  /// Java Heap 的 MiB 数。
  double get javaHeapMB => javaHeapBytes / (1024 * 1024);

  /// Native Heap 的 MiB 数。
  double get nativeHeapMB => nativeHeapBytes / (1024 * 1024);

  /// Graphics 的 MiB 数。
  double get graphicsMB => graphicsBytes / (1024 * 1024);

  /// Code 的 MiB 数。
  double get codeMB => codeBytes / (1024 * 1024);

  /// PSS 总量的 MiB 数。
  double get totalPssMB => totalPssBytes / (1024 * 1024);
}

/// 可观察的 App/Feature 活动标识。
enum DeveloperComponentId {
  /// SSH 会话。
  ssh,

  /// RAG 索引。
  rag,

  /// MCP Server。
  mcpServer,

  /// 性能监控。
  performanceMonitor,

  /// 日志缓冲区。
  logBuffer,

  /// Telemetry 数据埋点。
  telemetry,
}

/// 将组件标识转换为稳定的开发者页面标签。
extension DeveloperComponentPresentation on DeveloperComponentId {
  /// 返回英文组件名称，保持原 Developer Panel 文案。
  String get label => switch (this) {
    DeveloperComponentId.ssh => 'SSH',
    DeveloperComponentId.rag => 'RAG',
    DeveloperComponentId.mcpServer => 'MCP Server',
    DeveloperComponentId.performanceMonitor => 'Perf Monitor',
    DeveloperComponentId.logBuffer => 'Log Buffer',
    DeveloperComponentId.telemetry => 'Telemetry',
  };
}

/// 单个模块的短状态快照；不提供控制方法，避免 Developer UI 越权。
final class DeveloperComponentStatus {
  /// 创建模块状态。
  const DeveloperComponentStatus({required this.id, required this.state});

  /// 模块稳定标识。
  final DeveloperComponentId id;

  /// 供页面展示的状态文本。
  final String state;
}

/// Developer Panel 使用的只读 diagnostics contract。
abstract interface class DeveloperDiagnosticsPort implements Listenable {
  /// 返回当前模块活动快照。
  List<DeveloperComponentStatus> get componentStatuses;

  /// 返回当前可观测的模块、连接、数据库和资源快照。
  DeveloperDiagnosticsSnapshot get snapshot;

  /// 读取操作系统级内存分类；不支持的平台返回 null。
  Future<DeveloperNativeMemorySnapshot?> readNativeMemory();

  /// 一键重传本地所有 Telemetry 数据。
  Future<int> replayTelemetry() async => 0;

  /// 显式重试本地 rejected Telemetry 数据；不会影响 pending/synced rows。
  Future<int> retryRejectedTelemetry() async => 0;

  /// 立即触发一次 Telemetry 批次上传。
  Future<void> flushTelemetry() async {}

  /// 刷新远端 Telemetry 上传策略。
  Future<bool> refreshTelemetryPolicy() async => false;
}
