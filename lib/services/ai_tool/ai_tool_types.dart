part of '../ai_tool_service.dart';

abstract interface class AiToolProvider {
  Future<List<AiTool>> getTools(AiToolService service);

  Future<String?> execute(
    AiToolService service,
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  });
}

abstract interface class AiToolExecutor {
  Future<List<AiTool>> tools();

  Future<List<Map<String, dynamic>>> toolDefinitions();

  AiToolApprovalRequest? approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  );

  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  });

  AiCommandReview reviewCommand(
    String command, {
    ServerPlatform? platform,
  });
}

class AiToolApprovalRequest {
  final String toolName;
  final String approvalType;
  final String connectionId;
  final String connectionName;
  final String command;
  final String reason;
  final String? targetPath;
  final int? byteLength;
  final String? contentPreview;
  final bool destructive;

  const AiToolApprovalRequest({
    required this.toolName,
    required this.approvalType,
    required this.connectionId,
    required this.connectionName,
    required this.command,
    required this.reason,
    this.targetPath,
    this.byteLength,
    this.contentPreview,
    this.destructive = false,
  });
}

class AiToolApprovalDecision {
  final bool approved;
  final bool abort;
  final String? feedback;

  const AiToolApprovalDecision.approved()
      : approved = true,
        abort = false,
        feedback = null;

  const AiToolApprovalDecision.rejected({
    this.abort = true,
    this.feedback,
  }) : approved = false;
}

class AiCommandReview {
  final bool requiresApproval;
  final bool blocked;
  final String reason;

  const AiCommandReview.readOnly()
      : requiresApproval = false,
        blocked = false,
        reason = 'Read-only diagnostic command.';

  const AiCommandReview.requiresApproval(this.reason)
      : requiresApproval = true,
        blocked = false;

  const AiCommandReview.blocked(this.reason)
      : requiresApproval = false,
        blocked = true;
}

enum AiToolExecutionMode {
  readOnly,
  planOnly,
  executionOnly,
  stateChanging,
  planControl;

  bool get allowedInPlanMode {
    return this == AiToolExecutionMode.readOnly ||
        this == AiToolExecutionMode.planOnly ||
        this == AiToolExecutionMode.planControl;
  }
}

class AiTool {
  final String name;
  final String description;
  final Map<String, dynamic> properties;
  final List<String> required;
  final AiToolExecutionMode executionMode;
  final Future<String> Function(Map<String, dynamic> arguments) handler;

  const AiTool({
    required this.name,
    required this.description,
    required this.properties,
    required this.handler,
    this.required = const [],
    this.executionMode = AiToolExecutionMode.readOnly,
  });

  Map<String, dynamic> get definition {
    return {
      'type': 'function',
      'function': {
        'name': name,
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': properties,
          'required': required,
          'additionalProperties': false,
        },
      },
    };
  }
}

class _UnavailablePerformanceMonitorToolService
    implements PerformanceMonitorToolAdapter {
  const _UnavailablePerformanceMonitorToolService();

  static const String _message =
      'Performance monitor service is not available in this context.';

  @override
  Map<String, dynamic> clearSelection() =>
      {'supported': false, 'error': _message};

  @override
  Future<Map<String, dynamic>> getApplications(String connectionId) async =>
      {'supported': false, 'error': _message};

  @override
  Map<String, dynamic> getAlerts({int limit = 50}) =>
      {'supported': false, 'error': _message};

  @override
  Map<String, dynamic> getHealth({List<String>? connectionIds}) =>
      {'supported': false, 'error': _message};

  @override
  Future<Map<String, dynamic>> getPorts(String connectionId) async =>
      {'supported': false, 'error': _message};

  @override
  Map<String, dynamic> getSamples(
    String connectionId, {
    bool visibleOnly = true,
    int limit = 100,
  }) =>
      {'supported': false, 'error': _message};

  @override
  Map<String, dynamic> getState() => {'supported': false, 'error': _message};

  @override
  Map<String, dynamic> setHistoryWindow(Duration window) =>
      {'supported': false, 'error': _message};

  @override
  Map<String, dynamic> setInterval(Duration interval) =>
      {'supported': false, 'error': _message};

  @override
  Map<String, dynamic> setSelectedServers(List<String> connectionIds) =>
      {'supported': false, 'error': _message};

  @override
  Future<Map<String, dynamic>> start() async =>
      {'supported': false, 'error': _message};

  @override
  Map<String, dynamic> stop() => {'supported': false, 'error': _message};

  @override
  Map<String, dynamic> stopForConnection(String connectionId) =>
      {'supported': false, 'error': _message};
}

Map<String, dynamic> _string(String description) =>
    AiToolService._string(description);

Map<String, dynamic> _int(
  String description, {
  int? minimum,
  int? maximum,
  int? defaultValue,
}) =>
    AiToolService._int(
      description,
      minimum: minimum,
      maximum: maximum,
      defaultValue: defaultValue,
    );

Map<String, dynamic> _bool(String description) =>
    AiToolService._bool(description);

Map<String, dynamic> _stringArray(
  String description, {
  int? minimumItems,
}) =>
    AiToolService._stringArray(description, minimumItems: minimumItems);

Map<String, dynamic> _intArray(
  String description, {
  int? minimumItems,
}) =>
    AiToolService._intArray(description, minimumItems: minimumItems);
