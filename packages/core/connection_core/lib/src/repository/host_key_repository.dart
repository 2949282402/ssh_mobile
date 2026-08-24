/// SSH Host Key 信任元数据的公共契约。
///
/// 指纹属于连接路由安全边界，但不是密码或私钥；它可以和 Connection
/// 结构一起存储，任何更新都必须绑定正确的连接 id。
abstract interface class HostKeyRepository {
  /// 记录用户确认过的 Host Key 指纹和算法。
  ///
  /// [fingerprint] 为空时清除现有信任，供端点修改和跨存储补偿回滚使用。
  Future<void> trustHostKey(
    String connectionId, {
    required String? algorithm,
    required String? fingerprint,
    required DateTime? trustedAt,
  });
}
