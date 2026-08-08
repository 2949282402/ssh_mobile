// MCP App Shell 适配器。
//
// 这些适配器把 AppSettings、AppLogService 和旧 AI Tool Service 转换成
// feature_mcp 的公共 Contract；MCP Package 因此不反向依赖 App 实现。

import 'dart:convert';

import 'package:feature_mcp/feature_mcp.dart' as mcp;
import 'package:flutter/foundation.dart';

import '../services/ai_tool_service.dart';
import '../services/app_log_service.dart';
import '../services/app_settings.dart';
import '../services/tool_exposure_router.dart';

/// 将应用设置暴露为 MCP 的可监听 Settings Port。
final class AppMcpSettingsAdapter extends ChangeNotifier
    implements mcp.McpSettingsPort {
  AppMcpSettingsAdapter(this._settings) {
    _settings.addListener(_forwardChange);
  }

  final AppSettings _settings;

  @override
  mcp.McpServerSettings get mcpSettings => _settings.mcpSettings;

  @override
  bool get isEnglish => _settings.isEnglish;

  @override
  Future<void> ensureCoreLoaded() => _settings.ensureCoreLoaded();

  @override
  Future<String> ensureMcpServerToken() => _settings.ensureMcpServerToken();

  @override
  Future<void> setMcpServerEnabled(bool value) =>
      _settings.setMcpServerEnabled(value);

  @override
  Future<void> setMcpServerPort(int port) => _settings.setMcpServerPort(port);

  @override
  Future<void> setMcpApprovalMode(mcp.McpApprovalMode mode) =>
      _settings.setMcpApprovalMode(mode);

  @override
  Future<void> setMcpToolExposure(
    String toolName,
    bool exposed, {
    required Set<String> availableToolNames,
  }) => _settings.setMcpToolExposure(
    toolName,
    exposed,
    availableToolNames: availableToolNames,
  );

  @override
  Future<void> setMcpToolSecondaryReview(String toolName, bool enabled) =>
      _settings.setMcpToolSecondaryReview(toolName, enabled);

  @override
  Future<void> setMcpSecondaryReviewTools(Set<String> tools) =>
      _settings.setMcpSecondaryReviewTools(tools);

  @override
  Future<String> regenerateMcpServerToken() =>
      _settings.regenerateMcpServerToken();

  void _forwardChange() => notifyListeners();

  @override
  void dispose() {
    _settings.removeListener(_forwardChange);
    super.dispose();
  }
}

/// 将 App 日志实现转换成 MCP 的最小日志 Port。
final class AppMcpLoggerAdapter implements mcp.McpLoggerPort {
  const AppMcpLoggerAdapter(this._logger);

  final AppLogService _logger;

  @override
  void info(String message, {String? details}) =>
      _logger.info(message, details: details);

  @override
  void warning(String message, {String? details}) =>
      _logger.warning(message, details: details);

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) => _logger.error(
    message,
    error: error,
    stackTrace: stackTrace,
    details: details,
  );
}

/// App Shell 按请求懒构造当前 AI 工具运行时。
final class AppMcpToolRuntimeAdapter implements mcp.McpToolRuntimePort {
  const AppMcpToolRuntimeAdapter(this._factory);

  final mcp.McpToolExecutor Function() _factory;

  @override
  mcp.McpToolExecutor createToolExecutor() => _factory();
}

/// 将旧 AI Tool Executor 映射为 MCP 自有的工具与审批 Contract。
final class AppAiToolExecutorAdapter
    implements
        mcp.McpToolExecutor,
        mcp.McpApprovalTargetGuard,
        mcp.McpApprovalRequestProvider,
        mcp.McpChatSessionState {
  const AppAiToolExecutorAdapter(this._delegate);

  final AiToolExecutor _delegate;

  @override
  bool get hasChatSession {
    final delegate = _delegate;
    return delegate is AiToolService && delegate.clientWebViewSessionId != null;
  }

  @override
  Future<List<mcp.McpTool>> tools() async {
    final tools = await _delegate.tools();
    return List.unmodifiable(tools.map(_toMcpTool));
  }

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() =>
      _delegate.toolDefinitions();

  @override
  Future<mcp.McpApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final request = await _delegate.approvalRequestFor(name, arguments);
    return request == null ? null : _toMcpApprovalRequest(request);
  }

  @override
  Future<mcp.McpApprovalRequest?> mcpApprovalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final request = _delegate is McpApprovalRequestProvider
        ? await (_delegate as McpApprovalRequestProvider).mcpApprovalRequestFor(
            name,
            arguments,
          )
        : await _delegate.approvalRequestFor(name, arguments);
    return request == null ? null : _toMcpApprovalRequest(request);
  }

  @override
  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) => _delegate.execute(name, arguments, approvedWrite: approvedWrite);

  @override
  Future<bool> isApprovalTargetCurrent(mcp.McpApprovalRequest request) async {
    final delegate = _delegate;
    if (delegate is! AiToolApprovalTargetGuard) return false;
    final original = _originalRequest(request);
    if (original == null) return false;
    final guard = delegate as AiToolApprovalTargetGuard;
    return guard.isApprovalTargetCurrent(original);
  }

  @override
  Future<String> executeApproved(
    mcp.McpApprovalRequest request,
    Map<String, dynamic> arguments,
  ) async {
    final delegate = _delegate;
    if (delegate is! AiToolApprovalTargetGuard) {
      return jsonEncode({'error': 'approval_target_guard_unavailable'});
    }
    final original = _originalRequest(request);
    if (original == null) {
      return jsonEncode({'error': 'approval_target_binding_unavailable'});
    }
    final guard = delegate as AiToolApprovalTargetGuard;
    return guard.executeApproved(original, arguments);
  }

  mcp.McpTool _toMcpTool(AiTool tool) {
    return mcp.McpTool(
      name: tool.name,
      description: tool.description,
      properties: tool.properties,
      required: tool.required,
      executionMode: _toExecutionMode(tool.executionMode),
      capabilities: {
        for (final capability in tool.effectiveCapabilities)
          _toCapability(capability),
      },
      requiresServerSelection: tool.requiresServerSelection,
      requiresWebViewSession: tool.requiresWebViewSession,
    );
  }

  mcp.McpToolExecutionMode _toExecutionMode(AiToolExecutionMode mode) {
    return switch (mode) {
      AiToolExecutionMode.readOnly => mcp.McpToolExecutionMode.readOnly,
      AiToolExecutionMode.planOnly => mcp.McpToolExecutionMode.planOnly,
      AiToolExecutionMode.executionOnly =>
        mcp.McpToolExecutionMode.executionOnly,
      AiToolExecutionMode.stateChanging =>
        mcp.McpToolExecutionMode.stateChanging,
      AiToolExecutionMode.planControl => mcp.McpToolExecutionMode.planControl,
    };
  }

  mcp.McpToolCapability _toCapability(AiToolCapability capability) {
    return switch (capability) {
      AiToolCapability.client => mcp.McpToolCapability.client,
      AiToolCapability.server => mcp.McpToolCapability.server,
      AiToolCapability.ssh => mcp.McpToolCapability.ssh,
      AiToolCapability.sftp => mcp.McpToolCapability.sftp,
      AiToolCapability.monitor => mcp.McpToolCapability.monitor,
      AiToolCapability.web => mcp.McpToolCapability.web,
      AiToolCapability.logs => mcp.McpToolCapability.logs,
      AiToolCapability.settings => mcp.McpToolCapability.settings,
      AiToolCapability.diagnostics => mcp.McpToolCapability.diagnostics,
      AiToolCapability.planning => mcp.McpToolCapability.planning,
      AiToolCapability.playbook => mcp.McpToolCapability.playbook,
    };
  }

  mcp.McpApprovalRequest _toMcpApprovalRequest(AiToolApprovalRequest request) =>
      mcp.McpApprovalRequest(
        toolName: request.toolName,
        approvalType: request.approvalType,
        connectionId: request.connectionId,
        connectionName: request.connectionName,
        command: request.command,
        reason: request.reason,
        targetPath: request.targetPath,
        byteLength: request.byteLength,
        contentPreview: request.contentPreview,
        destructive: request.destructive,
        opaqueHandle: request,
      );

  AiToolApprovalRequest? _originalRequest(mcp.McpApprovalRequest request) {
    final original = request.opaqueHandle;
    return original is AiToolApprovalRequest ? original : null;
  }
}
