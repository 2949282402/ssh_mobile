// v1 LAN HTTP 错误响应解码测试，锁定稳定 code、operation 和 peer_id 语义。

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:feature_lan_share/feature_lan_share.dart';

/// 执行 LAN HTTP 错误模型测试。
void main() {
  /// 验证合法服务端错误会保留稳定上下文。
  test('decodes a v1 LAN HTTP error response', () {
    final exception = lanHttpException(
      statusCode: 403,
      body: const <String, dynamic>{
        'code': 2,
        'message': 'safe diagnostic',
        'operation': 'send_file',
        'peer_id': 'peer-a',
      },
      operation: NetworkOperation.sendFile,
      peerId: 'fallback-peer',
      fallbackMessage: 'fallback',
    );

    final error = exception.toNetworkError();
    expect(error.code, NetworkErrorCode.authenticationFailed);
    expect(error.message, 'safe diagnostic');
    expect(error.operation, NetworkOperation.sendFile);
    expect(error.peerId, 'peer-a');
  });

  /// 验证不完整响应会按 HTTP 状态回退且不泄露异常文本。
  test('falls back safely for an invalid LAN HTTP error response', () {
    final exception = lanHttpException(
      statusCode: 408,
      body: const <String, dynamic>{'message': 'line 1\nline 2'},
      operation: NetworkOperation.sendMeta,
      fallbackMessage: 'safe fallback',
    );

    final error = exception.toNetworkError();
    expect(error.code, NetworkErrorCode.timeout);
    expect(error.message, 'safe fallback');
    expect(error.operation, NetworkOperation.sendMeta);
  });
}
