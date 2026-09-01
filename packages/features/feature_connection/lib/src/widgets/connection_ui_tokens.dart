/// Connection 页面专用的尺寸和输入默认值。
///
/// 这些值有明确的 UI/协议语义，集中在 Feature 内避免在表单各处重复
/// Magic Number；共享主题建立后再由 app_ui 统一承接视觉 Token。
abstract final class ConnectionUiTokens {
  static const radiusSmall = 6.0;
  static const radiusMedium = 8.0;
  static const radiusLarge = 12.0;
  static const pagePadding = 20.0;
  static const compactPagePadding = 14.0;
  static const defaultPortText = '22';
  static const defaultUsernameText = 'root';
  static const defaultTmuxDeleteMinutesText = '10';
  static const minPort = 1;
  static const maxPort = 65535;
  static const minTmuxDeleteMinutes = 1;
  static const maxTmuxDeleteMinutes = 1440;

  const ConnectionUiTokens._();
}
