// network_transport 的公共入口。
//
// Package 外部只能依赖这里导出的稳定 Facade/Contract，不得跨包引用 src 目录。

export 'src/config/network_config.dart';
export 'src/metrics/network_metrics.dart';
export 'src/native/network_command_gateway.dart';
export 'src/native/native_network_adapter.dart';
export 'src/realtime/network_realtime_gateway.dart';
export 'src/runtime/network_capability.dart';
export 'src/runtime/network_runtime.dart';
export 'src/runtime/network_runtime_impl.dart';
export 'src/transport/transport_connection.dart';
export 'src/transport/transport_endpoint.dart';
