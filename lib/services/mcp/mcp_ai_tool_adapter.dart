import '../ai_tool_service.dart';
import '../tool_exposure_router.dart';

class McpAiToolAdapter {
  const McpAiToolAdapter();

  Map<String, dynamic> toMcpTool(AiTool tool) {
    return {
      'name': tool.name,
      'title': tool.name,
      'description': tool.description,
      'inputSchema': {
        'type': 'object',
        'properties': _cloneJsonMap(tool.properties),
        'required': tool.required,
        'additionalProperties': false,
      },
      'annotations': {
        'readOnlyHint': tool.executionMode == AiToolExecutionMode.readOnly,
        'destructiveHint': _isDestructive(tool),
        'idempotentHint': _isIdempotent(tool),
        'openWorldHint': _isOpenWorld(tool),
      },
    };
  }

  Map<String, dynamic> _cloneJsonMap(Map<String, dynamic> source) {
    return {
      for (final entry in source.entries)
        entry.key: _cloneJsonValue(entry.value),
    };
  }

  Object? _cloneJsonValue(Object? value) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          '${entry.key}': _cloneJsonValue(entry.value),
      };
    }
    if (value is List) {
      return value.map(_cloneJsonValue).toList(growable: false);
    }
    return value;
  }

  bool _isDestructive(AiTool tool) {
    final name = tool.name.toLowerCase();
    if (name.contains('delete') ||
        name.contains('clear') ||
        name.contains('remove') ||
        name.contains('overwrite') ||
        name.contains('import_app_backup')) {
      return true;
    }
    return name == 'ssh_close_server_sessions' ||
        name == 'ssh_close_session' ||
        name == 'ssh_restore_tmux_sessions';
  }

  bool _isIdempotent(AiTool tool) {
    if (tool.executionMode != AiToolExecutionMode.readOnly) return false;
    final name = tool.name.toLowerCase();
    return name.startsWith('query_') ||
        name.startsWith('list_') ||
        name.startsWith('get_') ||
        name.startsWith('inspect_') ||
        name.startsWith('detect_') ||
        name.contains('_status') ||
        name.contains('_state') ||
        name.contains('_health');
  }

  bool _isOpenWorld(AiTool tool) {
    final capabilities = tool.effectiveCapabilities;
    return capabilities.contains(AiToolCapability.server) ||
        capabilities.contains(AiToolCapability.ssh) ||
        capabilities.contains(AiToolCapability.sftp) ||
        capabilities.contains(AiToolCapability.monitor) ||
        capabilities.contains(AiToolCapability.web);
  }
}
