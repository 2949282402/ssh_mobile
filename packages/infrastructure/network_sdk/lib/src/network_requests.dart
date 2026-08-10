import 'dart:typed_data';

/// 由 App Shell 提供的无状态控制面请求。
///
/// `network_sdk` 只消费这个粗粒度边界，不依赖 `dart:io`、HTTP package 或
/// 平台网络实现。实现方负责连接复用、TLS、代理和平台证书策略。
abstract interface class SdkRequestExecutor {
  Future<SdkResponse> execute(SdkRequest request);
}

/// 一次控制面请求的不可变描述。
final class SdkRequest {
  SdkRequest({
    required this.method,
    required this.uri,
    Map<String, String> headers = const <String, String>{},
    this.body,
  }) : headers = Map.unmodifiable(headers);

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Uint8List? body;
}

/// App Shell 请求执行器返回的脱敏响应。
final class SdkResponse {
  SdkResponse({
    required this.statusCode,
    required Uint8List body,
    Map<String, String> headers = const <String, String>{},
  }) : body = Uint8List.fromList(body),
       headers = Map.unmodifiable(headers);

  final int statusCode;
  final Uint8List body;
  final Map<String, String> headers;

  bool get isSuccessful => statusCode >= 200 && statusCode < 300;
}
