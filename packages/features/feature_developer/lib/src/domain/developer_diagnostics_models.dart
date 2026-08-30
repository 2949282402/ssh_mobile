import 'package:app_core/app_core.dart';

/// 单个 App Module 的只读生命周期快照。
///
/// Developer Feature 只观察状态，不持有 Module，也不能通过快照控制模块。
final class DeveloperModuleSnapshot {
  /// 创建一个模块生命周期快照。
  const DeveloperModuleSnapshot({required this.id, required this.state});

  /// 模块稳定标识。
  final String id;

  /// 模块当前生命周期状态。
  final ModuleState state;

  /// 模块是否已经完成初始化且仍可被使用。
  bool get initialized => switch (state) {
    ModuleState.registered || ModuleState.disposed => false,
    ModuleState.initialized ||
    ModuleState.active ||
    ModuleState.inactive => true,
  };

  /// 模块是否当前处于活动状态。
  bool get active => state == ModuleState.active;
}

/// SSH App Scope 的资源计数快照。
final class DeveloperSshSnapshot {
  /// 创建 SSH 资源计数快照。
  const DeveloperSshSnapshot({
    required this.activeSessions,
    required this.idleSessions,
    required this.leaseCount,
  });

  /// 连接中或已连接的会话数。
  final int activeSessions;

  /// 已登记但当前未连接的会话数。
  final int idleSessions;

  /// 仍被调用方持有的 Session Lease 数。
  final int leaseCount;
}

/// NetworkRuntime 能直接观测到的网络资源计数快照。
final class DeveloperNetworkSnapshot {
  /// 创建网络资源计数快照。
  const DeveloperNetworkSnapshot({
    required this.activeConnections,
    required this.nativeHandles,
  });

  /// 当前由 NetworkRuntime 直接登记的活跃连接数。
  final int activeConnections;

  /// 当前由 NetworkRuntime 持有的 native handle 数。
  final int nativeHandles;
}

/// Composition Root 提供的数据库诊断描述；打开状态在每次快照生成时读取。
///
/// 数据库可能按需初始化（例如 AI），因此不能在 Runtime 创建时把 opened
/// 状态冻结；回调只返回状态，不暴露数据库句柄或控制能力。
final class DeveloperDatabaseDescriptor {
  /// 创建一个数据库诊断描述。
  const DeveloperDatabaseDescriptor({
    required this.moduleId,
    required this.databaseName,
    required this.isOpen,
  });

  /// 负责该数据库的 Module 或 App Scope 标识。
  final String moduleId;

  /// 供诊断页面展示的数据库名称。
  final String databaseName;

  /// 返回当前 Owner 是否已打开数据库。
  final bool Function() isOpen;

  /// 读取当前打开状态并生成不可变快照。
  DeveloperDatabaseSnapshot readSnapshot() => DeveloperDatabaseSnapshot(
    moduleId: moduleId,
    databaseName: databaseName,
    opened: isOpen(),
  );
}

/// 一个已知数据库的只读打开状态。
final class DeveloperDatabaseSnapshot {
  /// 创建数据库打开状态快照。
  const DeveloperDatabaseSnapshot({
    required this.moduleId,
    required this.databaseName,
    required this.opened,
  });

  /// 负责该数据库的 Module 或 App Scope 标识。
  final String moduleId;

  /// 供诊断页面展示的数据库名称。
  final String databaseName;

  /// 当前 Owner 是否已经打开数据库。
  final bool opened;
}

/// 已知 Timer 和 Stream 订阅资源的计数快照。
///
/// 这是“已接入诊断的资源”计数，不宣称可以枚举 Dart isolate 中所有
/// Timer 或 Stream；新的长期资源应在其 Owner 增加对应的诊断适配。
final class DeveloperResourceSnapshot {
  /// 创建资源计数快照。
  const DeveloperResourceSnapshot({
    required this.activeTimers,
    required this.activeSubscriptions,
  });

  /// 已知仍在运行的 Timer 数。
  final int activeTimers;

  /// 已知仍在监听的 Stream/Listenable 订阅数。
  final int activeSubscriptions;
}

/// Telemetry 模块的只读诊断快照。
final class DeveloperTelemetrySnapshot {
  /// 创建 Telemetry 诊断快照。
  const DeveloperTelemetrySnapshot({
    required this.localPendingCount,
    required this.localRejectedCount,
    required this.localSyncedCount,
    required this.totalCount,
    required this.cacheOverflow,
    this.oldestPendingAge,
    this.oldestRejectedAge,
    this.overflowCount = 0,
    required this.uploadEnabled,
    required this.policyVersion,
    required this.batchSizeThreshold,
    required this.timeIntervalSeconds,
    this.lastSyncTime,
    this.lastSyncError,
    required this.isUploading,
  });

  /// 待上传记录数。
  final int localPendingCount;

  /// 已被拒绝记录数。
  final int localRejectedCount;

  /// 已成功同步记录数。
  final int localSyncedCount;

  /// 本地总记录数。
  final int totalCount;

  /// 是否发生缓存超限（非丢失不变量激活）。
  final bool cacheOverflow;

  /// Age of the oldest pending local record, if present.
  final Duration? oldestPendingAge;

  /// Age of the oldest rejected local record, if present.
  final Duration? oldestRejectedAge;

  /// Number of rows above the configured local target capacity.
  final int overflowCount;

  /// 上传是否开启。
  final bool uploadEnabled;

  /// 策略版本。
  final int policyVersion;

  /// 批次条数阈值。
  final int batchSizeThreshold;

  /// 定时上传周期（秒）。
  final int timeIntervalSeconds;

  /// 最近同步时间。
  final DateTime? lastSyncTime;

  /// 最近同步错误（如有）。
  final String? lastSyncError;

  /// 当前是否正在上传。
  final bool isUploading;
}

/// Developer Panel 展示的完整生命周期诊断快照。
final class DeveloperDiagnosticsSnapshot {
  /// 创建完整诊断快照，并冻结所有集合，避免页面观察期间被外部修改。
  DeveloperDiagnosticsSnapshot({
    required this.capturedAt,
    required Iterable<DeveloperModuleSnapshot> modules,
    required this.ssh,
    required this.network,
    required Iterable<DeveloperDatabaseSnapshot> databases,
    required this.resources,
    this.telemetry,
  }) : modules = List.unmodifiable(modules),
       databases = List.unmodifiable(databases);

  /// 快照生成时间。
  final DateTime capturedAt;

  /// App Scope 当前已登记的 Module 列表。
  final List<DeveloperModuleSnapshot> modules;

  /// SSH 资源计数。
  final DeveloperSshSnapshot ssh;

  /// NetworkRuntime 资源计数。
  final DeveloperNetworkSnapshot network;

  /// Composition Root 提供的已知数据库列表。
  final List<DeveloperDatabaseSnapshot> databases;

  /// 已接入诊断的 Timer/订阅计数。
  final DeveloperResourceSnapshot resources;

  /// Telemetry 诊断快照（若已接入）。
  final DeveloperTelemetrySnapshot? telemetry;
}
