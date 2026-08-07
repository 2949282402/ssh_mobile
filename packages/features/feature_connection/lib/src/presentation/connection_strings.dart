// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

/// Connection Feature 自己需要的语言枚举，避免依赖 AppSettings 的实现类型。
enum ConnectionLanguage { chinese, english }

/// 连接页面的双语文案和语言状态。
///
/// App 组合根通过 `ChangeNotifierProxyProvider` 将全局语言设置同步到本
/// 对象；页面只依赖本 Feature 的展示契约，因此可以脱离 App 单独测试。
final class ConnectionStrings extends ChangeNotifier {
  ConnectionStrings({ConnectionLanguage language = ConnectionLanguage.chinese})
    : _language = language;

  ConnectionLanguage _language;

  ConnectionLanguage get language => _language;
  bool get isEnglish => _language == ConnectionLanguage.english;

  /// 同步 App Scope 的语言；值未变化时不触发无意义重建。
  void setLanguage(ConnectionLanguage language) {
    if (_language == language) return;
    _language = language;
    notifyListeners();
  }

  bool get _en => isEnglish;

  String get cancel => _en ? 'Cancel' : '取消';
  String get save => _en ? 'Save' : '保存';
  String get saving => _en ? 'Saving...' : '保存中...';
  String get addConnection => _en ? 'Add connection' : '添加连接';
  String get editConnection => _en ? 'Edit connection' : '编辑连接';
  String get verifyAndSave => _en ? 'Verify & Save' : '验证并保存';
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
      _en ? 'Optional (leave empty for direct)' : '可选，留空则直连';
  String get jumpPort => _en ? 'Jump host port' : '跳板机端口';
  String get jumpUsername => _en ? 'Jump host username' : '跳板机用户名';
  String get optional => _en ? 'Optional' : '可选';
  String get tmuxModeDescription => _en
      ? 'Auto-connect to tmux session matching the window name.'
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
  String get paste => _en ? 'Paste' : '粘贴';
  String get serverSystem => _en ? 'Server system' : '服务器系统';
  String get windowsTmuxUnavailable => _en
      ? 'tmux requires a Linux/WSL connection with tmux installed.'
      : 'Windows OpenSSH 使用普通交互式 shell。tmux 只适用于 Linux/WSL 且服务器已安装 tmux 的场景。';
  String get windowsMonitoringDescription => _en
      ? 'PowerShell diagnostics monitor. Terminal uses plain SSH.'
      : 'Windows 监控会使用 PowerShell 诊断命令；终端模式固定为普通 SSH。';
  String get linuxMonitoringDescription => _en
      ? 'Default. Supports plain SSH and SSH + tmux.'
      : '默认选项。服务器安装 tmux 时支持普通 SSH 和 SSH + tmux。';
  String get saveFailedGuidance => _en
      ? 'Please check the host address, port, username, password or private key, then save again.'
      : '请检查主机地址、端口、用户名、密码或私钥后重新保存。';
  String get saveWillCloseWindowsTitle =>
      _en ? 'Related windows will be closed' : '保存后将关闭相关窗口';
  String saveWillCloseWindowsContent(int count) => _en
      ? 'Saving closes $count active terminal ${count == 1 ? "window" : "windows"} to apply the connection changes.'
      : '当前配置有关联的 $count 个终端窗口。保存修改后，这些旧窗口会自动关闭，避免继续向旧 SSH 或旧 tmux 会话发送输入。';
  String get saveAndDisconnect => _en ? 'Save and disconnect' : '保存并断开';
  String get notConfigured => _en ? 'Not configured' : '未配置';
  String get advancedOptionsSummary =>
      _en ? 'Platform, tmux, KeepAlive' : '系统平台、tmux及保活设置';
  String get editSubtitle => _en
      ? 'Modify SSH server connection and authentication settings'
      : '修改并保存 SSH 服务器配置与认证信息';
  String get addSubtitle => _en
      ? 'Configure host address, port, auth credentials, and platform options'
      : '配置主机、端口、认证凭据与运行平台模式';

  String saveFailed(Object error) =>
      _en ? 'Save failed: $error' : '保存失败: $error';
}
