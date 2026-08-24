import 'dart:typed_data';

import '../transport/transport_connection.dart';

/// App Scope native runtime 的粗粒度 Command/Event 入口。
///
/// Gateway 只转发已经编码的 Network Protocol V2 frame，不理解 LAN、Relay
/// 或文件业务协议。
/// 它不拥有 native handle；关闭责任仍属于创建它的 [NetworkRuntime]。
abstract interface class NetworkCommandGateway {
  /// Rust helper isolate 发布的原始事件帧。
  Stream<Uint8List> get events;

  /// 向 Rust runtime 提交一个已经编码的 Network Protocol V2 command frame。
  TransportOperationStatus sendCommand(Uint8List command);
}
