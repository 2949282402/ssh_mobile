import 'dart:async';

import '../domain/mcp_ports.dart';

/// MCP 延迟工具图执行器。
/// 在 MCP HTTP Server 收到 initialize 请求时只暴露端口，
/// 仅当收到真正的 tools/list 或 tools/call 时才懒加载构造工具依赖图。
class LazyMcpToolExecutor
    implements
        McpToolExecutor,
        McpApprovalTargetGuard,
        McpApprovalRequestProvider {
  final McpToolExecutor Function() factory;
  McpToolExecutor? _delegate;
  Future<McpToolExecutor>? _initFuture;

  LazyMcpToolExecutor(this.factory);

  bool get isCreated => _delegate != null;

  Future<McpToolExecutor> _ensureDelegate() async {
    if (_delegate != null) return _delegate!;
    if (_initFuture != null) return _initFuture!;

    _initFuture = Future(() {
      final instance = factory();
      _delegate = instance;
      return instance;
    });

    try {
      return await _initFuture!;
    } catch (e) {
      _initFuture = null;
      rethrow;
    }
  }

  @override
  Future<List<McpTool>> tools() async {
    final delegate = await _ensureDelegate();
    return delegate.tools();
  }

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async {
    final delegate = await _ensureDelegate();
    return delegate.toolDefinitions();
  }

  @override
  Future<McpApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final delegate = await _ensureDelegate();
    return delegate.approvalRequestFor(name, arguments);
  }

  @override
  Future<McpApprovalRequest?> mcpApprovalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final delegate = await _ensureDelegate();
    if (delegate is McpApprovalRequestProvider) {
      return (delegate as McpApprovalRequestProvider).mcpApprovalRequestFor(
        name,
        arguments,
      );
    }
    return delegate.approvalRequestFor(name, arguments);
  }

  @override
  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async {
    final delegate = await _ensureDelegate();
    return delegate.execute(name, arguments, approvedWrite: approvedWrite);
  }

  @override
  Future<bool> isApprovalTargetCurrent(McpApprovalRequest request) async {
    final delegate = await _ensureDelegate();
    final guard = delegate is McpApprovalTargetGuard
        ? delegate as McpApprovalTargetGuard
        : null;
    if (guard == null) return false;
    return guard.isApprovalTargetCurrent(request);
  }

  @override
  Future<String> executeApproved(
    McpApprovalRequest request,
    Map<String, dynamic> arguments,
  ) async {
    final delegate = await _ensureDelegate();
    final guard = delegate is McpApprovalTargetGuard
        ? delegate as McpApprovalTargetGuard
        : null;
    if (guard == null) {
      return '{"error":"approval_target_guard_unavailable"}';
    }
    return guard.executeApproved(request, arguments);
  }

  void reset() {
    _delegate = null;
    _initFuture = null;
  }
}
