// MCP Feature 的跨边界契约。
//
// 本文件只描述 MCP 需要的工具、设置、日志和审批能力，不引用 AI Feature
// 或 App Shell 的具体实现。这样外部 MCP 请求仍由本模块执行安全检查，具体
// 工具执行则由 AppRuntime 通过适配器注入。

import 'package:flutter/foundation.dart';

import 'mcp_server_settings.dart';

/// MCP 工具的执行语义；策略层据此判断是否允许无交互执行。
enum McpToolExecutionMode {
  readOnly,
  planOnly,
  executionOnly,
  stateChanging,
  planControl,
}

/// 工具能力标签，用于生成 MCP 的 open-world 元数据。
enum McpToolCapability {
  client,
  server,
  ssh,
  sftp,
  monitor,
  web,
  logs,
  settings,
  diagnostics,
  planning,
  playbook,
}

/// MCP 边界可见的工具描述。
final class McpTool {
  const McpTool({
    required this.name,
    required this.description,
    required this.properties,
    this.required = const [],
    this.executionMode = McpToolExecutionMode.readOnly,
    this.capabilities = const {},
    this.requiresServerSelection = false,
    this.requiresWebViewSession = false,
  });

  final String name;
  final String description;
  final Map<String, dynamic> properties;
  final List<String> required;
  final McpToolExecutionMode executionMode;
  final Set<McpToolCapability> capabilities;
  final bool requiresServerSelection;
  final bool requiresWebViewSession;

  /// 返回显式能力或按工具名前缀推断的能力，避免策略重复维护工具清单。
  Set<McpToolCapability> get effectiveCapabilities {
    if (capabilities.isNotEmpty) return capabilities;
    if (name == 'web_search' || name.startsWith('client_webview_')) {
      return const {McpToolCapability.web, McpToolCapability.client};
    }
    if (name.startsWith('client_task_') || name == 'client_set_plan_mode') {
      return const {McpToolCapability.planning, McpToolCapability.client};
    }
    if (name.startsWith('client_')) {
      if (name.contains('log')) {
        return const {McpToolCapability.client, McpToolCapability.logs};
      }
      if (name.contains('setting') || name.contains('permission')) {
        return const {McpToolCapability.client, McpToolCapability.settings};
      }
      return const {McpToolCapability.client};
    }
    if (name.startsWith('ssh_')) {
      return const {McpToolCapability.ssh, McpToolCapability.server};
    }
    if (name.startsWith('sftp_')) {
      return const {McpToolCapability.sftp, McpToolCapability.server};
    }
    if (name.startsWith('monitor_')) {
      return const {McpToolCapability.monitor, McpToolCapability.diagnostics};
    }
    if (name.contains('playbook')) {
      return const {McpToolCapability.playbook};
    }
    if (name.contains('server') ||
        name.contains('ops') ||
        name == 'run_command') {
      return const {McpToolCapability.server, McpToolCapability.diagnostics};
    }
    return const {};
  }

  /// 判断工具是否需要当前聊天绑定的 WebView 会话。
  bool get needsWebViewSession =>
      requiresWebViewSession ||
      name == 'web_search' ||
      name.startsWith('client_webview_');
}

/// 外部 MCP 调用在进入审批队列前形成的脱敏预览。
///
/// [opaqueHandle] 只允许 App Shell 在内存中保存原始审批绑定，禁止序列化、
/// 日志记录或展示给 UI；它用于把用户批准的目标绑定准确交回底层执行器。
final class McpApprovalRequest {
  const McpApprovalRequest({
    required this.toolName,
    required this.approvalType,
    required this.connectionId,
    required this.connectionName,
    required this.command,
    required this.reason,
    this.targetPath,
    this.byteLength,
    this.contentPreview,
    this.destructive = false,
    this.opaqueHandle,
  });

  final String toolName;
  final String approvalType;
  final String connectionId;
  final String connectionName;
  final String command;
  final String reason;
  final String? targetPath;
  final int? byteLength;
  final String? contentPreview;
  final bool destructive;
  final Object? opaqueHandle;
}

/// MCP 工具执行器；实际工具图由 App Shell 延迟提供。
abstract interface class McpToolExecutor {
  Future<List<McpTool>> tools();

  Future<List<Map<String, dynamic>>> toolDefinitions();

  Future<McpApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  );

  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  });
}

/// App Shell 提供的工具图工厂；每次创建都可按需构造当前 AI 运行时。
abstract interface class McpToolRuntimePort {
  McpToolExecutor createToolExecutor();
}

/// 可选的聊天会话状态，用于隐藏必须绑定 WebView 的工具。
abstract interface class McpChatSessionState {
  bool get hasChatSession;
}

/// 将审批绑定校验和批准执行保持在执行层，而不是 UI 层。
abstract interface class McpApprovalTargetGuard {
  Future<bool> isApprovalTargetCurrent(McpApprovalRequest request);

  Future<String> executeApproved(
    McpApprovalRequest request,
    Map<String, dynamic> arguments,
  );
}

/// App Shell 可为 MCP 提供专用的审批请求构造逻辑。
abstract interface class McpApprovalRequestProvider {
  Future<McpApprovalRequest?> mcpApprovalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  );
}

/// MCP 模块读取和修改外部服务器设置所需的最小契约。
abstract interface class McpSettingsPort implements Listenable {
  McpServerSettings get mcpSettings;

  bool get isEnglish;

  Future<void> ensureCoreLoaded();

  Future<String> ensureMcpServerToken();

  Future<void> setMcpServerEnabled(bool value);

  Future<void> setMcpServerPort(int port);

  Future<void> setMcpApprovalMode(McpApprovalMode mode);

  Future<void> setMcpToolExposure(
    String toolName,
    bool exposed, {
    required Set<String> availableToolNames,
  });

  Future<void> setMcpToolSecondaryReview(String toolName, bool enabled);

  Future<void> setMcpSecondaryReviewTools(Set<String> tools);

  Future<String> regenerateMcpServerToken();
}

/// MCP 持久化和网络层只依赖这组结构化日志操作。
abstract interface class McpLoggerPort {
  void info(String message, {String? details});

  void warning(String message, {String? details});

  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  });
}
