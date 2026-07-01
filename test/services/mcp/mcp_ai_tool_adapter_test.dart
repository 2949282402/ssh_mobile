import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/mcp/mcp_ai_tool_adapter.dart';

void main() {
  group('McpAiToolAdapter', () {
    const adapter = McpAiToolAdapter();

    test('maps name, description, inputSchema, and required fields', () {
      final tool = AiTool(
        name: 'list_servers',
        description: 'List saved servers.',
        properties: {
          'limit': {'type': 'integer'},
        },
        required: const ['limit'],
        handler: (_) async => '{}',
      );

      final mapped = adapter.toMcpTool(tool);
      expect(mapped['name'], 'list_servers');
      expect(mapped['title'], 'list_servers');
      expect(mapped['description'], 'List saved servers.');
      expect(mapped['inputSchema'], {
        'type': 'object',
        'properties': {
          'limit': {'type': 'integer'},
        },
        'required': ['limit'],
        'additionalProperties': false,
      });
    });

    test('adds readOnlyHint for read-only tool', () {
      final mapped = adapter.toMcpTool(
        AiTool(
          name: 'get_server_status',
          description: 'Get status.',
          properties: const {},
          handler: (_) async => '{}',
        ),
      );

      expect((mapped['annotations'] as Map)['readOnlyHint'], isTrue);
      expect((mapped['annotations'] as Map)['idempotentHint'], isTrue);
    });

    test('adds destructiveHint for destructive tool', () {
      final mapped = adapter.toMcpTool(
        AiTool(
          name: 'sftp_delete_entry',
          description: 'Delete file.',
          properties: const {},
          executionMode: AiToolExecutionMode.stateChanging,
          handler: (_) async => '{}',
        ),
      );

      expect((mapped['annotations'] as Map)['destructiveHint'], isTrue);
    });

    test('adds openWorldHint for SSH/SFTP tool', () {
      final mapped = adapter.toMcpTool(
        AiTool(
          name: 'ssh_open_session',
          description: 'Open SSH.',
          properties: const {},
          executionMode: AiToolExecutionMode.stateChanging,
          handler: (_) async => '{}',
        ),
      );

      expect((mapped['annotations'] as Map)['openWorldHint'], isTrue);
    });
  });
}
