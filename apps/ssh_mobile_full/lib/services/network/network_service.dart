// App Shell Network Protocol V2 Facade。
//
// 公开服务只负责组合生命周期、命令、事件和领域适配器；具体职责位于
// 同一 App Shell library 的拆分 part 中，避免再次形成跨层的 Network God Object。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';
import 'package:uuid/uuid.dart';

import 'network_protocol_v2_codec.dart';
import '../telemetry/telemetry_span.dart';

part 'network_service_command_coordinator.dart';
part 'network_service_event_hub.dart';
part 'network_service_event_router.dart';
part 'network_service_lifecycle.dart';
part 'network_service_peer_adapter.dart';
part 'network_service_relay_adapter.dart';
part 'network_service_route_adapter.dart';
part 'network_service_runtime_gateway.dart';
part 'network_service_state_projection.dart';
part 'network_service_support.dart';
part 'network_service_transfer_adapter.dart';

/// 将原生 Network Protocol V2 运行时适配为 Flutter 的类型化网络契约。
///
/// 该类是兼容入口和组合根；命令确认、领域操作、状态投影及 Runtime
/// 生命周期分别由内部端口拥有。它不改变 [NetworkService] 的公共 API。
final class NativeNetworkService implements NetworkService {
  /// 基于已创建的原生运行时创建服务，并拥有该运行时。
  NativeNetworkService(
    NativeNetworkRuntime runtime, {
    NetworkProtocolV2Codec? codec,
    this._traceRegistry,
  }) : _gateway = _NativeRuntimeCommandGateway(runtime),
       _ownedRuntime = runtime,
       _codec = codec ?? const NetworkProtocolV2Codec() {
    _initialize();
  }

  /// 基于 AppRuntime 共享的 gateway 创建服务。
  ///
  /// 该构造方式只拥有自己的 command/event subscription，不拥有
  /// NetworkRuntime 或 native handle；最终资源由 AppRuntime 释放。
  NativeNetworkService.fromGateway(
    NetworkCommandGateway gateway, {
    NetworkProtocolV2Codec? codec,
    this._traceRegistry,
  }) : _gateway = gateway,
       _ownedRuntime = null,
       _codec = codec ?? const NetworkProtocolV2Codec() {
    _initialize();
  }

  final NetworkCommandGateway _gateway;
  final NativeNetworkRuntime? _ownedRuntime;
  final NetworkProtocolV2Codec _codec;
  final TelemetryTraceRegistry? _traceRegistry;
  final _NetworkServiceState _state = _NetworkServiceState();
  final _NetworkEventHub _eventHub = _NetworkEventHub();

  late final _NetworkCommandCoordinator _commands;
  late final _NetworkStateProjection _projection;
  late final _NetworkEventRouter _eventRouter;
  late final _NetworkRuntimeLifecycle _lifecycle;
  late final _NetworkPeerAdapter _peerAdapter;
  late final _NetworkRelayAdapter _relayAdapter;
  late final _NetworkRouteAdapter _routeAdapter;
  late final _NetworkTransferAdapter _transferAdapter;

  void _initialize() {
    _commands = _NetworkCommandCoordinator(
      gateway: _gateway,
      codec: _codec,
      state: _state,
      traceRegistry: _traceRegistry,
    );
    _projection = _NetworkStateProjection();
    _eventRouter = _NetworkEventRouter(
      gateway: _gateway,
      commands: _commands,
      projection: _projection,
      eventHub: _eventHub,
    );
    _lifecycle = _NetworkRuntimeLifecycle(
      ownedRuntime: _ownedRuntime,
      codec: _codec,
      commands: _commands,
      eventRouter: _eventRouter,
      eventHub: _eventHub,
      state: _state,
    );
    _peerAdapter = _NetworkPeerAdapter(
      codec: _codec,
      commands: _commands,
      eventHub: _eventHub,
      projection: _projection,
      traceRegistry: _traceRegistry,
    );
    _relayAdapter = _NetworkRelayAdapter(
      codec: _codec,
      commands: _commands,
      eventHub: _eventHub,
    );
    _routeAdapter = _NetworkRouteAdapter(
      commands: _commands,
      projection: _projection,
    );
    _transferAdapter = _NetworkTransferAdapter(
      codec: _codec,
      commands: _commands,
      projection: _projection,
    );
  }

  /// 消费内部命令结果后发布公开的类型化事件。
  @override
  Stream<NetworkEvent> get events => _eventHub.stream;

  /// 启动原生运行时，并等待对应的命令结果事件。
  @override
  Future<NetworkResult<void>> start(NetworkRuntimeConfig config) =>
      _lifecycle.start(config);

  /// 停止原生运行时，并关闭公开事件流。
  @override
  Future<NetworkResult<void>> stop() => _lifecycle.stop();

  /// 在原生运行时新增或替换对端。
  @override
  Future<NetworkResult<void>> upsertPeer(PeerConfig peer) =>
      _peerAdapter.upsertPeer(peer);

  @override
  Future<NetworkResult<void>> removePeer(String peerId) =>
      _peerAdapter.removePeer(peerId);

  /// 接受对端连接任务，并等待最终的 connected/failed 状态。
  @override
  Future<NetworkResult<void>> connect(
    String peerId, {
    CommunicationClass communicationClass = CommunicationClass.reliableStream,
  }) => _peerAdapter.connect(peerId, communicationClass: communicationClass);

  /// 接受对端断开任务，并等待命令确认。
  @override
  Future<NetworkResult<void>> disconnect(String peerId) =>
      _peerAdapter.disconnect(peerId);

  /// 配置原生 Relay 数据面，并等待 socket 认证终态。
  @override
  Future<NetworkResult<void>> configureRelay(RelayConfig config) =>
      _relayAdapter.configure(config);

  /// 请求断开原生 Relay。
  @override
  Future<NetworkResult<void>> disconnectRelay() => _relayAdapter.disconnect();

  /// 注册源文件传输，并返回已接受的传输会话。
  @override
  Future<NetworkResult<TransferSession>> send({
    required String transferId,
    required String peerId,
    required String filePath,
  }) => _transferAdapter.send(
    transferId: transferId,
    peerId: peerId,
    filePath: filePath,
  );

  /// 请求取消已接受的传输。
  @override
  Future<NetworkResult<void>> cancel(String transferId) =>
      _transferAdapter.cancel(transferId);

  /// 接受或拒绝原生传入传输申请。
  @override
  Future<NetworkResult<void>> respondToIncoming({
    required String transferId,
    required bool accept,
  }) => _transferAdapter.respondToIncoming(
    transferId: transferId,
    accept: accept,
  );

  /// 返回最近观察到的 [peerId] 类型化路由快照。
  @override
  Future<NetworkResult<RouteSnapshot>> state(String peerId) =>
      _routeAdapter.state(peerId);

  /// 释放服务自己的订阅、命令和状态；共享 Runtime 仍由 AppRuntime 负责。
  @override
  Future<void> dispose() => _lifecycle.dispose();
}
