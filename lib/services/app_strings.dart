part of 'app_settings.dart';

class AppStrings {
  final AppLanguage language;

  const AppStrings(this.language);

  bool get _en => language == AppLanguage.en;

  String get appTitle => 'SSH Mobile';
  String get switchToChinese => '中文';
  String get switchToEnglish => 'EN';
  String get languageLabel => _en ? 'Language' : '语言';
  String get currentLanguageName => _en ? 'English' : '中文';
  String get defaultOption => _en ? 'Default' : '默认';
  String get switchToLightMode => _en ? 'Switch to light mode' : '切换到浅色主题';
  String get switchToDarkMode => _en ? 'Switch to dark mode' : '切换到深色主题';
  String get oledDarkMode => _en ? 'OLED Black Mode' : 'OLED 纯黑模式';
  String get colorPalette => _en ? 'App Color' : '应用配色';
  String get paletteMonochrome => _en ? 'Monochrome' : '黑白灰';
  String get paletteIndigo => _en ? 'Indigo' : '靛蓝';
  String get paletteOcean => _en ? 'Ocean' : '海洋蓝';
  String get paletteEmerald => _en ? 'Emerald' : '翡翠绿';
  String get paletteRose => _en ? 'Rose' : '玫瑰红';
  String get paletteAmber => _en ? 'Amber' : '琥珀橙';
  String get terminalTheme => _en ? 'Terminal Theme' : '终端配色方案';
  String get customTerminalFont => _en ? 'Custom Terminal Font' : '自定义终端字体';
  String get customTerminalFontHint => _en
      ? 'System monospaced font family, e.g. Fira Code'
      : '系统已安装的等宽字体名称，如 Fira Code';
  String get serverListLayout => _en ? 'Server List Layout' : '服务器列表布局';
  String get layoutList => _en ? 'List' : '列表';
  String get layoutGrid => _en ? 'Grid' : '网格';

  String get servers => _en ? 'Servers' : '服务器';
  String get server => _en ? 'Server' : '服务器';
  String get windows => _en ? 'Windows' : '窗口';
  String get window => _en ? 'Window' : '窗口';
  String get active => _en ? 'Active' : '活跃';
  String get performanceMonitor => _en ? 'Monitor' : '监控';
  String get monitor => performanceMonitor;
  String get admin => systemAdmin;
  String get logs => _en ? 'Logs' : '日志';
  String get cancel => _en ? 'Cancel' : '取消';
  String get create => _en ? 'Create' : '创建';
  String get save => _en ? 'Save' : '保存';
  String get saving => _en ? 'Saving...' : '保存中...';
  String get add => _en ? 'Add' : '添加';
  String get edit => _en ? 'Edit' : '编辑';
  String get delete => _en ? 'Delete' : '删除';
  String get close => _en ? 'Close' : '关闭';
  String get copy => _en ? 'Copy' : '复制';
  String get remove => _en ? 'Remove' : '删除';
  String get unknown => _en ? 'Unknown' : '未知';

  String get addConnection => _en ? 'Add connection' : '添加连接';
  String get verifyAndSave => _en ? 'Verify & Save' : '验证并保存';
  String get deleteRemoteEntryConfirmPrompt =>
      _en ? 'Type the exact name to confirm:' : '请输入完整名称确认：';
  String get deleteRemoteEntryConfirmLabel => _en ? 'Entry name' : '文件或目录名称';
  String get deleteRemoteEntryConfirmMismatch =>
      _en ? 'Name does not match.' : '名称不匹配。';
  String uploadFileTooLarge(String limit) =>
      _en ? 'File is larger than $limit' : '文件大小超过了 $limit';
  String get uploadFileNoAccess =>
      _en ? 'Unable to access file path on this platform.' : '此平台无法访问文件路径。';
  String get uploadCancelled => _en ? 'Upload cancelled' : '上传已取消';
  String downloadFileTooLarge(String limit) =>
      _en ? 'File is larger than $limit' : '文件大小超过了 $limit';
  String get downloadCancelled => _en ? 'Download cancelled' : '下载已取消';
  String uploadingFile(String name) => _en ? 'Uploading $name' : '正在上传 $name';
  String downloadingFile(String name) =>
      _en ? 'Downloading $name' : '正在下载 $name';
  String get editConnection => _en ? 'Edit connection' : '编辑连接';
  String get noConnections => _en ? 'No saved servers yet' : '还没有保存的服务器';
  String get addHint => _en
      ? 'Add a connection to start a secure SSH session.'
      : '添加连接，开始安全的 SSH 会话。';
  String get reorderServer => _en ? 'Reorder server' : '调整服务器顺序';
  String get noMonitoringData => _en ? 'No monitoring data' : '暂无监控数据';
  String get newWindow => _en ? 'New window' : '新建窗口';
  String connectingTo(String name) =>
      _en ? 'Connecting to $name' : '正在连接 $name';
  String get establishingConnection =>
      _en ? 'Establishing SSH connection...' : '正在建立 SSH 连接...';
  String get deleteConnectionTitle => _en ? 'Delete connection' : '删除连接';
  String deleteConnectionContent(String name) => _en
      ? 'Delete "$name"? Password and private key will also be removed.'
      : '确定删除 "$name" 吗？\n密码和私钥也会一并清除。';
  String get deleteConnectionConfirm => _en ? 'Delete' : '删除';

  String get connectionInfo => _en ? 'Connection' : '连接信息';
  String get basicInfo => _en ? 'Basic info' : '基本信息';
  String get authMethod => _en ? 'Authentication' : '认证方式';
  String get jumpHostOptional => _en ? 'Jump host (optional)' : '跳板机（可选）';
  String get advancedOptions => _en ? 'Advanced options' : '高级选项';
  String get connectionName => _en ? 'Connection name' : '连接名称';
  String get connectionNameHint => _en ? 'My server' : '我的服务器';
  String get enterConnectionName => _en ? 'Enter connection name' : '请输入连接名称';
  String get hostAddress => _en ? 'Host address' : '主机地址';
  String get hostAddressHint =>
      _en ? '192.168.1.1 or example.com' : '192.168.1.1 或 example.com';
  String get enterHostAddress => _en ? 'Enter host address' : '请输入主机地址';
  String get port => _en ? 'Port' : '端口';
  String get invalidPort => _en ? 'Invalid port' : '无效端口';
  String get username => _en ? 'Username' : '用户名';
  String get enterUsername => _en ? 'Enter username' : '请输入用户名';
  String get password => _en ? 'Password' : '密码';
  String get privateKey => _en ? 'Private key' : '私钥';
  String get privateKeyPassword => _en ? 'Private key + password' : '私钥+密码';
  String get passwordHint => _en ? 'Enter SSH password' : '输入 SSH 密码';
  String get showPassword => _en ? 'Show password' : '显示密码';
  String get hidePassword => _en ? 'Hide password' : '隐藏密码';
  String get passwordRequired =>
      _en ? 'Password authentication requires a password' : '密码认证需要输入密码';
  String get sshPrivateKey => _en ? 'SSH private key' : 'SSH 私钥';
  String get privateKeyRequired => _en
      ? 'Private key authentication requires a private key'
      : '私钥认证需要输入私钥内容';
  String get jumpHost => _en ? 'Jump host address' : '跳板机地址';
  String get jumpHostHint =>
      _en ? 'Optional, leave empty for direct connection' : '可选，留空则直连';
  String get jumpPort => _en ? 'Jump host port' : '跳板机端口';
  String get jumpUsername => _en ? 'Jump host username' : '跳板机用户名';
  String get optional => _en ? 'Optional' : '可选';
  String get tmuxModeDescription => _en
      ? 'Connect over SSH and automatically enter the tmux session for this window.'
      : '连接 SSH 后自动进入与当前窗口同名的 tmux 会话。';
  String get sshModeDescription =>
      _en ? 'Open a normal interactive SSH shell.' : '打开普通交互式 SSH shell。';
  String get tmuxAutoDeleteMinutes =>
      _en ? 'tmux auto-delete wait time (minutes)' : 'tmux 无连接自动删除等待时间（分钟）';
  String get tmuxAutoDeleteHelp => _en
      ? 'Unit: minutes. If nobody reconnects after disconnecting, the tmux session will be deleted after this time.'
      : '单位：分钟。断开后无人重新连接，超过该时间自动删除 tmux 会话。';
  String get minOneMinute => _en ? 'Minimum 1 minute' : '最少 1 分钟';
  String get max1440Minutes => _en ? 'Maximum 1440 minutes' : '最多 1440 分钟';
  String get keepAliveTitle => _en ? 'Keep connection in background' : '后台保持连接';
  String get keepAliveSubtitle => _en
      ? 'The app uses a background service and keep-alive to keep SSH connected when possible.'
      : '应用会通过后台服务和 keep-alive 尽量维持 SSH 连接。';
  String saveFailed(Object error) =>
      _en ? 'Save failed: $error' : '保存失败: $error';
  String get saveFailedGuidance => _en
      ? 'Please check the host address, port, username, password or private key, then save again.'
      : '请检查主机地址、端口、用户名、密码或私钥后重新保存。';
  String get paste => _en ? 'Paste' : '粘贴';
  String get serverSystem => _en ? 'Server system' : '服务器系统';
  String get windowsTmuxUnavailable => _en
      ? 'Windows OpenSSH uses a normal interactive shell. tmux is only available if you connect to Linux/WSL and tmux is installed.'
      : 'Windows OpenSSH 使用普通交互式 shell。tmux 只适用于 Linux/WSL 且服务器已安装 tmux 的场景。';
  String get windowsMonitoringDescription => _en
      ? 'Windows monitoring uses PowerShell diagnostics; terminal mode stays plain SSH.'
      : 'Windows 监控会使用 PowerShell 诊断命令；终端模式固定为普通 SSH。';
  String get linuxMonitoringDescription => _en
      ? 'Default. Supports normal SSH and SSH + tmux when tmux is installed on the server.'
      : '默认选项。服务器安装 tmux 时支持普通 SSH 和 SSH + tmux。';
  String get saveWillCloseWindowsTitle =>
      _en ? 'Related windows will be closed' : '保存后将关闭相关窗口';
  String saveWillCloseWindowsContent(int count) => _en
      ? 'This config has $count related terminal ${count == 1 ? "window" : "windows"}. After saving, these old windows will close automatically to avoid sending input to an old SSH or tmux session.'
      : '当前配置有关联的 $count 个终端窗口。保存修改后，这些旧窗口会自动关闭，避免继续向旧 SSH 或旧 tmux 会话发送输入。';
  String get saveAndDisconnect => _en ? 'Save and disconnect' : '保存并断开';

  String get newTerminalWindow => _en ? 'New terminal window' : '新建终端窗口';
  String get windowName => _en ? 'Window name' : '窗口名称';
  String get enterWindowName => _en ? 'Enter window name' : '请输入窗口名称';
  String get duplicateWindowName =>
      _en ? 'Window name already exists' : '窗口名称已存在';

  String get terminalWindows => _en ? 'Terminal windows' : '终端窗口';
  String terminalWindowsOverview(int total, int connected, int attention) => _en
      ? '$total ${total == 1 ? "window" : "windows"} · $connected connected${attention > 0 ? " · $attention ${attention == 1 ? "needs" : "need"} attention" : ""}'
      : '$total 个窗口 · $connected 个已连接${attention > 0 ? " · $attention 个需处理" : ""}';
  String terminalWindowsForServer(int total, int connected) => _en
      ? '$total ${total == 1 ? "window" : "windows"} · $connected connected'
      : '$total 个窗口 · $connected 个已连接';
  String selectedWindows(int count) =>
      _en ? '$count selected' : '已选择 $count 个窗口';
  String selectedWindowsHint(int total) => _en
      ? 'Choose actions for the selected windows · $total total'
      : '对选中的窗口执行操作 · 共 $total 个';
  String selectedServers(int count) =>
      _en ? '$count selected' : '已选择 $count 台服务器';
  String viewAllTerminalWindows(int totalCount) => _en
      ? 'View all $totalCount ${totalCount == 1 ? "window" : "windows"}'
      : '查看全部 $totalCount 个窗口';
  String get exitSelection => _en ? 'Exit selection' : '退出选择';
  String get selectAll => _en ? 'Select all' : '全选';
  String get closeSelectedWindows => _en ? 'Close selected windows' : '关闭选中窗口';
  String get connectionHistory => _en ? 'Connection history' : '连接历史';
  String get noOpenWindows => _en ? 'No open terminal windows' : '暂无打开的终端窗口';
  String get openWindowsHint => _en
      ? 'Opened terminals will appear here after connecting to a server.'
      : '连接服务器后，打开的终端会显示在这里。';
  String get enterWindow => _en ? 'Enter window' : '进入窗口';
  String get renameTerminalWindow => _en ? 'Rename window' : '重命名窗口';
  String get windowActions => _en ? 'Window actions' : '窗口操作';
  String get closeWindow => _en ? 'Close window' : '关闭窗口';
  String get sessionMode => _en ? 'Mode' : '模式';
  String get tmuxSession => _en ? 'tmux' : 'tmux';
  String get plainSshSession => _en ? 'SSH' : 'SSH';
  String get createdAt => _en ? 'Created' : '创建';
  String get autoDestroy => _en ? 'Auto delete' : '销毁';
  String get memoryUsage => _en ? 'Memory' : '内存';
  String get notAvailable => _en ? 'N/A' : '不适用';
  String autoDestroyAfter(String duration) =>
      _en ? 'after disconnect: $duration' : '断开后 $duration';
  String autoDestroyAt(String time) => _en ? 'around $time' : '预计 $time';
  String durationMinutes(int minutes) => _en ? '$minutes min' : '$minutes 分钟';
  String durationSeconds(int seconds) => _en ? '$seconds sec' : '$seconds 秒';
  String get connected => _en ? 'Connected' : '已连接';
  String get connecting => _en ? 'Connecting' : '连接中';
  String get connectionError => _en ? 'Connection error' : '连接错误';
  String get disconnected => _en ? 'Disconnected' : '已断开';
  String closeWindowTitle(String name) =>
      _en ? 'Close "$name"?' : '确定关闭 "$name" 吗？';
  String get closeTerminalWindow => _en ? 'Close terminal window' : '关闭终端窗口';
  String get staleTmuxHint => _en
      ? 'If an abnormal tmux session remains on the server, run:'
      : '如果服务器上残留异常 tmux 会话，可手动执行：';
  String get copyCommand => _en ? 'Copy command' : '复制命令';
  String get copiedCleanupCommand =>
      _en ? 'Server cleanup command copied' : '已复制服务器清理命令';
  String closeSelectedContent(int count) => _en
      ? 'Close $count selected terminal ${count == 1 ? "window" : "windows"}?'
      : '确定关闭选中的 $count 个终端窗口吗？';

  String get developerLogs => _en ? 'Developer logs' : '开发日志';
  String get copyFilteredLogs => _en ? 'Copy filtered logs' : '复制当前筛选日志';
  String get clearLogs => _en ? 'Clear logs' : '清空日志';
  String get noLogs => _en ? 'No logs' : '暂无日志';
  String get noLogsForLevel => _en ? 'No logs for this level' : '当前等级暂无日志';
  String get copiedFilteredLogs => _en ? 'Filtered logs copied' : '已复制当前筛选日志';
  String get logsCleared => _en ? 'Logs cleared' : '已清空日志';
  String get copySingleLog => _en ? 'Copy this log' : '复制单条日志';
  String get expandFullLog => _en ? 'Tap to expand full log' : '点击展开完整日志';
  String get copiedSingleLog => _en ? 'Log copied' : '已复制单条日志';

  String get agentTraceTitle => _en ? 'Agent Trace' : 'Agent 执行轨迹';
  String get agentTraceLoadFailedTitle =>
      _en ? 'Failed to load trace' : '无法加载执行轨迹';
  String get agentTraceLoadFailedMessage =>
      _en ? 'Trace data could not be loaded. Try again.' : '无法读取执行轨迹数据，请重试。';
  String get agentTraceOverview => _en ? 'Overview' : '执行概览';
  String agentTraceEventCount(int count) =>
      _en ? '$count events' : '$count 个事件';
  String get agentTraceNoMatchingTitle =>
      _en ? 'No matching events' : '没有匹配的事件';
  String get agentTraceNoMatchingMessage =>
      _en ? 'No events match this filter.' : '当前筛选条件下没有事件。';
  String get agentTraceEmptyTitle =>
      _en ? 'No persisted trace events found for this run.' : '未找到本次运行保存的执行轨迹。';
  String get agentTraceFilterAll => _en ? 'All' : '全部';
  String get agentTraceFilterTools => _en ? 'Tools' : '工具';
  String get agentTraceFilterApprovals => _en ? 'Approvals' : '审批';
  String get agentTraceFilterBlocked => _en ? 'Blocked' : '已拦截';
  String get agentTraceFilterErrors => _en ? 'Errors' : '错误';
  String get agentTraceMetricStatus => _en ? 'Status' : '状态';
  String get agentTraceMetricRun => _en ? 'Run' : '运行 ID';
  String get agentTraceMetricModel => _en ? 'Model' : '模型';
  String get agentTraceMetricHelper => _en ? 'Helper' : '辅助模型';
  String get agentTraceMetricAudit => _en ? 'Audit' : '审计模型';
  String get agentTraceMetricElapsed => _en ? 'Elapsed' : '耗时';
  String get agentTraceMetricPrompt => _en ? 'Prompt' : '输入 Token';
  String get agentTraceMetricCompletion => _en ? 'Completion' : '输出 Token';
  String get agentTraceMetricTotal => _en ? 'Total' : '总 Token';
  String get agentTraceMetricTools => _en ? 'Tools' : '工具调用';
  String get agentTraceMetricCacheHits => _en ? 'Cache hits' : '缓存命中';
  String get agentTraceMetricDedupBlocked => _en ? 'Dedup blocked' : '去重拦截';
  String get agentTraceMetricApprovals => _en ? 'Approvals' : '审批';
  String get agentTraceMetricApproved => _en ? 'Approved' : '已批准';
  String get agentTraceMetricAudits => _en ? 'Audits' : '安全审计';
  String get agentTraceMetricHelperFanout => _en ? 'Helper fanout' : '辅助 Agent';
  String get agentTraceSelectedTools => _en ? 'Selected tools' : '已选工具';
  String get agentTraceMemorySources => _en ? 'Memory sources' : '记忆来源';
  String get agentTraceFinalReason => _en ? 'Final reason' : '最终原因';
  String get agentTraceCopyRaw => _en ? 'Copy raw' : '复制原始内容';
  String get agentTraceCopied => _en ? 'Trace content copied' : '已复制轨迹原始内容';
  String get agentTraceTruncated => _en ? 'truncated' : '已截断';
  String get agentTraceStatusSuccess => _en ? 'Success' : '成功';
  String get agentTraceStatusFailed => _en ? 'Failed' : '失败';
  String get agentRunCompleted => _en ? 'Run completed' : '运行完成';
  String get agentRunNeedsAttention => _en ? 'Run needs attention' : '运行需处理';
  String agentRunTools(int count) =>
      _en ? '$count ${count == 1 ? 'tool' : 'tools'}' : '$count 个工具';
  String agentRunApprovals(int approved, int total) =>
      _en ? '$approved/$total approvals' : '$approved/$total 次审批';
  String agentRunBlocked(int count) => _en ? '$count blocked' : '$count 次阻断';
  String get agentTraceOutcomeCancelled => _en ? 'Cancelled by user' : '用户已取消';
  String get agentTraceOutcomeModelError =>
      _en ? 'Model request failed' : '模型请求失败';
  String get agentTraceOutcomeToolError =>
      _en ? 'Tool execution failed' : '工具执行失败';
  String get agentTraceOutcomeApprovalRejected =>
      _en ? 'User rejected approval' : '用户拒绝审批';
  String get agentTraceOutcomeApprovalUnavailable =>
      _en ? 'Approval UI unavailable' : '审批界面不可用';
  String get agentTraceOutcomeBudgetAuditRejected =>
      _en ? 'Tool budget audit rejected' : '工具预算审计未通过';
  String get agentTraceOutcomeLoopGuardBlocked =>
      _en ? 'Tool loop guard blocked execution' : '工具循环保护已拦截执行';
  String get agentTraceOutcomePlanModeBlocked =>
      _en ? 'Plan Mode blocked execution' : '规划模式已拦截执行';
  String get agentTraceOutcomePlanExecutionBlocked =>
      _en ? 'Plan execution gate blocked execution' : '计划执行门禁已拦截执行';
  String get agentTraceOutcomeAgentLoopStopped =>
      _en ? 'Agent loop stopped' : 'Agent 循环已停止';
  String get agentTraceOutcomeUnknown =>
      _en ? 'Run ended with an unknown result' : '运行结果未知';

  String agentTraceOutcomeLabel(String value) {
    switch (value.trim()) {
      case 'success':
      case 'completed':
        return agentTraceStatusSuccess;
      case 'cancelled':
        return agentTraceOutcomeCancelled;
      case 'modelError':
        return agentTraceOutcomeModelError;
      case 'toolError':
        return agentTraceOutcomeToolError;
      case 'approvalRejected':
        return agentTraceOutcomeApprovalRejected;
      case 'approvalUnavailable':
        return agentTraceOutcomeApprovalUnavailable;
      case 'budgetAuditRejected':
        return agentTraceOutcomeBudgetAuditRejected;
      case 'loopGuardBlocked':
        return agentTraceOutcomeLoopGuardBlocked;
      case 'planModeBlocked':
        return agentTraceOutcomePlanModeBlocked;
      case 'planExecutionBlocked':
        return agentTraceOutcomePlanExecutionBlocked;
      case 'agentLoopStopped':
        return agentTraceOutcomeAgentLoopStopped;
      default:
        return agentTraceOutcomeUnknown;
    }
  }

  String get connectionHistoryHint => _en
      ? 'Review recent terminal sessions, connection results, and tmux cleanup commands.'
      : '查看最近的终端会话、连接结果和 tmux 清理命令。';
  String connectionHistoryCount(int count) => _en
      ? '$count recent ${count == 1 ? "session" : "sessions"}'
      : '最近 $count 条会话记录';
  String get loadingConnectionHistory =>
      _en ? 'Loading connection history…' : '正在加载连接历史…';
  String get connectionHistoryLoadFailed =>
      _en ? 'Could not load connection history' : '无法加载连接历史';
  String get connectionHistoryLoadFailedHint => _en
      ? 'The saved session records are temporarily unavailable. Try again.'
      : '暂时无法读取已保存的会话记录，请重试。';
  String get noConnectionHistory =>
      _en ? 'No connection history yet' : '暂无连接历史';
  String get noConnectionHistoryHint => _en
      ? 'Recently opened terminal sessions will appear here with their connection status.'
      : '最近打开的终端会话及其连接状态会显示在这里。';
  String historyUpdatedAt(String time) => _en ? 'Updated $time' : '更新于 $time';
  String get deleteHistoryRecord => _en ? 'Delete history record' : '删除历史记录';
  String get deleteHistoryRecordFailed => _en
      ? 'Could not delete this history record. Try again.'
      : '无法删除这条历史记录，请重试。';
  String get copyCleanupCommandFailed =>
      _en ? 'Could not copy the cleanup command. Try again.' : '无法复制清理命令，请重试。';

  String get backgroundConnectionSettings => _en ? 'Background access' : '后台运行';
  String get enableBackgroundPermission =>
      _en ? 'Keep SSH connected in the background' : '让 SSH 在后台保持连接';
  String get backgroundPermissionGuide => _en
      ? 'Android may pause background networking to save power. Review these settings so SSH sessions and transfers are less likely to disconnect.'
      : 'Android 可能会为了省电暂停后台网络。请检查以下设置，减少 SSH 会话和文件传输意外断开的情况。';
  String get backgroundChecklistTitle => _en ? 'Recommended settings' : '建议设置';
  String get allowBackgroundActivity =>
      _en ? 'Allow background activity' : '允许后台活动';
  String get allowNotifications => _en ? 'Allow notifications' : '允许发送通知';
  String get relaxBatteryRestrictions =>
      _en ? 'Remove battery restrictions' : '放宽电池限制';
  String get adjustPowerLimit => _en ? 'Review battery settings' : '检查电池设置';
  String get openAppSettings => _en ? 'Open app settings' : '打开应用设置';
  String get settings => _en ? 'Settings' : '设置';
  String get backgroundGuideNote => _en
      ? 'Setting names vary by device. You can continue for now; if restrictions remain, this guide will remind you again next launch.'
      : '不同设备的设置名称可能不同。你可以暂时继续；如果限制仍然存在，下次启动时会再次提醒。';
  String get enterApp => _en ? 'Continue for now' : '暂时继续';
  String get continueToApp => _en ? 'Continue to app' : '进入应用';
  String get powerLimitExempt =>
      _en ? 'Battery restrictions are relaxed' : '已放宽电池限制';
  String get powerLimitUnknown =>
      _en ? 'Battery restriction status needs review' : '需要检查电池限制状态';

  String get sftp => _en ? 'SFTP' : 'SFTP';
  String get sftpServers => _en ? 'SFTP servers' : 'SFTP 服务器';
  String get collapseServerList => _en ? 'Collapse server list' : '折叠服务器列表';
  String get expandServerList => _en ? 'Expand server list' : '展开服务器列表';
  String get sftpEmptyTitle =>
      _en ? 'Select a server for SFTP' : '选择服务器使用 SFTP';
  String get sftpEmptyHint => _en
      ? 'Browse remote files with the same saved SSH connections on desktop and mobile.'
      : '桌面端和移动端使用同一套 SSH 连接来浏览远程文件。';
  String get parentDirectory => _en ? 'Parent directory' : '上级目录';
  String get pathHistory => _en ? 'Path history' : '路径记录';
  String get inputPath => _en ? 'Input path' : '输入路径';
  String get recentPaths => _en ? 'Recent paths' : '最近路径';
  String get favoritePaths => _en ? 'Favorite paths' : '收藏路径';
  String get addFavoritePath => _en ? 'Add favorite path' : '收藏当前路径';
  String get removeFavoritePath => _en ? 'Remove favorite path' : '取消收藏路径';
  String get noRecentPaths => _en ? 'No recent paths' : '暂无最近路径';
  String get noFavoritePaths => _en ? 'No favorite paths' : '暂无收藏路径';
  String get refresh => _en ? 'Refresh' : '刷新';
  String get retry => _en ? 'Retry' : '重试';
  String get disconnect => _en ? 'Disconnect' : '断开连接';
  String get emptyDirectory => _en ? 'This directory is empty' : '当前目录为空';
  String get emptyDirectoryHint =>
      _en ? 'Upload a file or open another remote path.' : '可以上传文件，或打开其他远程路径。';
  String get loadingDirectory =>
      _en ? 'Loading remote directory…' : '正在加载远程目录…';
  String get directoryLoadFailed =>
      _en ? 'Could not load this directory' : '无法加载此目录';
  String get directoryLoadFailedHint => _en
      ? 'Check the SFTP connection and permissions, then try again.'
      : '请检查 SFTP 连接和目录权限，然后重试。';
  String get openPath => _en ? 'Open path' : '打开路径';
  String entryActions(String name) => _en ? 'Actions for $name' : '$name 的操作';
  String get pathHistoryLoadFailed =>
      _en ? 'Could not load path history' : '无法加载路径记录';
  String get pathHistoryLoadFailedHint => _en
      ? 'Recent and favorite paths could not be read. Try again.'
      : '无法读取最近路径和收藏路径，请重试。';
  String get directory => _en ? 'Directory' : '文件夹';
  String get uploadFile => _en ? 'Upload file' : '上传文件';
  String get uploadComplete => _en ? 'Upload complete' : '上传完成';
  String uploadFailed(Object error) =>
      _en ? 'Upload failed: $error' : '上传失败：$error';
  String get viewFile => _en ? 'View file' : '查看文件';
  String get preview => _en ? 'Preview' : '预览';
  String get source => _en ? 'Source' : '源码';
  String get previewMode => _en ? 'Preview mode' : '预览模式';
  String get loadingFilePreview => _en ? 'Loading file preview…' : '正在加载文件预览…';
  String get filePreviewLoadFailed =>
      _en ? 'Could not load this preview' : '无法加载此文件预览';
  String get filePreviewLoadFailedHint => _en
      ? 'Check the SFTP connection and file permissions, then try again.'
      : '请检查 SFTP 连接和文件权限，然后重试。';
  String get filePreviewTooLarge =>
      _en ? 'This file is too large to preview' : '文件过大，无法预览';
  String filePreviewTooLargeHint(int maxBytes) {
    final limit = _fileSizeLimitLabel(maxBytes);
    return _en
        ? 'The safe preview limit is $limit. Return to the file list to download the file instead.'
        : '安全预览上限为 $limit。请返回文件列表，下载后再查看。';
  }

  String get filePreviewResourceLimit =>
      _en ? 'This file is too complex to preview safely' : '文件复杂度过高，无法安全预览';
  String get filePreviewResourceLimitHint => _en
      ? 'Its image dimensions or animation complexity exceed the in-app rendering budget. Download it to inspect with another app.'
      : '图片尺寸或动画复杂度超出应用内渲染预算。请下载后使用其他应用查看。';
  String get closePreview => _en ? 'Back to files' : '返回文件列表';
  String get filePreviewRenderFailed =>
      _en ? 'Could not display this preview' : '无法显示此文件预览';
  String get filePreviewRenderFailedHint => _en
      ? 'The file may be damaged or use an unsupported format. Try loading it again.'
      : '文件可能已损坏或使用了不支持的格式，请重新加载。';
  String get unsupportedPreviewTitle => _en ? 'No preview available' : '暂不支持预览';
  String get unsupportedPreview => _en
      ? 'Preview is not supported for this file type. Download it to open with another app.'
      : '暂不支持预览这种文件类型。可以下载后用其他应用打开。';
  String get htmlPreviewUnavailable =>
      _en ? 'HTML preview is unavailable here' : '当前平台无法渲染 HTML';
  String get htmlPreviewUnavailableHint => _en
      ? 'Rendered HTML preview is available on Android, iOS, and macOS. You can still inspect the source safely.'
      : 'HTML 渲染预览支持 Android、iOS 和 macOS；你仍可安全查看源码。';
  String get pdfPreviewUnavailable =>
      _en ? 'Remote PDF preview is disabled' : '已禁用远程 PDF 预览';
  String get pdfPreviewUnavailableHint => _en
      ? 'To avoid parsing an untrusted document inside the app, download it and open it with a trusted PDF reader.'
      : '为避免在应用内解析不受信任的文档，请下载后使用可信的 PDF 阅读器打开。';
  String get viewSource => _en ? 'View source' : '查看源码';
  String get externalPreviewContentBlocked =>
      _en ? 'External preview content is blocked' : '已阻止预览中的外部内容';
  String get previewKindImage => _en ? 'Image' : '图片';
  String get previewKindPdf => _en ? 'PDF document' : 'PDF 文档';
  String get previewKindMarkdown => _en ? 'Markdown' : 'Markdown';
  String get previewKindHtml => _en ? 'HTML document' : 'HTML 文档';
  String get previewKindText => _en ? 'Text file' : '文本文件';
  String get previewKindUnsupported => _en ? 'File' : '文件';
  String previewFileDetails(String kind, String size) => '$kind · $size';
  String get imagePreviewLabel => _en ? 'Image preview' : '图片预览';
  String get htmlPreviewLabel => _en ? 'HTML preview' : 'HTML 预览';
  String get zoomOut => _en ? 'Zoom out' : '缩小';
  String get zoomIn => _en ? 'Zoom in' : '放大';
  String get resetZoom => _en ? 'Reset zoom' : '重置缩放';
  String imageZoomLevel(int percent) => _en ? 'Zoom $percent%' : '缩放 $percent%';
  String get downloadFile => _en ? 'Download file' : '下载文件';
  String get downloadComplete => _en ? 'Download complete' : '下载完成';
  String downloadFailed(Object error) =>
      _en ? 'Download failed: $error' : '下载失败：$error';
  String get deleteRemoteEntry => _en ? 'Delete remote entry' : '删除远程项目';
  String deleteRemoteEntryContent(String name) =>
      _en ? 'Delete "$name" from the server?' : '从服务器删除 "$name"？';
  String get deleteComplete => _en ? 'Deleted' : '已删除';
  String editRemoteFile(String name) => _en ? 'Edit "$name"' : '编辑 "$name"';
  String get remoteFileContent => _en ? 'Remote file content' : '远程文件内容';
  String get loadingRemoteFile => _en ? 'Loading remote file…' : '正在加载远程文件…';
  String get remoteFileOpenFailed =>
      _en ? 'Could not open this file' : '无法打开此文件';
  String get remoteFileOpenFailedHint => _en
      ? 'Check the SFTP connection and file permissions, then try again.'
      : '请检查 SFTP 连接和文件权限，然后重试。';
  String openEditorFailed(Object error) =>
      _en ? 'Unable to open editor: $error' : '无法打开编辑器：$error';
  String get saveComplete => _en ? 'Saved' : '已保存';
  String get saveRemoteFile => _en ? 'Save remote file' : '保存远程文件';
  String get savingRemoteFile => _en ? 'Saving remote file…' : '正在保存远程文件…';
  String get remoteFileSaveFailed => _en
      ? 'Could not save this file. Check the connection and try again.'
      : '无法保存此文件，请检查连接后重试。';
  String remoteFileTooLarge(int maxBytes) {
    final limit = _fileSizeLimitLabel(maxBytes);
    return _en
        ? 'This file is larger than the $limit edit limit. Reduce its content before saving.'
        : '文件内容超过 $limit 的编辑上限，请缩减内容后再保存。';
  }

  String _fileSizeLimitLabel(int maxBytes) {
    const bytesPerMegabyte = 1024 * 1024;
    return maxBytes >= bytesPerMegabyte
        ? '${(maxBytes / bytesPerMegabyte).toStringAsFixed(maxBytes % bytesPerMegabyte == 0 ? 0 : 1)} MB'
        : '${(maxBytes / 1024).ceil()} KB';
  }

  String get remoteFileNewChangesRemain => _en
      ? 'Earlier changes were saved. New edits are still unsaved.'
      : '先前修改已保存，新的编辑仍未保存。';
  String get remoteFilePath => _en ? 'Remote path' : '远程路径';
  String get remoteFileSaved => _en ? 'All changes saved' : '所有修改均已保存';
  String get remoteFileUnsaved => _en ? 'Unsaved changes' : '有未保存的修改';
  String get editorControls => _en ? 'Editor controls' : '编辑器控制';
  String get editorFontSize => _en ? 'Font size' : '字号';
  String fontSizeValue(int value) => _en ? 'Font size $value' : '字号 $value';
  String get smallerFont => _en ? 'Smaller font' : '缩小字号';
  String get largerFont => _en ? 'Larger font' : '放大字号';
  String get enableLineWrap => _en ? 'Enable line wrap' : '开启自动换行';
  String get disableLineWrap => _en ? 'Disable line wrap' : '关闭自动换行';
  String get discardChangesTitle => _en ? 'Discard changes?' : '放弃修改？';
  String get discardChangesContent => _en
      ? 'This file has unsaved changes. Leave without saving?'
      : '当前文件有未保存的修改，确定不保存并离开吗？';
  String get discard => _en ? 'Discard' : '放弃';

  String connectionFailed(String message) =>
      _en ? 'Connection failed: $message' : '连接失败：$message';
  String tmuxMissingHint(String text) => _en
      ? 'Connection failed: $text\nPlease install tmux manually on the server and try again.'
      : '连接失败：$text\n请先在服务器上手动安装 tmux 后再重试。';

  String get systemAdmin => _en ? 'Admin' : '系统管理';
  String get selectConnectedServer =>
      _en ? 'Select a connected server' : '选择已连接的服务器';
  String get noConnectedServers =>
      _en ? 'No active server connections' : '暂无活跃的服务器连接';
  String get rootRequiredMsg => _en
      ? 'This page requires root privileges. Currently you are not logged in as root.'
      : '此功能需要 root 权限。当前登录账户不是 root 权限。';
  String get nonLinuxMsg => _en
      ? 'Only Linux servers are supported for system admin tools.'
      : '系统管理工具目前仅支持 Linux 服务器。';
  String get activeSessions => _en ? 'Active Sessions' : '活动会话';
  String get userAccounts => _en ? 'User Accounts' : '用户账号';
  String get systemServices => _en ? 'Services' : '系统服务';
  String get listeningPorts => _en ? 'Ports' : '监听端口';
  String get applications => _en ? 'Applications' : '应用/进程';
  String get systemPower => _en ? 'Power' : '系统电源';
  String get lockUser => _en ? 'Lock User' : '禁用账号';
  String get unlockUser => _en ? 'Unlock User' : '启用账号';
  String get changePassword => _en ? 'Change Password' : '修改密码';
  String get viewHomeDir => _en ? 'Home Directory' : '主目录文件';
  String get usageStats => _en ? 'Resource Usage' : '资源占用';
  String get storageUsed => _en ? 'Storage Used' : '存储空间';
  String get memoryUsed => _en ? 'Memory Used' : '内存占用';
  String get activeProcesses => _en ? 'Active Processes' : '活跃进程';
  String get changePasswordTitle => _en ? 'Change Password' : '修改用户密码';
  String get enterNewPassword => _en ? 'Enter new password' : '输入新密码';
  String get passwordChangedSuccess =>
      _en ? 'Password updated successfully' : '密码更新成功';
  String get actionConfirm => _en ? 'Are you sure?' : '确定要执行此操作吗？';
  String get serviceStart => _en ? 'Start' : '启动';
  String get serviceStop => _en ? 'Stop' : '停止';
  String get serviceRestart => _en ? 'Restart' : '重启';
  String get serviceEnable => _en ? 'Enable' : '启用';
  String get serviceDisable => _en ? 'Disable' : '禁用';
  String get rebootServer => _en ? 'Reboot Server' : '重启服务器';
  String get shutdownServer => _en ? 'Shutdown Server' : '关闭服务器';
  String get powerConfirmContent => _en
      ? 'Are you absolutely sure? This will disconnect your terminal session and perform the operation.'
      : '你确定要执行此操作吗？这将断开所有的终端会话并执行此动作。';

  String get createUser => _en ? 'Create User' : '新建账号';
  String get grantSudo => _en ? 'Grant Admin (Sudo)' : '授予管理员权限 (Sudo)';
  String get revokeSudo => _en ? 'Revoke Admin (Sudo)' : '取消管理员权限 (Sudo)';
  String get loginShell => _en ? 'Login Shell' : '登录 Shell';
  String get userCreatedSuccess =>
      _en ? 'User account created successfully' : '用户账号创建成功';
  String get sudoStatus => _en ? 'Privilege Level' : '特权级别';
  String get normalUser => _en ? 'Normal User' : '普通用户';
  String get administrator => _en ? 'Administrator' : '管理员 (sudo/wheel)';

  String get refreshAll => _en ? 'Refresh All' : '刷新全部';
  String get verifyingPrivilege =>
      _en ? 'Connecting and verifying privilege level...' : '正在连接并验证权限级别...';
  String get reconnectAsRootMsg => _en
      ? 'Please reconnect as "root" user or with administrative authorization.'
      : '请以 root 账户重新连接，或确保连接的账户拥有完整的管理员权限。';
  String get systemOmAdmin => _en ? 'System O&M Administration' : '系统运维管理';
  String get adminRootAccess => _en ? 'Root access' : 'Root 权限';
  String get adminSnapshotAccess => _en ? 'Snapshot access' : '快照访问';
  String get adminConnectionFailed => _en ? 'Connection failed' : '连接失败';
  String get adminSelectServer => _en ? 'Select a server' : '选择服务器';
  String get adminLinuxManagementHint => _en
      ? 'Account, session, and power controls require a Linux server with root access.'
      : '账户、会话和电源操作需要已取得 Root 权限的 Linux 服务器。';
  String get adminConnectAsRoot => _en ? 'Connect as Root' : '以 Root 连接';
  String get selectServerToManage => _en
      ? 'Select a server from the list to connect and manage local accounts, services, ports, and power status.'
      : '请从列表中选择服务器进行连接，以管理本地账户、系统服务、监听端口和电源状态。';
  String get backToHome => _en ? 'Back to Home' : '返回主目录';
  String get systemPowerHint => _en
      ? 'Reboot or power down the remote server. Authenticated as root.'
      : '远程服务器系统控制，将直接向系统发送硬件关机或重启指令。';
  String get confirm => _en ? 'Confirm' : '确定';
  String get searchService => _en ? 'Search service...' : '搜索服务...';
  String get searchPort => _en ? 'Search port/service...' : '搜索端口/服务...';
  String get searchSessions => _en ? 'Search sessions...' : '搜索会话...';
  String get searchAccounts => _en ? 'Search accounts...' : '搜索账户...';
  String get killSession => _en ? 'Kill Session' : '断开会话';
  String get killAction => _en ? 'Disconnect' : '断开';
  String killSessionConfirm(String username, String tty) => _en
      ? 'Kill the active session of user "$username" on TTY "$tty"?'
      : '确定要强行断开用户 "$username" 在终端 "$tty" 的会话吗？';
  String get omServers => _en ? 'O&M Servers' : '运维服务器';
  String get notConnected => _en ? 'Not Connected' : '未连接';
  String get connectingEllipsis => _en ? 'Connecting...' : '连接中...';
}

class TerminalStrings {
  final AppLanguage language;

  const TerminalStrings(this.language);

  bool get _en => language == AppLanguage.en;

  String get connected => _en ? 'Connected' : '已连接';
  String get connecting => _en ? 'Connecting' : '连接中';
  String get disconnected => _en ? 'Disconnected' : '已断开';
  String get fontSize => _en ? 'Font' : '字号';
  String get defaultTerminal => _en ? 'SSH Terminal' : 'SSH 终端';
  String get currentServer => _en ? 'current server' : '当前服务器';
  String get unknown => _en ? 'unknown' : '未知错误';
  String get smallerFont => _en ? 'Smaller font' : '缩小字号';
  String get largerFont => _en ? 'Larger font' : '放大字号';
  String get switchToLightMode => _en ? 'Switch to light mode' : '切换到浅色主题';
  String get switchToDarkMode => _en ? 'Switch to dark mode' : '切换到深色主题';
  String get newWindow => _en ? 'New terminal window' : '新建终端窗口';
  String get renameWindow => _en ? 'Rename window' : '重命名窗口';
  String get switchWindow => _en ? 'Switch terminal window' : '切换终端窗口';
  String get disconnect => _en ? 'Disconnect' : '断开连接';
  String get reconnect => _en ? 'Reconnect' : '重连';
  String get reconnecting => _en ? 'Reconnecting...' : '正在重连...';
  String get connectingSession => _en ? 'Connecting to the terminal' : '正在连接终端';
  String get connectingSessionHint => _en
      ? 'Secure session negotiation is in progress. This usually takes only a moment.'
      : '正在协商安全会话，通常只需片刻。';
  String get connectionInterrupted =>
      _en ? 'Terminal connection interrupted' : '终端连接已中断';
  String get connectionInterruptedHint => _en
      ? 'Your terminal output is preserved. Reconnect to continue this session.'
      : '终端输出已保留，可重新连接后继续当前会话。';
  String get terminalConnectionError =>
      _en ? 'Could not connect to the terminal' : '无法连接终端';
  String get terminalConnectionErrorStatus => _en ? 'Error' : '错误';
  String get terminalConnectionErrorHint => _en
      ? 'Check the server and network, then try connecting again.'
      : '请检查服务器和网络状态，然后重试连接。';
  String get manageWindows => _en ? 'Manage windows' : '管理窗口';
  String get closeWindow => _en ? 'Close window' : '关闭窗口';
  String get restoringTerminalOutput =>
      _en ? 'Restoring terminal output…' : '正在恢复终端输出…';
  String get closeDisconnected =>
      _en ? 'Close disconnected window' : '关闭已断开的窗口';
  String get openNewWindow => _en ? 'Open new window' : '打开新窗口';
  String createFrom(String name) =>
      _en ? 'Create a new SSH window from "$name"?' : '使用 "$name" 创建新的 SSH 窗口？';
  String get cancel => _en ? 'Cancel' : '取消';
  String get editServer => _en ? 'Edit server' : '编辑服务器';
  String get addServer => _en ? 'Add server' : '新增服务器';
  String get create => _en ? 'Create' : '创建';
  String connectingTo(String name) =>
      _en ? 'Connecting to $name' : '正在连接 $name';
  String get openingNewWindow =>
      _en ? 'Opening a new SSH window...' : '正在打开新的 SSH 窗口...';
  String connectionFailed(String message) =>
      _en ? 'Connection failed: $message' : '连接失败：$message';
  String tmuxMissingHint(String text) => _en
      ? 'Connection failed: $text\nPlease install tmux manually on the server and try again.'
      : '连接失败：$text\n请先在服务器上手动安装 tmux 后再重试。';
  String get currentWindow => _en ? 'Current window' : '当前窗口';
  String get save => _en ? 'Save' : '保存';
  String get windowName => _en ? 'Window name' : '窗口名称';
  String get duplicateWindowName =>
      _en ? 'Window name already exists' : '窗口名称已存在';
  String get addShortcut => _en ? 'Add shortcut command' : '添加快捷命令';
  String get complexKeyboard => _en ? 'Advanced keyboard' : '复杂键盘';
  String get advancedKeyboardHint => _en
      ? 'Navigation, control, function keys, and multiline input.'
      : '集中使用导航键、控制键、功能键和多行输入。';
  String get moreKeys => _en ? 'More shortcut keys' : '更多快捷键';
  String get moreKeysHint => _en
      ? 'Frequently used shell navigation and control keys.'
      : '常用的 Shell 导航键与控制键。';
  String get multilineHint =>
      _en ? 'Paste or type multiline input' : '粘贴或输入多行文本';
  String get send => _en ? 'Send' : '发送';
  String get label => _en ? 'Label' : '标签';
  String get command => _en ? 'Command' : '命令';
  String get add => _en ? 'Add' : '添加';
  String get removeShortcut => _en ? 'Remove shortcut' : '删除快捷命令';
  String removeShortcutContent(String label) =>
      _en ? 'Remove "$label"?' : '删除 "$label"？';
  String get remove => _en ? 'Remove' : '删除';
  String get selectCopy => _en ? 'Select copy' : '选择复制';
  String get copy => _en ? 'Copy' : '复制';
  String get paste => _en ? 'Paste' : '粘贴';
  String get closeDisconnectedTitle =>
      _en ? 'Close disconnected window' : '关闭已断开的窗口';
  String disconnectContent(String name) =>
      _en ? 'Disconnect "$name"?' : '断开 "$name"？';
  String closeDisconnectedContent(String name) => _en
      ? '"$name" is already disconnected. Close this window?'
      : '"$name" 已经断开。关闭这个窗口吗？';
  String get copyAll => _en ? 'Copy all' : '复制全部';
  String get terminalOutput => _en ? 'Terminal output' : '终端输出';
  String get terminalOutputSnapshot =>
      _en ? 'Terminal output snapshot' : '终端输出快照';
  String get terminalOutputSelectionHint =>
      _en ? 'Select any text to copy part of the output.' : '选择任意文本可复制部分输出。';
  String get readOnly => _en ? 'Read-only' : '只读';
  String get copyingTerminalOutput =>
      _en ? 'Copying terminal output…' : '正在复制终端输出…';
  String get copyTerminalOutputFailed =>
      _en ? 'Could not copy the terminal output. Try again.' : '无法复制终端输出，请重试。';
  String terminalOutputSummary(int lineCount, int characterCount) {
    if (!_en) return '$lineCount 行 · $characterCount 个字符';
    final lines = lineCount == 1 ? 'line' : 'lines';
    final characters = characterCount == 1 ? 'character' : 'characters';
    return '$lineCount $lines · $characterCount $characters';
  }

  String get moreActions => _en ? 'More actions' : '更多操作';
  String get navigationShell => _en ? 'Navigation & Shell' : '导航与 Shell';
  String get editControl => _en ? 'Edit & Control' : '编辑与控制';
  String get functionKeys => _en ? 'Function Keys' : '功能键';
}
