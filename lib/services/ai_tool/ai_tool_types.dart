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

  Future<AiToolApprovalRequest?> approvalRequestFor(
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

class AiPendingApprovalSnapshot {
  final String id;
  final AiToolApprovalRequest request;
  final Map<String, dynamic> arguments;
  final DateTime createdAt;

  const AiPendingApprovalSnapshot({
    required this.id,
    required this.request,
    required this.arguments,
    required this.createdAt,
  });
}

abstract interface class AiPendingApprovalSnapshotStore {
  Future<void> savePendingApprovalSnapshot(AiPendingApprovalSnapshot snapshot);

  Future<AiPendingApprovalSnapshot?> loadPendingApprovalSnapshot(String id);

  Future<void> clearPendingApprovalSnapshot(String id);
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
  final Set<AiToolCapability> capabilities;
  final bool requiresServerSelection;
  final bool requiresWebViewSession;
  final bool preferredInPlanMode;
  final bool parallelSafeReadOnly;
  final Duration? cacheTtl;
  final Future<String> Function(Map<String, dynamic> arguments) handler;

  const AiTool({
    required this.name,
    required this.description,
    required this.properties,
    required this.handler,
    this.required = const [],
    this.executionMode = AiToolExecutionMode.readOnly,
    this.capabilities = const {},
    this.requiresServerSelection = false,
    this.requiresWebViewSession = false,
    this.preferredInPlanMode = false,
    this.parallelSafeReadOnly = false,
    this.cacheTtl,
  });

  Set<AiToolCapability> get effectiveCapabilities {
    if (capabilities.isNotEmpty) return capabilities;
    if (name == 'web_search' || name.startsWith('client_webview_')) {
      return const {AiToolCapability.web, AiToolCapability.client};
    }
    if (name.startsWith('client_task_') || name == 'client_set_plan_mode') {
      return const {AiToolCapability.planning, AiToolCapability.client};
    }
    if (name.startsWith('client_')) {
      if (name.contains('log')) {
        return const {AiToolCapability.client, AiToolCapability.logs};
      }
      if (name.contains('setting') || name.contains('permission')) {
        return const {AiToolCapability.client, AiToolCapability.settings};
      }
      return const {AiToolCapability.client};
    }
    if (name.startsWith('ssh_')) {
      return const {AiToolCapability.ssh, AiToolCapability.server};
    }
    if (name.startsWith('sftp_')) {
      return const {AiToolCapability.sftp, AiToolCapability.server};
    }
    if (name.startsWith('monitor_')) {
      return const {AiToolCapability.monitor, AiToolCapability.diagnostics};
    }
    if (name.contains('playbook')) {
      return const {AiToolCapability.playbook};
    }
    if (name.contains('server') ||
        name.contains('ops') ||
        name == 'run_command') {
      return const {AiToolCapability.server, AiToolCapability.diagnostics};
    }
    return const {};
  }

  bool get needsServerSelection {
    if (requiresServerSelection) return true;
    if (name == 'monitor_get_state' ||
        name == 'monitor_get_health' ||
        name == 'monitor_get_alerts') {
      return false;
    }
    return name == 'run_command' ||
        name == 'detect_os' ||
        name == 'get_server_status' ||
        name == 'get_server_details' ||
        name == 'generate_ops_report' ||
        name.startsWith('sftp_') ||
        name.startsWith('monitor_get_') ||
        name.startsWith('monitor_stop_for_') ||
        name.startsWith('ssh_open_') ||
        name.startsWith('ssh_close_server_') ||
        name.startsWith('inspect_') ||
        name.startsWith('collect_incident_');
  }

  bool get needsWebViewSession {
    return requiresWebViewSession ||
        name == 'web_search' ||
        name.startsWith('client_webview_');
  }

  Duration get effectiveCacheTtl {
    if (cacheTtl != null) return cacheTtl!;
    return executionMode == AiToolExecutionMode.readOnly
        ? const Duration(seconds: 20)
        : Duration.zero;
  }

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

  Map<String, dynamic> definitionFor(AiConnectionSettings settings) {
    if (!_supportsOpenAiStrict(settings)) {
      return definition;
    }
    return {
      'type': 'function',
      'function': {
        'name': name,
        'description': description,
        'strict': true,
        'parameters': {
          'type': 'object',
          'properties': {
            for (final entry in properties.entries)
              entry.key: _strictSchemaNode(
                entry.value,
                required: required.contains(entry.key),
              ),
          },
          'required': properties.keys.toList(growable: false),
          'additionalProperties': false,
        },
      },
    };
  }

  bool _supportsOpenAiStrict(AiConnectionSettings settings) {
    if (settings.apiFormat != LlmApiFormat.openAiChatCompletions) {
      return false;
    }
    final host =
        Uri.tryParse(settings.baseUrl.trim())?.host.toLowerCase().trim() ?? '';
    return host == 'api.openai.com' &&
        _isKnownOpenAiStrictModel(settings.model);
  }

  Map<String, dynamic> _strictSchemaNode(
    Object? value, {
    required bool required,
  }) {
    if (value is! Map) return <String, dynamic>{};
    final source = <String, dynamic>{
      for (final entry in value.entries) '${entry.key}': entry.value,
    };

    final node = <String, dynamic>{};
    final description = source['description'];
    if (description is String && description.trim().isNotEmpty) {
      node['description'] = description;
    }

    final anyOf = source['anyOf'];
    if (anyOf is List) {
      final variants = [
        for (final item in anyOf)
          if (item is Map) _strictSchemaNode(item, required: true),
      ];
      if (!required && !variants.any(_schemaAllowsNull)) {
        variants.add(const {'type': 'null'});
      }
      node['anyOf'] = variants;
      return node;
    }

    final type = source['type'];
    final allowNull = !required || _typeContains(type, 'null');
    final hasObjectType =
        _typeContains(type, 'object') || source['properties'] is Map;
    if (hasObjectType) {
      final props = source['properties'];
      final sourceRequired = _stringSet(source['required']);
      final normalizedProps = <String, dynamic>{};
      if (props is Map) {
        for (final entry in props.entries) {
          final key = '${entry.key}';
          normalizedProps[key] = _strictSchemaNode(
            entry.value,
            required: sourceRequired.contains(key),
          );
        }
      }
      node['type'] =
          _strictType(type, fallback: 'object', allowNull: allowNull);
      node['properties'] = normalizedProps;
      node['required'] = normalizedProps.keys.toList(growable: false);
      node['additionalProperties'] = false;
      return node;
    }

    final hasArrayType = _typeContains(type, 'array') || source['items'] is Map;
    if (hasArrayType) {
      node['type'] = _strictType(type, fallback: 'array', allowNull: allowNull);
      final items = source['items'];
      if (items is Map) {
        node['items'] = _strictSchemaNode(items, required: true);
      }
      _copyEnum(source, node, required: required);
      return node;
    }

    final normalizedType = _strictType(type, allowNull: allowNull);
    if (normalizedType != null) {
      node['type'] = normalizedType;
    }
    _copyEnum(source, node, required: required);
    final constValue = source['const'];
    if (constValue != null) {
      node['const'] = constValue;
    }
    return node;
  }

  bool _isKnownOpenAiStrictModel(String model) {
    final normalized = model.trim().toLowerCase();
    if (normalized.isEmpty || normalized.startsWith('ft:')) {
      return false;
    }
    return _openAiStrictModelPrefixes.any(normalized.startsWith);
  }

  Object? _strictType(
    Object? type, {
    String? fallback,
    required bool allowNull,
  }) {
    final types = <String>[];
    void addType(Object? raw) {
      if (raw is! String || !_openAiStrictJsonTypes.contains(raw)) {
        return;
      }
      if (!types.contains(raw)) {
        types.add(raw);
      }
    }

    if (type is List) {
      for (final item in type) {
        addType(item);
      }
    } else {
      addType(type);
    }
    if (types.isEmpty && fallback != null) {
      addType(fallback);
    }
    if (allowNull) {
      addType('null');
    } else {
      types.remove('null');
    }
    if (types.isEmpty) return null;
    return types.length == 1 ? types.first : types;
  }

  bool _typeContains(Object? type, String expected) {
    return type == expected || (type is List && type.contains(expected));
  }

  Set<String> _stringSet(Object? value) {
    if (value is! List) return const {};
    return {
      for (final item in value)
        if (item is String) item,
    };
  }

  bool _schemaAllowsNull(Map<String, dynamic> schema) {
    return _typeContains(schema['type'], 'null');
  }

  void _copyEnum(
    Map<String, dynamic> source,
    Map<String, dynamic> target, {
    required bool required,
  }) {
    final enumValues = source['enum'];
    if (enumValues is! List) return;
    final normalizedEnum = List<Object?>.from(enumValues);
    if (!required && !normalizedEnum.contains(null)) {
      normalizedEnum.add(null);
    }
    target['enum'] = normalizedEnum;
  }

  static const Set<String> _openAiStrictJsonTypes = {
    'string',
    'number',
    'integer',
    'boolean',
    'object',
    'array',
    'null',
  };

  static const Set<String> _openAiStrictModelPrefixes = {
    'gpt-5',
    'gpt-4.1',
    'gpt-4.5',
    'gpt-4o',
    'chatgpt-4o',
    'o1',
    'o3',
    'o4',
  };
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
