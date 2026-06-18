part of '../home_screen.dart';

extension _HomeSettingsStrings on AppStrings {
  String get settings => language == AppLanguage.en ? 'Settings' : '设置';
  String get appearance => language == AppLanguage.en ? 'Appearance' : '外观';
  String get toolsAndAutomation =>
      language == AppLanguage.en ? 'Tools & Automation' : '工具与自动化';
  String get aiSkillsHint => language == AppLanguage.en
      ? 'Manage custom AI prompts, workflows, and references'
      : '管理自定义 AI 提示词、工作流及规则说明';
  String get appFontFamily => language == AppLanguage.en ? 'App font' : '应用字体';
  String get appFontFamilyNote => language == AppLanguage.en
      ? 'Applied across the app. Font files are not bundled.'
      : '全局统一使用。应用不内置字体文件。';
  String get security => language == AppLanguage.en ? 'Security' : '安全';
  String get credentialCache => language == AppLanguage.en
      ? 'Cache SSH credentials in memory'
      : '缓存 SSH 凭证到内存。';
  String get credentialCacheHint => language == AppLanguage.en
      ? 'Reduce repeated Keychain prompts by caching passwords, private keys, and API keys in-memory during this session.'
      : '在本次会话内缓存密码、私钥和 API Key，可减少重复的密钥链弹窗。';
  String credentialCacheTimeoutLabel(int minutes) => language == AppLanguage.en
      ? 'Cache timeout (${minutes}m)'
      : '缓存时长 (${minutes}m)';
  String get notificationServerNames => language == AppLanguage.en
      ? 'Show server names in background notifications'
      : '后台通知显示服务器名';
  String get notificationServerNamesHint => language == AppLanguage.en
      ? 'Off by default. Keep it off to avoid exposing server names on the lock screen.'
      : '默认关闭。保持关闭可避免在锁屏通知中暴露服务器名称。';
  String get dataBackup => language == AppLanguage.en ? 'Data backup' : '数据备份';
  String get sftpLimits =>
      language == AppLanguage.en ? 'SFTP file limits' : 'SFTP 文件限制';
  String get sftpLimitsHint => language == AppLanguage.en
      ? 'Client-side limits for in-memory download, preview, and editing.'
      : '用于客户端下载、预览和编辑的内存保护限制。';
  String get sftpDownloadLimit =>
      language == AppLanguage.en ? 'Download limit' : '下载限制';
  String get sftpTextPreviewLimit =>
      language == AppLanguage.en ? 'Text preview limit' : '文本预览限制';
  String get sftpRichPreviewLimit =>
      language == AppLanguage.en ? 'Image/PDF preview limit' : '图片/PDF 预览限制';
  String get sftpEditLimit =>
      language == AppLanguage.en ? 'Text edit limit' : '文本编辑限制';
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
      ? 'Importing will replace saved servers, window history, AI chats, AI settings, and custom skills. Passwords, private keys, and API keys must be configured again. Continue?'
      : '导入会替换当前设备上的服务器、窗口历史、AI 聊天、AI 设置和自定义 Skills。密码、私钥和 API Key 需要重新配置。是否继续？';
  String get backupContainsSecrets => language == AppLanguage.en
      ? 'Passwords, private keys, and API keys are not exported. Reconfigure them after import.'
      : '密码、私钥和 API Key 不会导出，导入后需要重新配置。';
  String exportFailed(Object error) =>
      language == AppLanguage.en ? 'Export failed: $error' : '导出失败：$error';
  String importFailed(Object error) =>
      language == AppLanguage.en ? 'Import failed: $error' : '导入失败：$error';
}

extension _HomeFontSettingStrings on AppStrings {
  String get appFontPreview =>
      language == AppLanguage.en ? 'Font preview' : '字体预览';
  String get appFontCurrent =>
      language == AppLanguage.en ? 'Current font' : '当前字体';
  String get fontFallbackHint => language == AppLanguage.en
      ? 'If this font is unavailable on your device, system fallback will be used.'
      : '如该字体在设备上不存在，系统将自动回退到默认字体。';
  String get fontPlatformHint => language == AppLanguage.en
      ? 'Font availability depends on platform resources; install the font to force direct usage.'
      : '字体是否可用取决于平台资源，若需要可安装该字体后再使用。';
}
