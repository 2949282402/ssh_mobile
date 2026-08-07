// 旧监控模型路径的兼容类型别名；真实模型归属于 feature_monitoring。

part of 'performance_monitor_service.dart';

/// 兼容旧导入路径的健康等级。
typedef ServerHealthLevel = monitoring.ServerHealthLevel;

/// 兼容旧导入路径的健康快照。
typedef ServerHealthSnapshot = monitoring.ServerHealthSnapshot;

/// 兼容旧导入路径的监控告警。
typedef MonitorAlert = monitoring.MonitorAlert;

/// 兼容旧导入路径的性能采样。
typedef PerformanceSample = monitoring.PerformanceSample;
