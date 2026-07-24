part of '../home_screen.dart';

extension _HomeSettingsStrings on AppStrings {
  String get appearance => language == AppLanguage.en ? 'Appearance' : '外观';
  String get toolsAndAutomation =>
      language == AppLanguage.en ? 'Tools & Automation' : '工具与自动化';
  String get aiSkillsHint => language == AppLanguage.en
      ? 'Manage custom AI prompts, workflows, and references'
      : '管理自定义 AI 提示词、工作流及规则说明';
  String get mcpServer =>
      language == AppLanguage.en ? 'MCP Server' : 'MCP Server';
  String get mcpServerHint => language == AppLanguage.en
      ? 'Streamable HTTP server for CLI agent integrations.'
      : '供 Codex、Claude Code、Gemini CLI 使用的本地 Streamable HTTP 端点。';
  String get mcpHost => language == AppLanguage.en ? 'Host' : '主机';
  String get mcpPort => language == AppLanguage.en ? 'Port' : '端口';
  String get mcpCheckPort => language == AppLanguage.en ? 'Check port' : '检查端口';
  String get mcpRestart =>
      language == AppLanguage.en ? 'Restart Server' : '重启 MCP Server';
  String get mcpRegenerateToken =>
      language == AppLanguage.en ? 'Regenerate Token' : '重新生成 Token';
  String get mcpCopyCodex =>
      language == AppLanguage.en ? 'Copy Codex' : '复制 Codex 配置';
  String get mcpCopyClaude =>
      language == AppLanguage.en ? 'Copy Claude' : '复制 Claude 命令';
  String get mcpCopyGemini =>
      language == AppLanguage.en ? 'Copy Gemini' : '复制 Gemini 配置';
  String get mcpAllowWriteTools =>
      language == AppLanguage.en ? 'Expose Write Tools' : '暴露写入工具';
  String get mcpAllowWriteToolsHint => language == AppLanguage.en
      ? 'Off by default. Exposed write tools still require approval.'
      : '默认关闭。暴露后，所有写入工具仍需审批。';
  String get mcpRequireApproval =>
      language == AppLanguage.en ? 'Write Approval Required' : '写入操作强制审批';
  String get mcpRequireApprovalHint => language == AppLanguage.en
      ? 'Cannot be disabled until an in-app approval queue is available.'
      : '应用内审批队列可用前不可关闭。';
  String get mcpPortAvailable =>
      language == AppLanguage.en ? 'Port is available' : '端口可用';
  String get mcpPortOccupied => language == AppLanguage.en
      ? 'Port in use. Choose another.'
      : '端口已被占用，请选择其他端口。';
  String get mcpPortInvalidMessage => language == AppLanguage.en
      ? 'Port must be between 1024 and 65535.'
      : '端口必须在 1024 到 65535 之间。';
  String get mcpPortRestartNeeded => language == AppLanguage.en
      ? 'Port changes require restart.'
      : '端口变更需要重启 MCP Server。';
  String get mcpStopped =>
      language == AppLanguage.en ? 'MCP Server stopped' : 'MCP Server 已停止';
  String get mcpCheckingPort =>
      language == AppLanguage.en ? 'Checking port...' : '正在检查端口...';
  String get mcpStarting => language == AppLanguage.en
      ? 'Starting MCP Server...'
      : '正在启动 MCP Server...';
  String mcpRunningAt(String url) =>
      language == AppLanguage.en ? 'Running at $url' : '运行中：$url';
  String get mcpFailed =>
      language == AppLanguage.en ? 'MCP Server failed' : 'MCP Server 启动失败';
  String get mcpTokenRegenerated =>
      language == AppLanguage.en ? 'MCP token regenerated' : 'MCP Token 已重新生成';
  String get mcpCopied =>
      language == AppLanguage.en ? 'MCP config copied' : 'MCP 配置已复制';
  String get security => language == AppLanguage.en ? 'Security' : '安全';
  String get credentialCache =>
      language == AppLanguage.en ? 'Cache SSH credentials' : '缓存 SSH 凭证到内存';
  String get credentialCacheHint => language == AppLanguage.en
      ? 'Cache credentials this session to reduce keychain prompts.'
      : '在本次会话内缓存密码、私钥和 API Key，可减少重复的密钥链弹窗。';
  String get credentialCacheTimeout =>
      language == AppLanguage.en ? 'Cache timeout' : '缓存时长';
  String get notificationServerNames => language == AppLanguage.en
      ? 'Show server names in background notifications'
      : '后台通知显示服务器名';
  String get notificationServerNamesHint => language == AppLanguage.en
      ? 'Off by default to prevent server exposure on lock screen.'
      : '默认关闭。保持关闭可避免在锁屏通知中暴露服务器名称。';
  String get dataBackup => language == AppLanguage.en ? 'Data backup' : '数据备份';
  String get sftpLimits =>
      language == AppLanguage.en ? 'SFTP file limits' : 'SFTP 文件限制';
  String get sftpLimitsHint => language == AppLanguage.en
      ? 'Client limits for file download, preview, and edit.'
      : '用于客户端下载、预览和编辑的内存保护限制。';
  String get sftpDownloadLimit =>
      language == AppLanguage.en ? 'Download Limit' : '下载限制';
  String get sftpTextPreviewLimit =>
      language == AppLanguage.en ? 'Text Preview' : '文本预览限制';
  String get sftpRichPreviewLimit =>
      language == AppLanguage.en ? 'Image/PDF Preview' : '图片/PDF 预览限制';
  String get sftpEditLimit =>
      language == AppLanguage.en ? 'Text Edit' : '文本编辑限制';
  String get sftpLimitDialogHint => language == AppLanguage.en
      ? 'Enter a size in MB. Decimal values are allowed.'
      : '请输入 MB 单位大小，支持小数。';
  String get sftpLimitInvalid => language == AppLanguage.en
      ? 'Enter a value greater than 0.'
      : '请输入大于 0 的数值。';
  String sftpLimitRange(String min, String max) => language == AppLanguage.en
      ? 'Allowed range: $min - $max'
      : '允许范围：$min - $max';
  String get exportAppData =>
      language == AppLanguage.en ? 'Export app data' : '导出应用数据';
  String get importAppData =>
      language == AppLanguage.en ? 'Import app data' : '导入应用数据';
  String get exportComplete =>
      language == AppLanguage.en ? 'Export complete' : '导出完成';
  String get importComplete =>
      language == AppLanguage.en ? 'Import complete' : '导入完成';
  String get importAction => language == AppLanguage.en ? 'Import' : '导入';
  String get importAppDataWarning => language == AppLanguage.en
      ? 'Importing replaces servers, window history, AI chats, settings, and skills. Keys must be reconfigured. Continue?'
      : '导入会替换当前设备上的服务器、窗口历史、AI 聊天、AI 设置和自定义 Skills。密码、私钥和 API Key 需要重新配置。是否继续？';
  String get backupContainsSecrets => language == AppLanguage.en
      ? 'Passwords, keys, and API tokens are not exported. Reconfigure after import.'
      : '密码、私钥和 API Key 不会导出，导入后需要重新配置。';
  String exportFailed(Object error) =>
      language == AppLanguage.en ? 'Export failed: $error' : '导出失败：$error';
  String importFailed(Object error) =>
      language == AppLanguage.en ? 'Import failed: $error' : '导入失败：$error';
  String get developerMode =>
      language == AppLanguage.en ? 'Developer Mode' : '开发者模式';
  String get developerModeHint => language == AppLanguage.en
      ? 'Show performance metrics and debugging information.'
      : '显示性能指标和调试信息。';
  String get developerPanel =>
      language == AppLanguage.en ? 'Developer Panel' : '开发者面板';
  String get developerPanelFloating => language == AppLanguage.en
      ? 'Show as floating ball'
      : '浮窗显示开发者面板';
  String get developerPanelFloatingHint => language == AppLanguage.en
      ? 'View the developer panel as a floating ball on every page.'
      : '在各页面以悬浮球形式查看开发者面板。';
}
