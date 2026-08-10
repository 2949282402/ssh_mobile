// App Shell 对 network_sdk 请求执行器的最小平台适配。
//
// 该适配只负责短生命周期的控制面 HTTP 请求；Rust/native runtime 仍拥有
// LAN 数据面 Socket、长连接和传输状态。

import 'dart:io';
import 'dart:typed_data';

import 'package:network_sdk/network_sdk.dart';

/// 使用 Dart `HttpClient` 执行 SDK 控制面请求。
///
/// 每次请求都显式关闭临时 client，避免把 HTTP 连接池误认为 App Scope 数据面
/// Owner。SDK 的 timeout 和错误脱敏仍由 `Json*Client` 负责。
final class AppSdkRequestExecutor implements SdkRequestExecutor {
  const AppSdkRequestExecutor({this.maxResponseBytes = 64 * 1024});

  final int maxResponseBytes;

  @override
  Future<SdkResponse> execute(SdkRequest request) async {
    final client = HttpClient();
    try {
      final ioRequest = await client.openUrl(request.method, request.uri);
      request.headers.forEach((name, value) {
        if (name.toLowerCase() == 'content-length') return;
        ioRequest.headers.set(name, value);
      });
      final body = request.body;
      if (body != null && body.isNotEmpty) ioRequest.add(body);
      final response = await ioRequest.close();
      final responseBody = await _readBounded(response);
      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        headers[name] = values.join(',');
      });
      return SdkResponse(
        statusCode: response.statusCode,
        headers: headers,
        body: responseBody,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List> _readBounded(Stream<List<int>> source) async {
    final bytes = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in source) {
      total += chunk.length;
      if (total > maxResponseBytes) {
        throw const FormatException('SDK response is too large.');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }
}
