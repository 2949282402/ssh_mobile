import '../domain/mcp_ports.dart';

/// 将 MCP 工具契约转换成 Model Context Protocol 的 tools/list schema。
class McpAiToolAdapter {
  const McpAiToolAdapter();

  Map<String, dynamic> toMcpTool(McpTool tool) {
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
        'readOnlyHint': tool.executionMode == McpToolExecutionMode.readOnly,
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

  bool _isDestructive(McpTool tool) {
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

  bool _isIdempotent(McpTool tool) {
    if (tool.executionMode != McpToolExecutionMode.readOnly) return false;
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

  bool _isOpenWorld(McpTool tool) {
    final capabilities = tool.effectiveCapabilities;
    return capabilities.contains(McpToolCapability.server) ||
        capabilities.contains(McpToolCapability.ssh) ||
        capabilities.contains(McpToolCapability.sftp) ||
        capabilities.contains(McpToolCapability.monitor) ||
        capabilities.contains(McpToolCapability.web);
  }
}
