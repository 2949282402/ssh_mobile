import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log_service.dart';
import 'mcp/mcp_server_settings.dart';

enum AppLanguage {
  zh,
  en,
}

/// 应用设置 + 国际化字符串服务。
///
/// 职责：
/// 1. 持久化设置：ThemeMode、语言、字体、SFTP 大小限制
/// 2. AppStrings：中英双语约 230 个字符串的集中管理
/// 3. 字体选择：8 个预定义字体（思源黑体、Noto Sans、Roboto、Microsoft YaHei、PingFang SC 等）
///
/// 语言切换后通过 notifyListeners() 触发 MaterialApp 重建，实现全局语言切换。
class AppSettings extends ChangeNotifier {
  static const _languageKey = 'app_language';
  static const _darkModeKey = 'dark_mode';
  static const _themeModeKey = 'theme_mode';
  static const _fontFamilyKey = 'font_family';
  static const _ragEnabledKey = 'rag_enabled';
  static const _ragSearchModeKey = 'rag_search_mode';
  static const _ragTopNKey = 'rag_top_n';
  static const _showServerNamesInNotificationsKey =
      'show_server_names_in_notifications';
  static const _sftpDownloadLimitBytesKey = 'sftp_download_limit_bytes';
  static const _sftpTextPreviewLimitBytesKey = 'sftp_text_preview_limit_bytes';
  static const _sftpRichPreviewLimitBytesKey = 'sftp_rich_preview_limit_bytes';
  static const _sftpTextEditLimitBytesKey = 'sftp_text_edit_limit_bytes';
  static const _mcpServerEnabledKey = 'mcp_server_enabled';
  static const _mcpServerHostKey = 'mcp_server_host';
  static const _mcpServerPortKey = 'mcp_server_port';
  static const _mcpAllowWriteToolsKey = 'mcp_allow_write_tools';
  static const _mcpRequireApprovalForWriteToolsKey =
      'mcp_require_approval_for_write_tools';
  static const _mcpEnableSseKey = 'mcp_enable_sse';
  static const _mcpServerTokenSecureKey = 'mcp_server_token';
  static const _oledDarkKey = 'oled_dark';
  static const _terminalThemeIdKey = 'terminal_theme_id';
  static const _terminalFontFamilyKey = 'terminal_font_family';
  static const _serverListLayoutModeKey = 'server_list_layout_mode';
  static const int minSftpLimitBytes = 64 * 1024;
  static const int maxSftpLimitBytes = 2 * 1024 * 1024 * 1024;
  static const int defaultSftpDownloadLimitBytes = 512 * 1024 * 1024;
  static const int defaultSftpTextPreviewLimitBytes = 2 * 1024 * 1024;
  static const int defaultSftpRichPreviewLimitBytes = 20 * 1024 * 1024;
  static const int defaultSftpTextEditLimitBytes = 512 * 1024;

  AppLanguage _language = AppLanguage.zh;
  ThemeMode _themeMode = ThemeMode.light;
  String _fontFamilyId = AppFontChoice.systemId;
  int _sftpDownloadLimitBytes = defaultSftpDownloadLimitBytes;
  int _sftpTextPreviewLimitBytes = defaultSftpTextPreviewLimitBytes;
  int _sftpRichPreviewLimitBytes = defaultSftpRichPreviewLimitBytes;
  int _sftpTextEditLimitBytes = defaultSftpTextEditLimitBytes;
  bool _ragEnabled = false;
  String _ragSearchMode = 'bm25'; // 'bm25', 'vector', 'hybrid'
  int _ragTopN = 3;
  bool _showServerNamesInNotifications = false;
  bool _mcpServerEnabled = false;
  String _mcpServerHost = McpServerSettings.defaultHost;
  int _mcpServerPort = McpServerSettings.defaultPort;
  String _mcpServerToken = '';
  bool _mcpAllowWriteTools = false;
  bool _mcpRequireApprovalForWriteTools = true;
  bool _mcpEnableSse = false;
  bool _oledDark = false;
  String _terminalThemeId = 'default';
  String _terminalFontFamily = '';
  String _serverListLayoutMode = 'list';
  bool _initialized = false;
  final Completer<void> _initCompleter = Completer<void>();
  Future<void> _themeWrite = Future.value();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  AppLanguage get language => _language;
  ThemeMode get themeMode => _themeMode;
  bool get initialized => _initialized;
  Future<void> get initFuture => _initCompleter.future;
  bool get isEnglish => _language == AppLanguage.en;
  bool get isDarkMode => _themeMode == ThemeMode.dark;
  bool get ragEnabled => _ragEnabled;
  String get ragSearchMode => _ragSearchMode;
  int get ragTopN => _ragTopN;
  bool get showServerNamesInNotifications => _showServerNamesInNotifications;
  String get fontFamilyId => _fontFamilyId;
  String? get fontFamily => AppFontChoice.byId(_fontFamilyId).fontFamily;
  AppFontChoice get fontChoice => AppFontChoice.byId(_fontFamilyId);
  int get sftpDownloadLimitBytes => _sftpDownloadLimitBytes;
  int get sftpTextPreviewLimitBytes => _sftpTextPreviewLimitBytes;
  int get sftpRichPreviewLimitBytes => _sftpRichPreviewLimitBytes;
  int get sftpTextEditLimitBytes => _sftpTextEditLimitBytes;
  bool get mcpServerEnabled => _mcpServerEnabled;
  String get mcpServerHost => _mcpServerHost;
  int get mcpServerPort => _mcpServerPort;
  String get mcpServerToken => _mcpServerToken;
  bool get mcpAllowWriteTools => _mcpAllowWriteTools;
  bool get mcpRequireApprovalForWriteTools => _mcpRequireApprovalForWriteTools;
  bool get mcpEnableSse => _mcpEnableSse;
  bool get oledDark => _oledDark;
  String get terminalThemeId => _terminalThemeId;
  String get terminalFontFamily => _terminalFontFamily;
  String get serverListLayoutMode => _serverListLayoutMode;
  McpServerSettings get mcpSettings => McpServerSettings(
        enabled: _mcpServerEnabled,
        host: _mcpServerHost,
        port: _mcpServerPort,
        token: _mcpServerToken,
        allowWriteTools: _mcpAllowWriteTools,
        requireApprovalForWriteTools: _mcpRequireApprovalForWriteTools,
        enableSse: _mcpEnableSse,
      );

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 3),
      );
      final languageName = prefs.getString(_languageKey);
      _language =
          languageName == AppLanguage.en.name ? AppLanguage.en : AppLanguage.zh;
      _themeMode = _themeModeFromPrefs(prefs);
      _fontFamilyId = AppFontChoice.normalize(prefs.getString(_fontFamilyKey));
      _sftpDownloadLimitBytes = _normalizeSftpLimit(
        prefs.getInt(_sftpDownloadLimitBytesKey),
        defaultSftpDownloadLimitBytes,
      );
      _sftpTextPreviewLimitBytes = _normalizeSftpLimit(
        prefs.getInt(_sftpTextPreviewLimitBytesKey),
        defaultSftpTextPreviewLimitBytes,
      );
      _sftpRichPreviewLimitBytes = _normalizeSftpLimit(
        prefs.getInt(_sftpRichPreviewLimitBytesKey),
        defaultSftpRichPreviewLimitBytes,
      );
      _sftpTextEditLimitBytes = _normalizeSftpLimit(
        prefs.getInt(_sftpTextEditLimitBytesKey),
        defaultSftpTextEditLimitBytes,
      );
      _ragEnabled = prefs.getBool(_ragEnabledKey) ?? false;
      _ragSearchMode = prefs.getString(_ragSearchModeKey) ?? 'bm25';
      _ragTopN = prefs.getInt(_ragTopNKey) ?? 3;
      _showServerNamesInNotifications =
          prefs.getBool(_showServerNamesInNotificationsKey) ?? false;
      _mcpServerEnabled = prefs.getBool(_mcpServerEnabledKey) ?? false;
      final host = prefs.getString(_mcpServerHostKey);
      _mcpServerHost = McpServerSettings.isAllowedHost(host ?? '')
          ? McpServerSettings.normalizeHost(host!)
          : McpServerSettings.defaultHost;
      _mcpServerPort = McpServerSettings.normalizePort(
        prefs.getInt(_mcpServerPortKey),
      );
      _mcpAllowWriteTools = prefs.getBool(_mcpAllowWriteToolsKey) ?? false;
      _mcpRequireApprovalForWriteTools =
          prefs.getBool(_mcpRequireApprovalForWriteToolsKey) ?? true;
      _mcpEnableSse = prefs.getBool(_mcpEnableSseKey) ?? false;
      _mcpServerToken = await _readOrCreateMcpServerToken();
      _oledDark = prefs.getBool(_oledDarkKey) ?? false;
      _terminalThemeId = prefs.getString(_terminalThemeIdKey) ?? 'default';
      _terminalFontFamily = prefs.getString(_terminalFontFamilyKey) ?? '';
      _serverListLayoutMode =
          prefs.getString(_serverListLayoutModeKey) ?? 'list';
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Failed to initialize AppSettings',
        error: e,
        stackTrace: stackTrace,
      );
      _language = AppLanguage.zh;
      _themeMode = ThemeMode.light;
      _fontFamilyId = AppFontChoice.systemId;
      _sftpDownloadLimitBytes = defaultSftpDownloadLimitBytes;
      _sftpTextPreviewLimitBytes = defaultSftpTextPreviewLimitBytes;
      _sftpRichPreviewLimitBytes = defaultSftpRichPreviewLimitBytes;
      _sftpTextEditLimitBytes = defaultSftpTextEditLimitBytes;
      _ragEnabled = false;
      _ragSearchMode = 'bm25';
      _ragTopN = 3;
      _showServerNamesInNotifications = false;
      _mcpServerEnabled = false;
      _mcpServerHost = McpServerSettings.defaultHost;
      _mcpServerPort = McpServerSettings.defaultPort;
      _mcpServerToken = '';
      _mcpAllowWriteTools = false;
      _mcpRequireApprovalForWriteTools = true;
      _mcpEnableSse = false;
      _oledDark = false;
      _terminalThemeId = 'default';
      _terminalFontFamily = '';
      _serverListLayoutMode = 'list';
    } finally {
      _initialized = true;
      if (!_initCompleter.isCompleted) {
        _initCompleter.complete();
      }
      notifyListeners();
    }
  }

  Future<void> toggleLanguage() async {
    _language = _language == AppLanguage.zh ? AppLanguage.en : AppLanguage.zh;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_languageKey, _language.name);
    AppLogService.instance.info(
      'Language setting updated',
      details: 'language=${_language.name}',
    );
  }

  Future<void> setRagEnabled(bool value) async {
    if (_ragEnabled == value) return;
    _ragEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_ragEnabledKey, value);
    AppLogService.instance.info(
      'RAG setting updated: enabled',
      details: 'enabled=$value',
    );
  }

  Future<void> setRagSearchMode(String mode) async {
    if (_ragSearchMode == mode) return;
    _ragSearchMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ragSearchModeKey, mode);
    AppLogService.instance.info(
      'RAG setting updated: searchMode',
      details: 'searchMode=$mode',
    );
  }

  Future<void> setRagTopN(int value) async {
    if (_ragTopN == value) return;
    _ragTopN = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_ragTopNKey, value);
    AppLogService.instance.info(
      'RAG setting updated: topN',
      details: 'topN=$value',
    );
  }

  Future<void> setShowServerNamesInNotifications(bool value) async {
    if (_showServerNamesInNotifications == value) return;
    _showServerNamesInNotifications = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showServerNamesInNotificationsKey, value);
    AppLogService.instance.info(
      'Notification privacy setting updated',
      details: 'showServerNames=$value',
    );
  }

  Future<void> setMcpServerEnabled(bool value) async {
    if (value) {
      await ensureMcpServerToken();
    }
    if (_mcpServerEnabled == value) return;
    _mcpServerEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_mcpServerEnabledKey, value);
    AppLogService.instance.info(
      'MCP server enabled setting updated',
      details: 'enabled=$value',
    );
  }

  Future<void> setMcpServerHost(String host) async {
    final normalized = McpServerSettings.normalizeHost(host);
    if (!McpServerSettings.isAllowedHost(normalized)) {
      throw ArgumentError.value(host, 'host', 'Invalid MCP host');
    }
    if (_mcpServerHost == normalized) return;
    _mcpServerHost = normalized;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_mcpServerHostKey, normalized);
    AppLogService.instance.info(
      'MCP server host setting updated',
      details: 'host=$normalized',
    );
  }

  Future<void> setMcpServerPort(int port) async {
    if (!McpServerSettings.isValidPort(port)) {
      throw ArgumentError.value(port, 'port', 'Invalid MCP port');
    }
    if (_mcpServerPort == port) return;
    _mcpServerPort = port;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_mcpServerPortKey, port);
    AppLogService.instance.info(
      'MCP server port setting updated',
      details: 'port=$port',
    );
  }

  Future<void> setMcpAllowWriteTools(bool value) async {
    if (_mcpAllowWriteTools == value) return;
    _mcpAllowWriteTools = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_mcpAllowWriteToolsKey, value);
    AppLogService.instance.info(
      'MCP write-tool setting updated',
      details: 'allowWriteTools=$value',
    );
  }

  Future<void> setMcpRequireApprovalForWriteTools(bool value) async {
    if (_mcpRequireApprovalForWriteTools == value) return;
    _mcpRequireApprovalForWriteTools = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_mcpRequireApprovalForWriteToolsKey, value);
    AppLogService.instance.info(
      'MCP write-tool approval setting updated',
      details: 'requireApproval=$value',
    );
  }

  Future<void> setMcpEnableSse(bool value) async {
    if (_mcpEnableSse == value) return;
    _mcpEnableSse = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_mcpEnableSseKey, value);
    AppLogService.instance.info(
      'MCP SSE setting updated',
      details: 'enableSse=$value',
    );
  }

  Future<String> ensureMcpServerToken() async {
    if (_mcpServerToken.trim().isNotEmpty) return _mcpServerToken;
    final token = McpServerSettings.generateToken();
    await _secureStorage.write(key: _mcpServerTokenSecureKey, value: token);
    _mcpServerToken = token;
    notifyListeners();
    AppLogService.instance.info('MCP server token generated');
    return token;
  }

  Future<String> regenerateMcpServerToken() async {
    final token = McpServerSettings.generateToken();
    await _secureStorage.write(key: _mcpServerTokenSecureKey, value: token);
    _mcpServerToken = token;
    notifyListeners();
    AppLogService.instance.info('MCP server token regenerated');
    return token;
  }

  void toggleTheme() {
    final nextMode =
        _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    setThemeMode(nextMode);
  }

  void setThemeMode(ThemeMode mode) {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();

    _themeWrite = _themeWrite.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_themeModeKey, _themeModeToName(mode));
      await prefs.setBool(_darkModeKey, mode == ThemeMode.dark);
      AppLogService.instance.info(
        'Theme setting updated',
        details: 'themeMode=${mode.name}',
      );
    });
  }

  Future<void> setOledDark(bool value) async {
    if (_oledDark == value) return;
    _oledDark = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_oledDarkKey, value);
    AppLogService.instance.info(
      'OLED Dark setting updated',
      details: 'oledDark=$value',
    );
  }

  Future<void> setTerminalThemeId(String id) async {
    if (_terminalThemeId == id) return;
    _terminalThemeId = id;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_terminalThemeIdKey, id);
    AppLogService.instance.info(
      'Terminal Theme setting updated',
      details: 'themeId=$id',
    );
  }

  Future<void> setTerminalFontFamily(String family) async {
    final trimmed = family.trim();
    if (_terminalFontFamily == trimmed) return;
    _terminalFontFamily = trimmed;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_terminalFontFamilyKey, trimmed);
    AppLogService.instance.info(
      'Terminal Font setting updated',
      details: 'fontFamily=$trimmed',
    );
  }

  Future<void> setServerListLayoutMode(String mode) async {
    if (_serverListLayoutMode == mode) return;
    _serverListLayoutMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverListLayoutModeKey, mode);
    AppLogService.instance.info(
      'Server list layout mode updated',
      details: 'mode=$mode',
    );
  }

  Future<void> setFontFamilyId(String id) async {
    final normalized = AppFontChoice.normalize(id);
    if (_fontFamilyId == normalized) return;
    _fontFamilyId = normalized;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_fontFamilyKey, normalized);
    AppLogService.instance.info(
      'Font family setting updated',
      details: 'fontFamilyId=$normalized',
    );
  }

  Future<void> setSftpDownloadLimitBytes(int bytes) {
    return _setSftpLimitBytes(
      key: _sftpDownloadLimitBytesKey,
      current: _sftpDownloadLimitBytes,
      fallback: defaultSftpDownloadLimitBytes,
      bytes: bytes,
      apply: (value) => _sftpDownloadLimitBytes = value,
    );
  }

  Future<void> setSftpTextPreviewLimitBytes(int bytes) {
    return _setSftpLimitBytes(
      key: _sftpTextPreviewLimitBytesKey,
      current: _sftpTextPreviewLimitBytes,
      fallback: defaultSftpTextPreviewLimitBytes,
      bytes: bytes,
      apply: (value) => _sftpTextPreviewLimitBytes = value,
    );
  }

  Future<void> setSftpRichPreviewLimitBytes(int bytes) {
    return _setSftpLimitBytes(
      key: _sftpRichPreviewLimitBytesKey,
      current: _sftpRichPreviewLimitBytes,
      fallback: defaultSftpRichPreviewLimitBytes,
      bytes: bytes,
      apply: (value) => _sftpRichPreviewLimitBytes = value,
    );
  }

  Future<void> setSftpTextEditLimitBytes(int bytes) {
    return _setSftpLimitBytes(
      key: _sftpTextEditLimitBytesKey,
      current: _sftpTextEditLimitBytes,
      fallback: defaultSftpTextEditLimitBytes,
      bytes: bytes,
      apply: (value) => _sftpTextEditLimitBytes = value,
    );
  }

  Future<void> _setSftpLimitBytes({
    required String key,
    required int current,
    required int fallback,
    required int bytes,
    required ValueChanged<int> apply,
  }) async {
    final normalized = _normalizeSftpLimit(bytes, fallback);
    if (current == normalized) return;
    apply(normalized);
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(key, normalized);
    AppLogService.instance.info(
      'SFTP size limit setting updated',
      details: 'key=$key value=$normalized bytes',
    );
  }

  int _normalizeSftpLimit(int? bytes, int fallback) {
    final value = bytes == null || bytes <= 0 ? fallback : bytes;
    return value.clamp(minSftpLimitBytes, maxSftpLimitBytes).toInt();
  }

  ThemeMode _themeModeFromPrefs(SharedPreferences prefs) {
    switch (prefs.getString(_themeModeKey)) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
    }

    if (prefs.containsKey(_darkModeKey)) {
      return prefs.getBool(_darkModeKey) == true
          ? ThemeMode.dark
          : ThemeMode.light;
    }

    return ThemeMode.light;
  }

  String _themeModeToName(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }

  Future<String> _readOrCreateMcpServerToken() async {
    final saved =
        (await _secureStorage.read(key: _mcpServerTokenSecureKey))?.trim();
    if (saved != null && saved.isNotEmpty) {
      return saved;
    }
    final token = McpServerSettings.generateToken();
    await _secureStorage.write(key: _mcpServerTokenSecureKey, value: token);
    AppLogService.instance.info('MCP server token generated');
    return token;
  }
}

class AppFontChoice {
  static const systemId = 'system';

  final String id;
  final String name;
  final String? fontFamily;
  final String licenseNote;
  final bool platformSpecific;
  final List<TargetPlatform>? supportedPlatforms;

  const AppFontChoice({
    required this.id,
    required this.name,
    required this.fontFamily,
    required this.licenseNote,
    this.platformSpecific = false,
    this.supportedPlatforms,
  });

  static const values = [
    AppFontChoice(
      id: systemId,
      name: 'System',
      fontFamily: null,
      licenseNote: 'Use platform default font.',
      platformSpecific: false,
      supportedPlatforms: TargetPlatform.values,
    ),
  ];

  static String normalize(String? id) {
    return systemId;
  }

  static AppFontChoice byId(String? id) {
    return values[0];
  }

  bool isLikelyAvailableOn(TargetPlatform platform) {
    return true;
  }
}

class AppStrings {
  final AppLanguage language;

  const AppStrings(this.language);

  bool get _en => language == AppLanguage.en;

  String get appTitle => 'SSH Mobile';
  String get switchToChinese => '中文';
  String get switchToEnglish => 'EN';
  String get switchToLightMode => _en ? 'Switch to light mode' : '切换到浅色主题';
  String get switchToDarkMode => _en ? 'Switch to dark mode' : '切换到深色主题';
  String get oledDarkMode => _en ? 'OLED Black Mode' : 'OLED 纯黑模式';
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
  String get editConnection => _en ? 'Edit connection' : '编辑连接';
  String get noConnections => _en ? 'No saved servers yet' : '还没有保存的服务器';
  String get addHint => _en ? 'Tap + to add a connection' : '点击右下角 + 添加连接';
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
  String selectedWindows(int count) =>
      _en ? '$count selected' : '已选择 $count 个窗口';
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
  String get closeWindow => _en ? 'Close window' : '关闭窗口';
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

  String get noConnectionHistory => _en ? 'No connection history' : '暂无连接历史';
  String get deleteHistoryRecord => _en ? 'Delete history record' : '删除历史记录';

  String get backgroundConnectionSettings =>
      _en ? 'Background connection settings' : '后台连接设置';
  String get enableBackgroundPermission =>
      _en ? 'Enable background connection permission' : '开启后台连接权限';
  String get backgroundPermissionGuide => _en
      ? 'The current platform has not confirmed unrestricted background power usage. SSH connections need background service and keep-alive support. Please allow SSH Mobile to run in the background, send notifications, and avoid power-saving rules that may interrupt background networking.'
      : '检测到当前平台尚未确认后台耗电无限制。SSH 连接需要后台服务和保活心跳支持，请允许 SSH Mobile 后台运行、发送通知，并关闭可能中断后台网络的省电限制。';
  String get adjustPowerLimit => _en ? 'Adjust power settings' : '调整省电限制';
  String get openAppSettings => _en ? 'Open app settings' : '打开应用设置';
  String get settings => _en ? 'Settings' : '设置';
  String get backgroundGuideNote => _en
      ? 'Setting names differ by platform. Look for permissions, battery, or background activity settings and allow SSH Mobile to keep running. You can continue this time; if the restriction is still detected next launch, this guide will appear again.'
      : '不同平台的设置名称可能不同，请在应用权限、电池或后台运行相关设置中允许 SSH Mobile 持续运行。本次可继续进入应用；如果下次启动时仍未放宽限制，将再次显示此引导。';
  String get enterApp => _en ? 'Enter app' : '进入应用';
  String get powerLimitExempt => _en ? 'Power restrictions relaxed' : '已放宽省电限制';
  String get powerLimitUnknown =>
      _en ? 'Power restriction status not confirmed' : '尚未确认省电限制状态';

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
  String get directory => _en ? 'Directory' : '文件夹';
  String get uploadFile => _en ? 'Upload file' : '上传文件';
  String get uploadComplete => _en ? 'Upload complete' : '上传完成';
  String uploadFailed(Object error) =>
      _en ? 'Upload failed: $error' : '上传失败：$error';
  String get viewFile => _en ? 'View file' : '查看文件';
  String get preview => _en ? 'Preview' : '预览';
  String get source => _en ? 'Source' : '源码';
  String previewFailed(Object error) =>
      _en ? 'Preview failed: $error' : '预览失败：$error';
  String get unsupportedPreview => _en
      ? 'Preview is not supported for this file type. Download it to open with another app.'
      : '暂不支持预览这种文件类型。可以下载后用其他应用打开。';
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
  String openEditorFailed(Object error) =>
      _en ? 'Unable to open editor: $error' : '无法打开编辑器：$error';
  String get saveComplete => _en ? 'Saved' : '已保存';
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
  String get moreActions => _en ? 'More actions' : '更多操作';
  String get navigationShell => _en ? 'Navigation & Shell' : '导航与 Shell';
  String get editControl => _en ? 'Edit & Control' : '编辑与控制';
  String get functionKeys => _en ? 'Function Keys' : '功能键';
}
