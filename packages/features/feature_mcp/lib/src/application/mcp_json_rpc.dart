import 'dart:async';
import 'dart:convert';

import 'mcp_lifecycle_handler.dart';
import 'mcp_tool_handler.dart';

/// MCP JSON-RPC 解析、错误映射和方法路由，保证协议错误不越界到 HTTP 层。
class McpJsonRpcErrorCodes {
  static const int parseError = -32700;
  static const int invalidRequest = -32600;
  static const int methodNotFound = -32601;
  static const int invalidParams = -32602;
  static const int internalError = -32603;
}

class McpJsonRpcException implements Exception {
  final int code;
  final String message;
  final Object? data;
  final Object? id;

  const McpJsonRpcException(this.code, this.message, {this.data, this.id});

  @override
  String toString() => 'McpJsonRpcException($code, $message)';
}

class McpJsonRpcRequest {
  final Object? id;
  final bool hasId;
  final String method;
  final Map<String, dynamic>? params;

  const McpJsonRpcRequest({
    required this.id,
    required this.hasId,
    required this.method,
    this.params,
  });

  bool get isNotification => !hasId;
}

class McpJsonRpcHandlerResult {
  final Object? result;
  final bool noResponse;

  const McpJsonRpcHandlerResult.result(this.result) : noResponse = false;
  const McpJsonRpcHandlerResult.noResponse() : result = null, noResponse = true;
}

class McpJsonRpcHttpResult {
  final int statusCode;
  final Object? body;
  final bool hasBody;

  const McpJsonRpcHttpResult({
    required this.statusCode,
    required this.body,
    this.hasBody = true,
  });
}

class McpJsonRpc {
  static McpJsonRpcRequest parse(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const McpJsonRpcException(
        McpJsonRpcErrorCodes.parseError,
        'Parse error',
      );
    }

    if (decoded is! Map) {
      throw const McpJsonRpcException(
        McpJsonRpcErrorCodes.invalidRequest,
        'Invalid Request',
      );
    }

    final jsonrpc = decoded['jsonrpc'];
    final method = decoded['method'];
    if (jsonrpc != '2.0' || method is! String || method.trim().isEmpty) {
      throw McpJsonRpcException(
        McpJsonRpcErrorCodes.invalidRequest,
        'Invalid Request',
        id: decoded['id'],
      );
    }

    final hasId = decoded.containsKey('id');
    final id = decoded['id'];
    if (hasId && id != null && id is! String && id is! num) {
      throw McpJsonRpcException(
        McpJsonRpcErrorCodes.invalidRequest,
        'Invalid Request',
        id: id,
      );
    }

    final params = decoded['params'];
    if (params != null && params is! Map) {
      throw McpJsonRpcException(
        McpJsonRpcErrorCodes.invalidParams,
        'Invalid params',
        id: id,
      );
    }

    final normalizedParams = <String, dynamic>{};
    if (params is Map) {
      for (final entry in params.entries) {
        if (entry.key is String) {
          normalizedParams[entry.key as String] = entry.value;
        }
      }
    }

    return McpJsonRpcRequest(
      id: id,
      hasId: hasId,
      method: method,
      params: params == null ? null : normalizedParams,
    );
  }

  static Map<String, dynamic> successResponse(Object? id, Object? result) {
    return {
      'jsonrpc': '2.0',
      'id': id,
      'result': result ?? <String, dynamic>{},
    };
  }

  static Map<String, dynamic> errorResponse({
    required Object? id,
    required int code,
    required String message,
    Object? data,
  }) {
    return {
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': message, 'data': ?data},
    };
  }
}

class McpJsonRpcRouter {
  final McpLifecycleHandler lifecycleHandler;
  final McpToolHandler toolHandler;

  const McpJsonRpcRouter({
    required this.lifecycleHandler,
    required this.toolHandler,
  });

  Future<McpJsonRpcHttpResult> route(String body) async {
    McpJsonRpcRequest request;
    try {
      request = McpJsonRpc.parse(body);
    } on McpJsonRpcException catch (e) {
      return McpJsonRpcHttpResult(
        statusCode: 200,
        body: McpJsonRpc.errorResponse(
          id: e.id,
          code: e.code,
          message: e.message,
          data: e.data,
        ),
      );
    }

    try {
      final result = await _dispatch(request);
      if (request.isNotification || result.noResponse) {
        return const McpJsonRpcHttpResult(
          statusCode: 202,
          body: null,
          hasBody: false,
        );
      }
      return McpJsonRpcHttpResult(
        statusCode: 200,
        body: McpJsonRpc.successResponse(request.id, result.result),
      );
    } on McpJsonRpcException catch (e) {
      if (request.isNotification) {
        return const McpJsonRpcHttpResult(
          statusCode: 202,
          body: null,
          hasBody: false,
        );
      }
      return McpJsonRpcHttpResult(
        statusCode: 200,
        body: McpJsonRpc.errorResponse(
          id: e.id ?? request.id,
          code: e.code,
          message: e.message,
          data: e.data,
        ),
      );
    } catch (e) {
      if (request.isNotification) {
        return const McpJsonRpcHttpResult(
          statusCode: 202,
          body: null,
          hasBody: false,
        );
      }
      return McpJsonRpcHttpResult(
        statusCode: 200,
        body: McpJsonRpc.errorResponse(
          id: request.id,
          code: McpJsonRpcErrorCodes.internalError,
          message: 'Internal error',
          data: {'error': e.toString()},
        ),
      );
    }
  }

  Future<McpJsonRpcHandlerResult> _dispatch(McpJsonRpcRequest request) async {
    if (lifecycleHandler.canHandle(request.method)) {
      return lifecycleHandler.handle(request);
    }
    if (toolHandler.canHandle(request.method)) {
      return toolHandler.handle(request);
    }
    throw McpJsonRpcException(
      McpJsonRpcErrorCodes.methodNotFound,
      'Method not found',
      id: request.id,
    );
  }
}
