import 'package:flutter_test/flutter_test.dart';
import 'package:feature_mcp/feature_mcp.dart';

void main() {
  group('McpAiToolAdapter', () {
    const adapter = McpAiToolAdapter();

    test('maps name, description, inputSchema, and required fields', () {
      const tool = McpTool(
        name: 'list_servers',
        description: 'List saved servers.',
        properties: {
          'limit': {'type': 'integer'},
        },
        required: ['limit'],
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
        const McpTool(
          name: 'get_server_status',
          description: 'Get status.',
          properties: {},
        ),
      );

      expect((mapped['annotations'] as Map)['readOnlyHint'], isTrue);
      expect((mapped['annotations'] as Map)['idempotentHint'], isTrue);
    });

    test('adds destructiveHint for destructive tool', () {
      final mapped = adapter.toMcpTool(
        const McpTool(
          name: 'sftp_delete_entry',
          description: 'Delete file.',
          properties: {},
          executionMode: McpToolExecutionMode.stateChanging,
        ),
      );

      expect((mapped['annotations'] as Map)['destructiveHint'], isTrue);
    });

    test('adds openWorldHint for SSH/SFTP tool', () {
      final mapped = adapter.toMcpTool(
        const McpTool(
          name: 'ssh_open_session',
          description: 'Open SSH.',
          properties: {},
          executionMode: McpToolExecutionMode.stateChanging,
        ),
      );

      expect((mapped['annotations'] as Map)['openWorldHint'], isTrue);
    });
  });
}
