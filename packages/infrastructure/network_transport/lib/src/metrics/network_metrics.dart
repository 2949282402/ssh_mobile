// 网络运行时指标的稳定快照合约。
//
// 这里只定义跨模块可复用的只读数据，不启动 Timer、不采集网络，也不拥有
// 任何连接资源；采集责任由实际 Transport/Monitoring Owner 管理。

/// 一次网络观测的不可变指标快照。
final class NetworkMetricSnapshot {
  /// 创建网络指标快照。
  const NetworkMetricSnapshot({
    required this.capturedAt,
    this.roundTripTime,
    this.bytesSent = 0,
    this.bytesReceived = 0,
  }) : assert(bytesSent >= 0, 'bytesSent must not be negative'),
       assert(bytesReceived >= 0, 'bytesReceived must not be negative');

  /// 采样发生的时间。
  final DateTime capturedAt;

  /// 可选的往返延迟。
  final Duration? roundTripTime;

  /// 截止采样时已发送的字节数。
  final int bytesSent;

  /// 截止采样时已接收的字节数。
  final int bytesReceived;
}
