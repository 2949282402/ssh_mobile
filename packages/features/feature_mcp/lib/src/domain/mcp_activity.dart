import 'mcp_ports.dart';

// MCP 活动模型与记录器。只保存脱敏的协议、策略和生命周期元数据。

enum McpActivityKind { lifecycle, protocol, tool, security }

enum McpActivityOutcome { success, denied, failed }

class McpActivityRecord {
  final int? id;
  final DateTime occurredAt;
  final McpActivityKind kind;
  final String? method;
  final String? toolName;
  final McpActivityOutcome outcome;
  final String? policyReason;
  final int? durationMs;

  const McpActivityRecord({
    this.id,
    required this.occurredAt,
    required this.kind,
    this.method,
    this.toolName,
    required this.outcome,
    this.policyReason,
    this.durationMs,
  });
}

abstract interface class McpActivityRepository {
  Future<List<McpActivityRecord>> loadMcpActivityRecords({int limit = 500});
  Future<void> recordMcpActivity(McpActivityRecord record);
  Future<void> clearMcpActivityRecords();
}

class McpActivityRecorder {
  final McpActivityRepository _repository;
  final McpLoggerPort? logger;

  /// 创建一个不拥有 Repository 的记录器；Repository 生命周期由 Module 管理。
  const McpActivityRecorder(this._repository, {this.logger});

  Future<void> record({
    required McpActivityKind kind,
    required McpActivityOutcome outcome,
    String? method,
    String? toolName,
    String? policyReason,
    int? durationMs,
  }) async {
    try {
      await _repository.recordMcpActivity(
        McpActivityRecord(
          occurredAt: DateTime.now(),
          kind: kind,
          method: method,
          toolName: toolName,
          outcome: outcome,
          policyReason: policyReason,
          durationMs: durationMs,
        ),
      );
    } catch (error) {
      logger?.error(
        'MCP activity persistence failed',
        details:
            'errorCode=activity_persistence_failed '
            'errorType=${error.runtimeType}',
      );
    }
  }
}
