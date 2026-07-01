import 'dart:convert';

import 'mcp_server_settings.dart';

class McpConfigTemplates {
  const McpConfigTemplates._();

  static String codex(McpServerSettings settings) {
    return '''
[mcp_servers.ssh_mobile]
url = "${settings.url}"
tool_timeout_sec = 60
startup_timeout_sec = 10

[mcp_servers.ssh_mobile.http_headers]
Authorization = "Bearer ${settings.token}"
'''
        .trim();
  }

  static String claudeCode(McpServerSettings settings) {
    return 'claude mcp add --transport http ssh_mobile ${settings.url} --header "Authorization: Bearer ${settings.token}"';
  }

  static String geminiCli(McpServerSettings settings) {
    return const JsonEncoder.withIndent('  ').convert({
      'mcpServers': {
        'ssh_mobile': {
          'httpUrl': settings.url,
          'headers': {
            'Authorization': 'Bearer ${settings.token}',
          },
          'timeout': 30000,
        },
      },
    });
  }
}
