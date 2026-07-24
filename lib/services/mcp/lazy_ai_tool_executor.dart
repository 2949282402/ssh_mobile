import 'dart:async';
import '../ai_tool_service.dart';
import '../../features/connection/models/connection.dart';
import '../../utils/startup_instrumentation.dart';

/// MCP 延迟工具图执行器。
/// 在 MCP HTTP Server 收到 initialize 请求时只暴露端口，
/// 仅当收到真正的 tools/list 或 tools/call 时才懒加载构造 AiToolService 依赖图。
class LazyAiToolExecutor implements AiToolExecutor {
  final AiToolExecutor Function() factory;
  AiToolExecutor? _delegate;
  Future<AiToolExecutor>? _initFuture;

  LazyAiToolExecutor(this.factory);

  bool get isCreated => _delegate != null;

  Future<AiToolExecutor> _ensureDelegate() async {
    if (_delegate != null) return _delegate!;
    if (_initFuture != null) return _initFuture!;

    _initFuture = Future(() {
      StartupInstrumentation.instance.recordServiceInitialized(
        'LazyAiToolExecutor',
      );
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
  Future<List<AiTool>> tools() async {
    final delegate = await _ensureDelegate();
    return delegate.tools();
  }

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async {
    final delegate = await _ensureDelegate();
    return delegate.toolDefinitions();
  }

  @override
  Future<AiToolApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final delegate = await _ensureDelegate();
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
  AiCommandReview reviewCommand(String command, {ServerPlatform? platform}) {
    if (_delegate != null) {
      return _delegate!.reviewCommand(command, platform: platform);
    }
    return const AiCommandReview.readOnly();
  }

  void reset() {
    _delegate = null;
    _initFuture = null;
  }
}
