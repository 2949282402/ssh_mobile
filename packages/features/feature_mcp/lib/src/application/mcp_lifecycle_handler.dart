import 'mcp_json_rpc.dart';

/// 处理 MCP 初始化、心跳和初始化通知，不触发工具图构造。
class McpLifecycleHandler {
  static const String protocolVersion = '2025-06-18';

  const McpLifecycleHandler();

  bool canHandle(String method) {
    return method == 'initialize' ||
        method == 'notifications/initialized' ||
        method == 'ping';
  }

  McpJsonRpcHandlerResult handle(McpJsonRpcRequest request) {
    switch (request.method) {
      case 'initialize':
        return const McpJsonRpcHandlerResult.result({
          'protocolVersion': protocolVersion,
          'capabilities': {
            'tools': {'listChanged': false},
          },
          'serverInfo': {
            'name': 'ssh_mobile',
            'title': 'SSH Mobile MCP Server',
            'version': '1.0.0',
          },
          'instructions':
              'Use SSH Mobile tools to inspect and operate saved SSH/SFTP servers through the local SSH Mobile app.',
        });
      case 'notifications/initialized':
        return const McpJsonRpcHandlerResult.noResponse();
      case 'ping':
        return const McpJsonRpcHandlerResult.result(<String, dynamic>{});
    }
    throw McpJsonRpcException(
      McpJsonRpcErrorCodes.methodNotFound,
      'Method not found',
      id: request.id,
    );
  }
}
