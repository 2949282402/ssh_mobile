// 传输端点值对象。
//
// 端点只负责表达和校验地址，不负责建立 Socket 或调用 native API。

/// 稳定传输协议标识，供端点和后续连接实现复用。
enum TransportProtocol {
  /// TCP 流式传输。
  tcp,

  /// UDP 数据报传输。
  udp,

  /// QUIC 传输。
  quic,

  /// HTTPS/WSS Relay 传输。
  webSocketRelay,
}

/// 不可变的传输端点描述。
final class TransportEndpoint {
  /// 创建一个传输端点。
  const TransportEndpoint({
    required this.protocol,
    required this.host,
    required this.port,
    this.path = '',
  }) : assert(host != '', 'host must not be empty'),
       assert(port > 0 && port <= 65535, 'port must be valid');

  /// 从 URI 创建端点，并拒绝当前 Facade 未识别的 Scheme。
  factory TransportEndpoint.fromUri(Uri uri) {
    final protocol = switch (uri.scheme.toLowerCase()) {
      'tcp' => TransportProtocol.tcp,
      'udp' => TransportProtocol.udp,
      'quic' => TransportProtocol.quic,
      'wss' => TransportProtocol.webSocketRelay,
      _ => throw FormatException('Unsupported transport scheme: ${uri.scheme}'),
    };
    if (uri.host.isEmpty || uri.port <= 0 || uri.port > 65535) {
      throw const FormatException(
        'Transport endpoint host or port is invalid.',
      );
    }
    return TransportEndpoint(
      protocol: protocol,
      host: uri.host,
      port: uri.port,
      path: uri.path,
    );
  }

  /// 端点所使用的传输协议。
  final TransportProtocol protocol;

  /// DNS 名称或 IP 地址；不包含端口。
  final String host;

  /// 端口号，范围为 1 到 65535。
  final int port;

  /// Relay 端点的可选路径；普通传输端点通常为空。
  final String path;

  /// 将端点转换为可记录和传递的 URI。
  Uri get uri => Uri(
    scheme: switch (protocol) {
      TransportProtocol.tcp => 'tcp',
      TransportProtocol.udp => 'udp',
      TransportProtocol.quic => 'quic',
      TransportProtocol.webSocketRelay => 'wss',
    },
    host: host,
    port: port,
    path: path,
  );

  @override
  bool operator ==(Object other) =>
      other is TransportEndpoint &&
      other.protocol == protocol &&
      other.host == host &&
      other.port == port &&
      other.path == path;

  @override
  int get hashCode => Object.hash(protocol, host, port, path);

  @override
  String toString() => uri.toString();
}
