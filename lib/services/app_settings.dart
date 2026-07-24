import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../theme/app_theme.dart';
import '../utils/device_name_util.dart';
import 'app_log_service.dart';
import 'mcp/mcp_server_settings.dart';

part 'app_strings.dart';

enum AppLanguage { zh, en }

@immutable
class AppVisualSettingsSnapshot {
  const AppVisualSettingsSnapshot({
    required this.themeMode,
    required this.oledDark,
    required this.colorPalette,
  });

  final ThemeMode themeMode;
  final bool oledDark;
  final AppColorPalette colorPalette;

  @override
  bool operator ==(Object other) =>
      other is AppVisualSettingsSnapshot &&
      other.themeMode == themeMode &&
      other.oledDark == oledDark &&
      other.colorPalette == colorPalette;

  @override
  int get hashCode => Object.hash(themeMode, oledDark, colorPalette);
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
  static const _colorPaletteKey = 'color_palette';
  static const _terminalThemeIdKey = 'terminal_theme_id';
  static const _terminalFontFamilyKey = 'terminal_font_family';
  static const _serverListLayoutModeKey = 'server_list_layout_mode';
  static const _lanDeviceIdKey = 'lan_device_id';
  static const _lanDeviceAliasKey = 'lan_device_alias';
  static const _developerModeKey = 'developer_mode';
  static const _developerPanelFloatingKey = 'developer_panel_floating';
  static const int minSftpLimitBytes = 64 * 1024;
  static const int maxSftpLimitBytes = 2 * 1024 * 1024 * 1024;
  static const int defaultSftpDownloadLimitBytes = 512 * 1024 * 1024;
  static const int defaultSftpTextPreviewLimitBytes = 2 * 1024 * 1024;
  static const int defaultSftpRichPreviewLimitBytes = 20 * 1024 * 1024;
  static const int defaultSftpTextEditLimitBytes = 512 * 1024;

  AppLanguage _language = AppLanguage.zh;
  ThemeMode _themeMode = ThemeMode.light;
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
  bool _mcpEnableSse = false;
  bool _oledDark = false;
  AppColorPalette _colorPalette = AppColorPalette.monochrome;
  String _terminalThemeId = 'default';
  String _terminalFontFamily = '';
  String _serverListLayoutMode = 'list';
  String _lanDeviceId = '';
  String _lanDeviceAlias = '';
  bool _developerMode = false;
  bool _developerPanelFloating = false;
  bool _coreLoaded = false;
  bool _initialized = false;
  Future<void>? _coreLoadFuture;
  final Completer<void> _initCompleter = Completer<void>();
  Future<void> _themeWrite = Future.value();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  AppLanguage get language => _language;
  ThemeMode get themeMode => _themeMode;
  String get lanDeviceId => _lanDeviceId;
  String get lanDeviceAlias => _lanDeviceAlias;
  AppVisualSettingsSnapshot get visualSettings => AppVisualSettingsSnapshot(
    themeMode: _themeMode,
    oledDark: _oledDark,
    colorPalette: _colorPalette,
  );
  bool get coreLoaded => _coreLoaded;
  bool get initialized => _initialized;
  Future<void> get initFuture => _initCompleter.future;
  bool get isEnglish => _language == AppLanguage.en;
  bool get isDarkMode => _themeMode == ThemeMode.dark;
  bool get ragEnabled => _ragEnabled;
  String get ragSearchMode => _ragSearchMode;
  int get ragTopN => _ragTopN;
  bool get showServerNamesInNotifications => _showServerNamesInNotifications;
  int get sftpDownloadLimitBytes => _sftpDownloadLimitBytes;
  int get sftpTextPreviewLimitBytes => _sftpTextPreviewLimitBytes;
  int get sftpRichPreviewLimitBytes => _sftpRichPreviewLimitBytes;
  int get sftpTextEditLimitBytes => _sftpTextEditLimitBytes;
  bool get mcpServerEnabled => _mcpServerEnabled;
  String get mcpServerHost => _mcpServerHost;
  int get mcpServerPort => _mcpServerPort;
  String get mcpServerToken => _mcpServerToken;
  bool get mcpAllowWriteTools => _mcpAllowWriteTools;
  bool get mcpRequireApprovalForWriteTools => true;
  bool get mcpEnableSse => _mcpEnableSse;
  bool get oledDark => _oledDark;
  AppColorPalette get colorPalette => _colorPalette;
  String get terminalThemeId => _terminalThemeId;
  String get terminalFontFamily => _terminalFontFamily;
  String get serverListLayoutMode => _serverListLayoutMode;
  bool get developerMode => _developerMode;
  bool get developerPanelFloating => _developerPanelFloating;
  McpServerSettings get mcpSettings => McpServerSettings(
    enabled: _mcpServerEnabled,
    host: _mcpServerHost,
    port: _mcpServerPort,
    token: _mcpServerToken,
    allowWriteTools: _mcpAllowWriteTools,
    requireApprovalForWriteTools: true,
    enableSse: _mcpEnableSse,
  );

  /// 仅加载核心偏好设置（语言、主题Mode、色板、SFTP限制等），不引发网络/SecureStorage/设备名查找
  Future<void> ensureCoreLoaded() {
    if (_coreLoaded) return Future<void>.value();
    return _coreLoadFuture ??= _loadCoreSettings();
  }

  Future<void> _loadCoreSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 3),
      );
      final languageName = prefs.getString(_languageKey);
      _language = languageName == AppLanguage.en.name
          ? AppLanguage.en
          : AppLanguage.zh;
      _themeMode = _themeModeFromPrefs(prefs);
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
      if (prefs.getBool(_mcpRequireApprovalForWriteToolsKey) != true) {
        await prefs.setBool(_mcpRequireApprovalForWriteToolsKey, true);
      }
      _mcpEnableSse = prefs.getBool(_mcpEnableSseKey) ?? false;
      _oledDark = prefs.getBool(_oledDarkKey) ?? false;
      final colorPaletteName = prefs.getString(_colorPaletteKey);
      _colorPalette = AppColorPalette.values.firstWhere(
        (palette) => palette.name == colorPaletteName,
        orElse: () => AppColorPalette.monochrome,
      );
      _terminalThemeId = prefs.getString(_terminalThemeIdKey) ?? 'default';
      _terminalFontFamily = prefs.getString(_terminalFontFamilyKey) ?? '';
      _serverListLayoutMode =
          prefs.getString(_serverListLayoutModeKey) ?? 'list';
      _developerMode = prefs.getBool(_developerModeKey) ?? false;
      _developerPanelFloating =
          prefs.getBool(_developerPanelFloatingKey) ?? false;
      _coreLoaded = true;
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Failed to load core AppSettings',
        error: e,
        stackTrace: stackTrace,
      );
      _language = AppLanguage.zh;
      _themeMode = ThemeMode.light;
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
      _mcpAllowWriteTools = false;
      _mcpEnableSse = false;
      _oledDark = false;
      _colorPalette = AppColorPalette.monochrome;
      _terminalThemeId = 'default';
      _terminalFontFamily = '';
      _serverListLayoutMode = 'list';
      _developerMode = false;
      _developerPanelFloating = false;
      _coreLoaded = true;
    } finally {
      _coreLoadFuture = null;
      notifyListeners();
    }
  }

  /// 按需读取或生成 MCP Token
  Future<void> ensureMcpToken() async {
    if (_mcpServerToken.isNotEmpty) return;
    _mcpServerToken = await _readOrCreateMcpServerToken();
  }

  /// 按需读取或生成 LAN 设备 Identity 与设备名称
  Future<void> ensureLanIdentity() async {
    if (_lanDeviceId.isNotEmpty && _lanDeviceAlias.isNotEmpty) return;
    final prefs = await SharedPreferences.getInstance();

    if (_lanDeviceId.isEmpty) {
      String secureId = '';
      try {
        secureId = await _secureStorage.read(key: _lanDeviceIdKey) ?? '';
      } catch (_) {}

      final prefsId = prefs.getString(_lanDeviceIdKey) ?? '';

      if (secureId.isNotEmpty) {
        _lanDeviceId = secureId;
        if (prefsId != secureId) {
          await prefs.setString(_lanDeviceIdKey, secureId);
        }
      } else if (prefsId.isNotEmpty) {
        _lanDeviceId = prefsId;
        try {
          await _secureStorage.write(key: _lanDeviceIdKey, value: prefsId);
        } catch (_) {}
      } else {
        _lanDeviceId = const Uuid().v4();
        await prefs.setString(_lanDeviceIdKey, _lanDeviceId);
        try {
          await _secureStorage.write(key: _lanDeviceIdKey, value: _lanDeviceId);
        } catch (_) {}
      }
    }

    if (_lanDeviceAlias.isEmpty) {
      _lanDeviceAlias = prefs.getString(_lanDeviceAliasKey) ?? '';
      if (_lanDeviceAlias.isEmpty) {
        _lanDeviceAlias = await getDeviceName();
        await prefs.setString(_lanDeviceAliasKey, _lanDeviceAlias);
      }
    }
  }

  Future<void> init() async {
    try {
      await ensureCoreLoaded();
      await ensureMcpToken();
      await ensureLanIdentity();
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

  Future<void> setLanDeviceAlias(String alias) async {
    if (_lanDeviceAlias == alias) return;
    _lanDeviceAlias = alias;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lanDeviceAliasKey, alias);
    AppLogService.instance.info(
      'LAN device alias updated',
      details: 'alias=$alias',
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
    final nextMode = _themeMode == ThemeMode.dark
        ? ThemeMode.light
        : ThemeMode.dark;
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

  Future<void> setColorPalette(AppColorPalette palette) async {
    if (_colorPalette == palette) return;
    _colorPalette = palette;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_colorPaletteKey, palette.name);
    AppLogService.instance.info(
      'Color palette setting updated',
      details: 'palette=${palette.name}',
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
    final saved = (await _secureStorage.read(
      key: _mcpServerTokenSecureKey,
    ))?.trim();
    if (saved != null && saved.isNotEmpty) {
      return saved;
    }
    final token = McpServerSettings.generateToken();
    await _secureStorage.write(key: _mcpServerTokenSecureKey, value: token);
    AppLogService.instance.info('MCP server token generated');
    return token;
  }

  Future<void> setDeveloperMode(bool value) async {
    if (_developerMode == value) return;
    _developerMode = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_developerModeKey, value);
    AppLogService.instance.info(
      'Developer mode updated',
      details: 'developerMode=$value',
    );
  }

  Future<void> setDeveloperPanelFloating(bool value) async {
    if (_developerPanelFloating == value) return;
    _developerPanelFloating = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_developerPanelFloatingKey, value);
    AppLogService.instance.info(
      'Developer panel floating updated',
      details: 'developerPanelFloating=$value',
    );
  }
}
