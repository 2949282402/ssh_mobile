import '../app_log_service.dart';

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

  const McpActivityRecorder(this._repository);

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
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        'MCP activity persistence failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
