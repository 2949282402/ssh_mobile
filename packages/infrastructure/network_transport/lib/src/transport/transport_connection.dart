// 传输连接的稳定合约。
//
// 本 Step 不实现具体连接；SSH/SFTP/LAN Step 通过该合约接入对应协议，避免
// Feature 直接依赖 Socket、FFI handle 或某个 native SDK 的实现类。

import 'dart:typed_data';

import 'package:app_core/app_core.dart';

import 'transport_endpoint.dart';

/// 低层传输操作的类型化结果。
enum TransportOperationStatus {
  /// 操作已接受或完成。
  success,

  /// 请求参数无效。
  invalidArgument,

  /// 连接已停止或正在关闭。
  stopped,

  /// native 或底层 IO 返回了未分类失败。
  failure,
}

/// 具备明确 close/dispose 生命周期的传输连接。
abstract interface class TransportConnection implements Disposable {
  /// 当前连接的远端端点。
  TransportEndpoint get endpoint;

  /// 连接接收的原始数据；调用 close 后必须结束。
  Stream<Uint8List> get incoming;

  /// 发送一帧原始传输数据。
  Future<TransportOperationStatus> send(Uint8List payload);

  /// 显式关闭连接；重复调用必须安全。
  Future<void> close();
}
