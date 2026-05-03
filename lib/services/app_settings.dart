import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLanguage {
  zh,
  en,
}

class AppSettings extends ChangeNotifier {
  static const _languageKey = 'app_language';
  static const _darkModeKey = 'dark_mode';

  AppLanguage _language = AppLanguage.zh;
  ThemeMode _themeMode = ThemeMode.dark;
  bool _initialized = false;

  AppLanguage get language => _language;
  ThemeMode get themeMode => _themeMode;
  bool get initialized => _initialized;
  bool get isEnglish => _language == AppLanguage.en;
  bool get isDarkMode => _themeMode == ThemeMode.dark;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final languageName = prefs.getString(_languageKey);
    _language =
        languageName == AppLanguage.en.name ? AppLanguage.en : AppLanguage.zh;
    _themeMode =
        prefs.getBool(_darkModeKey) == false ? ThemeMode.light : ThemeMode.dark;
    _initialized = true;
    notifyListeners();
  }

  Future<void> toggleLanguage() async {
    _language = _language == AppLanguage.zh ? AppLanguage.en : AppLanguage.zh;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_languageKey, _language.name);
  }

  Future<void> toggleTheme() async {
    _themeMode =
        _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_darkModeKey, _themeMode == ThemeMode.dark);
  }
}

class AppStrings {
  final AppLanguage language;

  const AppStrings(this.language);

  bool get _en => language == AppLanguage.en;

  String get disconnectAllTooltip => _en ? 'Close all windows' : '关闭所有窗口';
  String get addConnection => _en ? 'Add connection' : '添加连接';
  String get noConnections => _en ? 'No saved servers yet' : '还没有保存的服务器';
  String get addHint => _en ? 'Tap + to add a connection' : '点击右下角 + 添加连接';
  String get newWindow => _en ? 'New window' : '新建窗口';
  String get edit => _en ? 'Edit' : '编辑';
  String get delete => _en ? 'Delete' : '删除';
  String get closeAllTitle => _en ? 'Close all windows' : '关闭所有窗口';
  String closeAllContent(int count) => _en
      ? 'Close all $count terminal ${count == 1 ? "window" : "windows"}?'
      : '确定关闭全部 $count 个终端窗口吗？';
  String get cancel => _en ? 'Cancel' : '取消';
  String get closeAll => _en ? 'Close all' : '全部关闭';
  String get deleteConnectionTitle => _en ? 'Delete connection' : '删除连接';
  String deleteConnectionContent(String name) => _en
      ? 'Delete "$name"? Password and private key will also be removed.'
      : '确定删除 "$name" 吗？\n密码和私钥也会一并清除。';
  String get lightMode => _en ? 'Light mode' : '浅色主题';
  String get darkMode => _en ? 'Dark mode' : '深色主题';
  String get switchToChinese => '中文';
  String get switchToEnglish => 'EN';
}

class TerminalStrings {
  final AppLanguage language;

  const TerminalStrings(this.language);

  bool get _en => language == AppLanguage.en;

  String get connected => _en ? 'Connected' : '已连接';
  String get disconnected => _en ? 'Disconnected' : '已断开';
  String get fontSize => _en ? 'Font' : '字号';
  String get defaultTerminal => _en ? 'SSH Terminal' : 'SSH 终端';
  String get currentServer => _en ? 'current server' : '当前服务器';
  String get unknown => _en ? 'unknown' : '未知错误';
  String get smallerFont => _en ? 'Smaller font' : '缩小字号';
  String get largerFont => _en ? 'Larger font' : '放大字号';
  String get newWindow => _en ? 'New terminal window' : '新建终端窗口';
  String get renameWindow => _en ? 'Rename window' : '重命名窗口';
  String get switchWindow => _en ? 'Switch terminal window' : '切换终端窗口';
  String get disconnect => _en ? 'Disconnect' : '断开连接';
  String get reconnect => _en ? 'Reconnect' : '重连';
  String get reconnecting => _en ? 'Reconnecting...' : '正在重连...';
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
  String get currentWindow => _en ? 'Current window' : '当前窗口';
  String get save => _en ? 'Save' : '保存';
  String get windowName => _en ? 'Window name' : '窗口名称';
  String get duplicateWindowName =>
      _en ? 'Window name already exists' : '窗口名称已存在';
  String get addShortcut => _en ? 'Add shortcut command' : '添加快捷命令';
  String get complexKeyboard => _en ? 'Advanced keyboard' : '复杂键盘';
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
}
