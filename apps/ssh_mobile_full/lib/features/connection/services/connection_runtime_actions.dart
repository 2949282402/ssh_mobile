/// 旧路径兼容转导出；具体 App Service 适配器位于 App 组合根。
library;

export 'package:feature_connection/feature_connection.dart'
    show ConnectionRuntimePort;

/// 旧缓存清理调用点的兼容占位。
final class SftpCacheMaintenance {
  const SftpCacheMaintenance._();

  static void clearCacheForConnection(String connectionId) {
    // Step 06 不改变既有缓存策略；真实清理 Owner 在 SFTP 模块迁移时接入。
  }
}
