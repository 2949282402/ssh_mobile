/// Relay Bootstrap API 规范定义的标准契约路由与常量。
abstract final class RelayBootstrapRoutes {
  /// 健康检查/存活探测路径。
  static const String healthz = '/healthz';

  /// 设备注册端点路径。
  static const String enrollV2 = '/v2/devices/enroll';

  /// 设备凭据刷新端点路径。
  static const String refreshV2 = '/v2/devices/refresh';

  /// 构造设备凭据刷新签名的 canonical transcript。
  static String buildRefreshTranscript(int timestamp, String nonce) =>
      'POST\n$refreshV2\n$timestamp\n$nonce';
}
