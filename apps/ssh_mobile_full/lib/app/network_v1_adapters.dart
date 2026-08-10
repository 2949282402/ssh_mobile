// App Shell native v1 网络适配入口。
//
// NativeNetworkService 和手写 v1 codec 仍是 App Scope/native boundary，
// 不是 Feature 实现。调用方通过 network_sdk 的 typed contracts 使用它们。

export '../services/network/network_protocol_codec.dart';
export '../services/network/network_service.dart';
