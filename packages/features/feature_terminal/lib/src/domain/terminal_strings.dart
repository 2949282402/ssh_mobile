// Terminal Feature 自有的中英双语文案。
//
// 文案不再从 AppSettings/全局 AppStrings 反向读取；language 接受 App 传入
// 的任意语言快照，以保持旧 AppLanguage 枚举的兼容性。

/// Terminal 页面文案。
final class TerminalStrings {
  /// 使用 App 传入的语言快照创建文案对象。
  const TerminalStrings(this.language);

  /// App 的语言值；通常是 AppLanguage 或字符串 `en`/`zh`。
  final Object language;

  bool get isEnglish {
    final value = language.toString().toLowerCase();
    return value == 'en' || value.endsWith('.en') || value.contains('english');
  }

  String _text(String zh, String en) => isEnglish ? en : zh;

  String get connected => _text('已连接', 'Connected');
  String get connecting => _text('连接中', 'Connecting');
  String get disconnected => _text('已断开', 'Disconnected');
  String get fontSize => _text('字号', 'Font');
  String get defaultTerminal => _text('SSH 终端', 'SSH Terminal');
  String get currentServer => _text('当前服务器', 'current server');
  String get unknown => _text('未知错误', 'unknown');
  String get smallerFont => _text('缩小字号', 'Smaller Font');
  String get largerFont => _text('放大字号', 'Larger Font');
  String get switchToLightMode => _text('切换到浅色主题', 'Light Mode');
  String get switchToDarkMode => _text('切换到深色主题', 'Dark Mode');
  String get newWindow => _text('新建终端窗口', 'New Window');
  String get renameWindow => _text('重命名窗口', 'Rename Window');
  String get switchWindow => _text('切换终端窗口', 'Switch Window');
  String get disconnect => _text('断开连接', 'Disconnect');
  String get reconnect => _text('重连', 'Reconnect');
  String get reconnecting => _text('正在重连...', 'Reconnecting...');
  String get connectingSession => _text('正在连接终端', 'Connecting to the terminal');
  String get connectingSessionHint =>
      _text('正在协商安全会话，通常只需片刻。', 'Negotiating secure session. Please wait.');
  String get connectionInterrupted =>
      _text('终端连接已中断', 'Terminal connection interrupted');
  String get connectionInterruptedHint => _text(
    '终端输出已保留，可重新连接后继续当前会话。',
    'Terminal output preserved. Reconnect to resume.',
  );
  String get terminalConnectionError =>
      _text('无法连接终端', 'Could not connect to the terminal');
  String get terminalConnectionErrorStatus => _text('错误', 'Error');
  String get terminalConnectionErrorHint => _text(
    '请检查服务器和网络状态，然后重试连接。',
    'Check server and network status, then retry.',
  );
  String get manageWindows => _text('管理窗口', 'Manage Windows');
  String get closeWindow => _text('关闭窗口', 'Close window');
  String get restoringTerminalOutput =>
      _text('正在恢复终端输出…', 'Restoring terminal output…');
  String get closeDisconnected => _text('关闭已断开的窗口', 'Close Disconnected');
  String get openNewWindow => _text('打开新的 SSH 窗口', 'Open New Window');
  String createFrom(String name) =>
      _text('使用 "$name" 创建新的 SSH 窗口？', 'Create new window from "$name"?');
  String get cancel => _text('取消', 'Cancel');
  String get editServer => _text('编辑服务器', 'Edit server');
  String get addServer => _text('新增服务器', 'Add server');
  String get create => _text('创建', 'Create');
  String connectingTo(String name) =>
      _text('正在连接 $name', 'Connecting to $name');
  String get establishingConnection =>
      _text('正在建立 SSH 连接...', 'Establishing SSH connection...');
  String get openingNewWindow =>
      _text('正在打开新的 SSH 窗口...', 'Opening new window...');
  String connectionFailed(String message) =>
      _text('连接失败：$message', 'Connection failed: $message');
  String tmuxMissingHint(String text) => _text(
    '连接失败：$text\n请先在服务器上手动安装 tmux 后再重试。',
    'Connection failed: $text\nPlease install tmux manually on the server and try again.',
  );
  String get currentWindow => _text('当前窗口', 'Current window');
  String get save => _text('保存', 'Save');
  String get windowName => _text('窗口名称', 'Window name');
  String get duplicateWindowName =>
      _text('窗口名称已存在', 'Window name already exists');
  String get addShortcut => _text('添加快捷命令', 'Add Command');
  String get complexKeyboard => _text('复杂键盘', 'Advanced Keyboard');
  String get advancedKeyboardHint => _text(
    '集中使用导航键、控制键、功能键和多行输入。',
    'Navigation, controls, function keys, and multiline.',
  );
  String get windowsKeyboard => _text('Windows 键盘', 'Windows Keyboard');
  String get windowsKeyboardHint => _text(
    '包含 F1-F12、修饰键、Shell 特殊符号与复杂命令编辑。',
    'Full PC layout with F1-F12, modifiers, symbols, and multiline commands.',
  );
  String get keyboardComposeMode => _text('编辑输入', 'Compose');
  String get keyboardDirectMode => _text('直接发送', 'Direct');
  String get customizeQuickKeys => _text('自定义快捷键', 'Customize quick keys');
  String get keyboardLetters => _text('字母', 'Letters');
  String get keyboardNavigation => _text('导航', 'Navigation');
  String get keyboardSpace => _text('空格', 'Space');
  String get keyboardBackspace => _text('退格', 'Backspace');
  String get keyboardEnter => _text('回车', 'Enter');
  String get quickKeysTitle => _text('自定义快捷栏', 'Customize Quick Keys');
  String get quickKeysHint => _text(
    '选择显示在 Ctrl、Alt 旁的内置键；自定义命令始终保留。',
    'Choose built-in keys shown beside Ctrl and Alt. Custom commands remain visible.',
  );
  String get quickKeysAtLeastOne =>
      _text('至少保留一个内置快捷键。', 'Keep at least one built-in quick key.');
  String get resetQuickKeys => _text('恢复默认', 'Reset defaults');
  String get done => _text('完成', 'Done');
  String get shellSymbols => _text('Shell 符号', 'Shell Symbols');
  String get controlShortcuts => _text('控制快捷键', 'Control Keys');
  String get moreKeys => _text('更多快捷键', 'More Shortcuts');
  String get moreKeysHint =>
      _text('常用的 Shell 导航键与控制键。', 'Shell navigation and control keys.');
  String get multilineHint =>
      _text('粘贴或输入多行文本', 'Paste or type multiline input');
  String get commandComposer => _text('命令编辑器', 'Command composer');
  String get commandComposerHint => _text(
    'Enter 发送 · Shift+Enter 换行 · 上下方向键浏览已发送命令',
    'Enter sends · Shift+Enter adds a line · Up/Down recalls sent commands',
  );
  String get pasteIntoCommand => _text('粘贴到命令编辑器', 'Paste into command');
  String get clearCommand => _text('清空命令', 'Clear command');
  String get send => _text('发送', 'Send');
  String get label => _text('标签', 'Label');
  String get command => _text('命令', 'Command');
  String get add => _text('添加', 'Add');
  String get removeShortcut => _text('删除快捷命令', 'Remove Shortcut');
  String removeShortcutContent(String label) =>
      _text('删除 "$label"？', 'Remove "$label"?');
  String get remove => _text('删除', 'Remove');
  String get selectCopy => _text('选择复制', 'Select Copy');
  String get copy => _text('复制', 'Copy');
  String get paste => _text('粘贴', 'Paste');
  String get closeDisconnectedTitle =>
      _text('关闭已断开的窗口', 'Close disconnected window');
  String disconnectContent(String name) =>
      _text('断开 "$name"？', 'Disconnect "$name"?');
  String closeDisconnectedContent(String name) => _text(
    '"$name" 已经断开。关闭这个窗口吗？',
    '"$name" is already disconnected. Close this window?',
  );
  String get copyAll => _text('复制全部', 'Copy all');
  String get terminalOutput => _text('终端输出', 'Terminal output');
  String get terminalOutputSnapshot => _text('终端输出快照', 'Output Snapshot');
  String get terminalOutputSelectionHint =>
      _text('选择任意文本可复制部分输出。', 'Select text to copy output.');
  String get readOnly => _text('只读', 'Read-only');
  String get copyingTerminalOutput => _text('正在复制终端输出…', 'Copying output...');
  String get copyTerminalOutputFailed =>
      _text('无法复制终端输出，请重试。', 'Failed to copy output. Retry.');
  String terminalOutputSummary(int lineCount, int characterCount) {
    if (!isEnglish) return '$lineCount 行 · $characterCount 个字符';
    final lines = lineCount == 1 ? 'line' : 'lines';
    final characters = characterCount == 1 ? 'character' : 'characters';
    return '$lineCount $lines · $characterCount $characters';
  }

  String get moreActions => _text('更多操作', 'More Actions');
  String get terminalAppearance => _text('终端外观', 'Terminal appearance');
  String get defaultOption => _text('默认', 'Default');
  String get terminalTheme => _text('终端配色方案', 'Terminal Theme');
  String get customTerminalFont => _text('自定义终端字体', 'Custom Terminal Font');
  String get customTerminalFontHint => _text(
    '系统已安装的等宽字体名称，如 Fira Code',
    'System monospaced font family, e.g. Fira Code',
  );

  String get terminalWindows => _text('终端窗口', 'Terminal windows');
  String terminalWindowsOverview(int total, int connected, int attention) =>
      _text(
        '共 $total 个窗口 · $connected 个已连接 · $attention 个需关注',
        '$total windows · $connected connected · $attention need attention',
      );
  String terminalWindowsForServer(int total, int connected) => _text(
    '$total 个窗口 · $connected 个已连接',
    '$total windows · $connected connected',
  );
  String selectedWindows(int count) => _text('已选择 $count 个', '$count selected');
  String selectedWindowsHint(int total) => _text(
    '从 $total 个窗口中选择要批量关闭的窗口。',
    'Select windows to close in batch from $total total.',
  );
  String viewAllTerminalWindows(int totalCount) =>
      _text('查看全部 $totalCount 个终端窗口', 'View all $totalCount terminal windows');
  String get exitSelection => _text('退出选择', 'Exit selection');
  String get selectAll => _text('全选', 'Select all');
  String get closeSelectedWindows => _text('关闭选中窗口', 'Close selected windows');
  String get connectionHistory => _text('连接历史', 'Connection history');
  String get newTerminalWindow => _text('新建终端窗口', 'New terminal window');
  String get noOpenWindows => _text('暂无打开的终端窗口', 'No open terminal windows');
  String get openWindowsHint => _text(
    '连接服务器后，终端窗口会显示在这里。',
    'Terminal windows appear here after you connect to a server.',
  );
  String get renameTerminalWindow => _text('重命名窗口', 'Rename window');
  String get windowActions => _text('窗口操作', 'Window actions');
  String get sessionMode => _text('模式', 'Mode');
  String get tmuxSession => 'tmux';
  String get plainSshSession => 'SSH';
  String get createdAt => _text('创建', 'Created');
  String get autoDestroy => _text('销毁', 'Auto delete');
  String get memoryUsage => _text('内存', 'Memory');
  String get notAvailable => _text('不适用', 'N/A');
  String autoDestroyAfter(String duration) =>
      _text('$duration 后销毁', 'Auto deletes after $duration');
  String autoDestroyAt(String time) => _text('预计 $time', 'around $time');
  String durationMinutes(int minutes) => _text('$minutes 分钟', '$minutes min');
  String durationSeconds(int seconds) => _text('$seconds 秒', '$seconds sec');
  String get connectionError => _text('连接错误', 'Connection error');
  String closeWindowTitle(String name) =>
      _text('关闭终端窗口', 'Close terminal window');
  String get closeTerminalWindow => _text('关闭终端窗口', 'Close terminal window');
  String get staleTmuxHint => _text(
    '此窗口关联的 tmux 会话可能已在服务器上结束。',
    'The tmux session for this window may have ended on the server.',
  );
  String get copyCommand => _text('复制命令', 'Copy command');
  String get copiedCleanupCommand =>
      _text('Server cleanup command copied', 'Server cleanup command copied');
  String closeSelectedContent(int count) => _text(
    '确定关闭选中的 $count 个终端窗口吗？',
    'Close the selected $count terminal windows?',
  );
  String get connectionHistoryHint => _text(
    '最近打开的终端会话及其连接状态会显示在这里。',
    'Recent terminal sessions and connection states appear here.',
  );
  String connectionHistoryCount(int count) =>
      _text('$count 个最近会话', '$count recent session${count == 1 ? '' : 's'}');
  String get loadingConnectionHistory =>
      _text('正在加载连接历史…', 'Loading connection history…');
  String get connectionHistoryLoadFailed =>
      _text('无法加载连接历史', 'Could not load connection history');
  String get connectionHistoryLoadFailedHint =>
      _text('请稍后重试。', 'Try again later.');
  String get noConnectionHistory =>
      _text('暂无连接历史', 'No connection history yet');
  String get noConnectionHistoryHint => _text(
    '最近打开的终端会话及其连接状态会显示在这里。',
    'Recent terminal sessions and their connection states appear here.',
  );
  String historyUpdatedAt(String time) => _text('更新于 $time', 'Updated $time');
  String get deleteHistoryRecord => _text('删除历史记录', 'Delete history record');
  String get deleteHistoryRecordFailed => _text(
    '无法删除此历史记录，请重试。',
    'Could not delete this history record. Try again.',
  );
  String get copiedCleanupCommandFailed =>
      _text('无法复制清理命令，请重试。', 'Could not copy the cleanup command. Try again.');
  String get copyCleanupCommandFailed => copiedCleanupCommandFailed;
  String get functionKeys => _text('功能键', 'Function Keys');
  String get refresh => _text('刷新', 'Refresh');
  String get retry => _text('重试', 'Retry');
  String get close => _text('关闭', 'Close');
  String get newWindowLabel => newWindow;
}
