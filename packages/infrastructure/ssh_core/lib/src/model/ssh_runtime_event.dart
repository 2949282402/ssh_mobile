// SSH Runtime 与 App Scope 之间传递的无平台事件模型。
//
// 平台桥接只负责把原生事件转换成该模型，Session Manager 和 Feature 不需要
// 了解 MethodChannel、flutter_background_service 或具体平台判断。

/// Runtime 事件类别。
enum SshRuntimeEventType { stateChanged, dataReceived, overviewUpdated, log }

/// 一条来自 SSH Runtime 的平台无关事件。
final class SshRuntimeEvent {
  /// 创建 Runtime 事件。
  const SshRuntimeEvent({
    required this.type,
    this.sessionId,
    this.state,
    this.data,
    this.overview,
    this.details,
  });

  /// 事件类别。
  final SshRuntimeEventType type;

  /// 关联会话 id。
  final String? sessionId;

  /// 状态名称，转换成 [SshConnectionState] 由上层完成。
  final String? state;

  /// 输出或日志正文。
  final String? data;

  /// Runtime 聚合摘要。
  final Map<String, Object?>? overview;

  /// 可选诊断信息。
  final String? details;
}
