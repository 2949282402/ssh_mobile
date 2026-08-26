// MCP 控制台局部国际化文案。
//
// 原文案属于 AppSettings 的大字典；迁移后只保留 MCP 页面实际使用的键，
// 避免 Feature 反向依赖 App Shell 的设置与字符串实现。

final class McpStrings {
  const McpStrings(this.isEnglish);

  final bool isEnglish;

  String get cancel => isEnglish ? 'Cancel' : '取消';
  String get close => isEnglish ? 'Close' : '关闭';
  String get clear => isEnglish ? 'Clear' : '清空';
  String get reject => isEnglish ? 'Reject' : '拒绝';
  String get loadingConsole =>
      isEnglish ? 'Loading MCP console...' : '正在加载 MCP 控制台...';

  String get mcpServer => 'MCP Server';
  String get mcpServerHint => isEnglish
      ? 'Streamable HTTP server for CLI agent integrations.'
      : '供 Codex、Claude Code、Gemini CLI 使用的本地 Streamable HTTP 端点。';
  String get mcpHost => isEnglish ? 'Host' : '主机';
  String get mcpPort => isEnglish ? 'Port' : '端口';
  String get mcpServerToken => 'Token';
  String get mcpClientConfiguration =>
      isEnglish ? 'Client configuration' : '客户端配置';
  String get mcpCheckPort => isEnglish ? 'Check port' : '检查端口';
  String get mcpRestart => isEnglish ? 'Restart Server' : '重启 MCP Server';
  String get mcpRegenerateToken =>
      isEnglish ? 'Regenerate Token' : '重新生成 Token';
  String get mcpCopyCodex => isEnglish ? 'Copy Codex' : '复制 Codex 配置';
  String get mcpCopyClaude => isEnglish ? 'Copy Claude' : '复制 Claude 命令';
  String get mcpCopyGemini => isEnglish ? 'Copy Gemini' : '复制 Gemini 配置';
  String get mcpApprovalMode =>
      isEnglish ? 'External MCP approval mode' : '外部 MCP 审核模式';
  String get mcpReviewConfiguredTools =>
      isEnglish ? 'Dangerous operations require review' : '危险操作二次审核';
  String get mcpReviewConfiguredToolsHint => isEnglish
      ? 'Tools selected in the Local MCP Console enter the SSH Mobile approval queue when a call is risky.'
      : '在本地 MCP 控制台选中的 Tool，在本次调用确实有风险时进入 SSH Mobile 审批队列。';
  String get mcpTrustedAgent =>
      isEnglish ? 'Full access (trusted Agent)' : '完整权限（信任 Agent）';
  String get mcpTrustedAgentHint => isEnglish
      ? 'Selected exposed tools execute without interactive SSH Mobile review.'
      : '在本地 MCP 控制台选中的对外 Tool 不再进入 SSH Mobile 的交互式二次审核。';
  String get mcpTrustedAgentActive =>
      isEnglish ? 'Automatic execution enabled' : '已启用自动执行';
  String get mcpTrustedAgentActiveHint => isEnglish
      ? 'This setting applies immediately to new external MCP calls.'
      : '此设置立即作用于新的外部 MCP 调用。';
  String get mcpTrustedAgentSafetyBoundary => isEnglish
      ? 'Loopback authentication, target binding, input validation, secret filtering, blocked paths, and destructive command restrictions remain active.'
      : '回环监听、身份验证、目标绑定、参数校验、秘密过滤、敏感路径和危险命令限制仍然有效。';
  String get mcpSecondaryReviewTools =>
      isEnglish ? 'Tools requiring secondary review' : '需要二次审核的 Tools';
  String get mcpToolPolicyConsoleTitle => isEnglish
      ? 'Configure Tool policy in Local MCP Console'
      : '在本地 MCP 控制台配置 Tool 策略';
  String get mcpToolPolicyConsoleHint => isEnglish
      ? 'External exposure and secondary review are configured per Tool there.'
      : 'Tool 的对外暴露和二次审核统一在本地 MCP 控制台逐项配置。';
  String get mcpToolPolicyConsoleDetails => isEnglish
      ? 'Hard hidden and blocked rules remain enforced and cannot be enabled here.'
      : '永久隐藏和阻断规则仍然有效，不能通过控制台绕过。';
  String get mcpToolPolicyTitle =>
      isEnglish ? 'Tool exposure and review' : 'Tool 暴露与二次审核';
  String get mcpToolPolicyHint => isEnglish
      ? 'Exposure is shared across modes; review settings apply only in review mode.'
      : '两种模式共用对外暴露配置；二次审核设置仅在审核模式生效。';
  String get mcpExposeExternally => isEnglish ? 'Expose externally' : '对外暴露';
  String get mcpSecondaryReview => isEnglish ? 'Secondary review' : '二次审核';
  String get mcpReviewRequired =>
      isEnglish ? 'Review configuration required' : '需先配置二次审核';
  String get mcpExecutable => isEnglish ? 'Executable' : '可直接执行';
  String get mcpNoConfigurableTools =>
      isEnglish ? 'No configurable tools available.' : '当前没有可配置的 Tool。';
  String get mcpNotExposed => isEnglish ? 'Not exposed' : '未对外暴露';
  String get mcpHidden => isEnglish ? 'Hidden' : '隐藏';
  String get mcpBlocked => isEnglish ? 'Blocked' : '已阻断';
  String get mcpHardBoundaryHint => isEnglish
      ? 'This Tool is hidden or blocked by a hard security rule and cannot be enabled.'
      : '该 Tool 由硬安全规则隐藏或阻断，不能通过配置启用。';
  String get mcpTrustedAgentWarningTitle => isEnglish
      ? 'Enable full access for external Agents?'
      : '启用外部 Agent 完整权限？';
  String get mcpTrustedAgentWarningBody => isEnglish
      ? 'External Agents may execute write and deletion tools continuously. Codex, Claude Code, or another MCP client may enable automatic approval. SSH Mobile still blocks hidden tools, sensitive paths, invalid targets, and other hard-prohibited operations. Existing pending approvals will be rejected. This takes effect immediately.'
      : '外部 Agent 可能连续执行写入和删除类 Tool。Codex、Claude Code 或其他 MCP Client 可能启用自动批准。SSH Mobile 仍会阻止隐藏 Tool、敏感路径、无效目标和其他硬性禁止操作。当前待审批请求会被拒绝。本设置立即生效。';
  String get mcpEnableTrustedAgent =>
      isEnglish ? 'Enable full access' : '启用完整权限';
  String get mcpPortAvailable => isEnglish ? 'Port is available' : '端口可用';
  String get mcpPortOccupied =>
      isEnglish ? 'Port in use. Choose another.' : '端口已被占用，请选择其他端口。';
  String get mcpPortInvalidMessage => isEnglish
      ? 'Port must be between 1024 and 65535.'
      : '端口必须在 1024 到 65535 之间。';
  String get mcpPortRestartNeeded =>
      isEnglish ? 'Port changes require restart.' : '端口变更需要重启 MCP Server。';
  String get mcpStopped => isEnglish ? 'MCP Server stopped' : 'MCP Server 已停止';
  String get mcpCheckingPort => isEnglish ? 'Checking port...' : '正在检查端口...';
  String get mcpStarting =>
      isEnglish ? 'Starting MCP Server...' : '正在启动 MCP Server...';
  String mcpRunningAt(String url) => isEnglish ? 'Running at $url' : '运行中：$url';
  String get mcpFailed => isEnglish ? 'MCP Server failed' : 'MCP Server 启动失败';
  String get mcpTokenRegenerated =>
      isEnglish ? 'MCP token regenerated' : 'MCP Token 已重新生成';
  String get mcpCopied => isEnglish ? 'MCP config copied' : 'MCP 配置已复制';
  String get openMcpConsole => isEnglish ? 'Open console' : '打开控制台';
  String get openMcpSettings => isEnglish ? 'MCP settings' : 'MCP 设置';

  String get mcpApprovalQueueTitle => isEnglish ? 'MCP approvals' : 'MCP 审批队列';
  String get mcpApprovalQueueSubtitle => isEnglish
      ? 'Review external MCP actions before execution'
      : '执行外部 MCP 操作前进行审核';
  String get mcpNoPendingApprovals =>
      isEnglish ? 'No pending approvals' : '暂无待审批操作';
  String get mcpApprovalQueueEmptyMessage => isEnglish
      ? 'Write-capable MCP calls will appear here before they run.'
      : '需要写入或改变状态的 MCP 请求会在执行前显示在这里。';
  String get mcpApprovalTarget => isEnglish ? 'Target' : '目标';
  String get mcpApprovalReason => isEnglish ? 'Reason' : '原因';
  String get mcpApprovalRequested => isEnglish ? 'Requested' : '请求时间';
  String get mcpApprovalPath => isEnglish ? 'Path' : '路径';
  String get mcpApprovalBytes => isEnglish ? 'Bytes' : '字节';
  String get mcpApprovalCommand => isEnglish ? 'Command' : '命令';
  String get mcpApprovalPreview => isEnglish ? 'Preview' : '预览';
  String get mcpApprovalApprove => isEnglish ? 'Approve' : '批准';
  String get mcpApprovalExecuting => isEnglish ? 'Executing…' : '执行中…';
  String get mcpApprovalWaiting => isEnglish ? 'Waiting for review' : '等待审核';

  String get mcpRecentActivity => isEnglish ? 'Recent activity' : '最近活动';
  String get mcpActivitySubtitle =>
      isEnglish ? 'Redacted MCP server activity' : '已脱敏的 MCP Server 活动记录';
  String get mcpActivityAll => isEnglish ? 'All' : '全部';
  String get mcpActivityClear => isEnglish ? 'Clear activity' : '清空活动';
  String get mcpActivityEmpty =>
      isEnglish ? 'No activity recorded.' : '暂无活动记录。';
  String get mcpActivityClearTitle =>
      isEnglish ? 'Clear MCP activity?' : '清空 MCP 活动记录？';
  String get mcpActivityClearMessage => isEnglish
      ? 'This only removes local, redacted activity metadata.'
      : '这只会移除本机保存的脱敏活动元数据。';
  String get mcpActivitySuccess => isEnglish ? 'Success' : '成功';
  String get mcpActivityDenied => isEnglish ? 'Denied' : '已拒绝';
  String get mcpActivityFailed => isEnglish ? 'Failed' : '失败';
}
