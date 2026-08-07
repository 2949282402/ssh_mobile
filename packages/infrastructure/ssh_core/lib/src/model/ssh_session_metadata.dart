// SSH 会话聚合元数据。
//
// 该模型用于列表、监控和连接摘要，不持有任何底层连接资源。

import 'ssh_session.dart';

/// 单个 Connection 的 SSH 窗口摘要。
final class SshConnectionOverview {
  /// 空摘要。
  static const empty = SshConnectionOverview(
    count: 0,
    latestState: null,
    hasConnected: false,
  );

  /// 创建连接摘要。
  const SshConnectionOverview({
    required this.count,
    required this.latestState,
    required this.hasConnected,
  });

  /// 当前窗口数。
  final int count;

  /// 最近窗口状态。
  final SshConnectionState? latestState;

  /// 是否至少有一个窗口已连接。
  final bool hasConnected;

  @override
  bool operator ==(Object other) {
    return other is SshConnectionOverview &&
        other.count == count &&
        other.latestState == latestState &&
        other.hasConnected == hasConnected;
  }

  @override
  int get hashCode => Object.hash(count, latestState, hasConnected);
}

/// 所有 Connection 的 SSH 窗口聚合快照。
final class SshServerOverviewSnapshot {
  /// 创建聚合快照。
  const SshServerOverviewSnapshot({
    required this.byConnection,
    required this.windowCount,
  });

  /// 空聚合快照。
  const SshServerOverviewSnapshot.empty()
    : byConnection = const {},
      windowCount = 0;

  /// 按连接 id 分组的摘要。
  final Map<String, SshConnectionOverview> byConnection;

  /// 全部窗口数。
  final int windowCount;

  /// 读取指定连接的摘要，不存在时返回空值对象。
  SshConnectionOverview forConnection(String connectionId) {
    return byConnection[connectionId] ?? SshConnectionOverview.empty;
  }

  @override
  bool operator ==(Object other) {
    if (other is! SshServerOverviewSnapshot ||
        other.windowCount != windowCount ||
        other.byConnection.length != byConnection.length) {
      return false;
    }
    for (final entry in byConnection.entries) {
      if (other.byConnection[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    windowCount,
    Object.hashAllUnordered(
      byConnection.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
  );
}
