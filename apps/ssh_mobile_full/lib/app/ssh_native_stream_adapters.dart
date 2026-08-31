// SSH 到 native ReliableStream 的 App Shell 适配器。
//
// [AppSshNativeStreamConnector] 是 ssh_core `SshNativeStreamConnector` 的 App
// 实现：它借用 AppRuntime-owned 的 native command gateway，先通过
// `NetworkFacade.connectPeer(communicationClass: reliableStream)` 建立对端连接，
// 再发送 `SshStreamOpen` 命令，并把 `SshStreamDataReceived` / `SshStreamClosed`
// 事件按完整 NativeStreamHandle 路由到对应的 [SshNativeStream]（dartssh2 仍负责 SSH/SFTP 协议）。

// ignore_for_file: prefer_initializing_formals
// Public named parameters intentionally initialize private owner fields.

import 'dart:async';
import 'dart:typed_data';

import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_core/ssh_core.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

import '../services/telemetry/telemetry_span.dart';

part 'ssh_native_stream.dart';

/// 打开 AppRuntime-owned native command gateway 的提供者。
typedef SshNativeGatewayProvider = Future<NetworkCommandGateway> Function();

/// 提供当前 runtime 的稳定本地设备身份。
typedef SshNativeOpenerDeviceIdProvider = Future<String> Function();

/// Lazily resolves the App-owned network facade after composition completes.
typedef SshNetworkFacadeProvider = NetworkFacade? Function();

/// 基于 native ReliableStream 的 SSH 流连接器。
final class AppSshNativeStreamConnector implements SshNativeStreamConnector {
  static const int _minStreamId = 1;
  static const int _maxStreamId = 0xffff;

  /// 创建连接器。
  ///
  /// [gatewayProvider] 惰性打开共享 native gateway；[facade] 用于
  /// `connectPeer`（可省略：省略时假定 peer 已连接）。
  AppSshNativeStreamConnector({
    required SshNativeGatewayProvider gatewayProvider,
    required SshNativeOpenerDeviceIdProvider openerDeviceIdProvider,
    NetworkFacade? facade,
    SshNetworkFacadeProvider? facadeProvider,
    TelemetryTraceRegistry? traceRegistry,
  }) : _gatewayProvider = gatewayProvider,
       _openerDeviceIdProvider = openerDeviceIdProvider,
       _facade = facade,
       _facadeProvider = facadeProvider,
       _traceRegistry = traceRegistry;

  final SshNativeGatewayProvider _gatewayProvider;
  final SshNativeOpenerDeviceIdProvider _openerDeviceIdProvider;
  final NetworkFacade? _facade;
  final SshNetworkFacadeProvider? _facadeProvider;
  final TelemetryTraceRegistry? _traceRegistry;
  final Map<String, bool> _connectedPeers = <String, bool>{};
  final Map<String, Future<void>> _peerConnectOperations =
      <String, Future<void>>{};
  final Map<String, String> _peerTraceIds = <String, String>{};
  final Map<NativeStreamHandle, _AppSshNativeStream> _streams =
      <NativeStreamHandle, _AppSshNativeStream>{};
  // 等待 native CommandResult 确认的 SshStreamOpen：commandId → StreamHandle。
  final Map<String, NativeStreamHandle> _pendingOpens =
      <String, NativeStreamHandle>{};
  // Accepted open commands remain traceable until the stream's terminal
  // close/failure event. The native protocol has no trace field, so retaining
  // this command-to-handle edge is the only safe late-result boundary.
  final Map<NativeStreamHandle, String> _acceptedOpenCommands =
      <NativeStreamHandle, String>{};

  NetworkCommandGateway? _gateway;
  Future<NetworkCommandGateway>? _gatewayFuture;
  Future<String>? _openerDeviceIdFuture;
  StreamSubscription<Uint8List>? _nativeSubscription;
  int _nextStreamId = _minStreamId;
  int _commandSequence = 0;
  bool _closed = false;

  /// 当前登记的活跃 native 流数量（诊断）。
  int get activeStreamCount => _streams.length;

  @override
  Future<SshNativeStream> open({
    required String peerId,
    String service = kSshNativeStreamService,
    String? traceId,
  }) async {
    _ensureOpen();
    final openerDeviceId = await _ensureOpenerDeviceId();
    _ensureOpen();
    final gateway = await _ensureGateway();
    _ensureOpen();
    if (_facade != null || _facadeProvider != null) {
      await _ensurePeerConnected(peerId, traceId: traceId);
      _ensureOpen();
    }

    final handle = _allocateStreamHandle(openerDeviceId);
    final stream = _AppSshNativeStream(
      connector: this,
      peerId: peerId,
      handle: handle,
    );
    _streams[handle] = stream;
    final commandId = _nextCommandId('ssh-open');
    _pendingOpens[commandId] = handle;
    if (traceId != null && _traceRegistry != null) {
      _traceRegistry.bindCommand(
        commandId: commandId,
        peerId: peerId,
        traceId: traceId,
      );
    }
    final status = gateway.sendCommand(
      NativeNetworkProtocol.sshStreamOpenCommand(
        commandId: commandId,
        peerId: peerId,
        handle: handle,
        service: service,
      ),
    );
    if (status != TransportOperationStatus.success) {
      _streams.remove(handle);
      _pendingOpens.remove(commandId);
      _traceRegistry?.completeCommand(commandId);
      _releasePeerWhenNoStreams(peerId);
      throw StateError(
        'Failed to queue native SSH stream open: ${status.name}.',
      );
    }
    return stream;
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('The native SSH stream connector is closed.');
    }
  }

  NativeStreamHandle _allocateStreamHandle(String openerDeviceId) {
    final firstCandidate = _nextStreamId;
    var streamId = firstCandidate;
    do {
      final handle = NativeStreamHandle(
        openerDeviceId: openerDeviceId,
        streamId: streamId,
      );
      _nextStreamId = streamId == _maxStreamId ? _minStreamId : streamId + 1;
      if (!_streams.containsKey(handle)) return handle;
      streamId = _nextStreamId;
    } while (streamId != firstCandidate);
    throw StateError('ReliableStream stream ID namespace is exhausted.');
  }

  Future<String> _ensureOpenerDeviceId() {
    final existing = _openerDeviceIdFuture;
    if (existing != null) return existing;
    late final Future<String> future;
    future = _openerDeviceIdProvider().then((deviceId) {
      if (deviceId.isEmpty) {
        throw StateError('The local opener device ID is unavailable.');
      }
      return deviceId;
    });
    _openerDeviceIdFuture = future;
    future.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        if (identical(_openerDeviceIdFuture, future)) {
          _openerDeviceIdFuture = null;
        }
      },
    );
    return future;
  }

  Future<NetworkCommandGateway> _ensureGateway() {
    final current = _gateway;
    if (current != null) return Future<NetworkCommandGateway>.value(current);
    final existing = _gatewayFuture;
    if (existing != null) return existing;

    late final Future<NetworkCommandGateway> future;
    future = _gatewayProvider();
    _gatewayFuture = future;
    future.then<void>(
      (gateway) {
        if (!identical(_gatewayFuture, future) || _closed) return;
        _gatewayFuture = null;
        _gateway = gateway;
        _nativeSubscription = gateway.events.listen(_onRawEvent);
      },
      onError: (Object _, StackTrace _) {
        if (identical(_gatewayFuture, future)) _gatewayFuture = null;
      },
    );
    return future;
  }

  Future<void> _ensurePeerConnected(String peerId, {String? traceId}) {
    if (_connectedPeers.containsKey(peerId)) return Future<void>.value();
    final existing = _peerConnectOperations[peerId];
    if (existing != null) return existing;

    late final Future<void> operation;
    operation = _connectPeer(peerId, traceId: traceId).whenComplete(() {
      if (identical(_peerConnectOperations[peerId], operation)) {
        _peerConnectOperations.remove(peerId);
      }
    });
    _peerConnectOperations[peerId] = operation;
    return operation;
  }

  Future<void> _connectPeer(String peerId, {String? traceId}) async {
    final facade = _facade ?? _facadeProvider?.call();
    if (facade == null) {
      throw StateError(
        'Native network facade is unavailable; cannot connect SSH peer.',
      );
    }

    if (traceId != null && _traceRegistry != null) {
      _traceRegistry.bindPeer(peerId: peerId, traceId: traceId);
      _peerTraceIds[peerId] = traceId;
    }
    try {
      final result = await facade.connectPeer(
        peerId,
        communicationClass: CommunicationClass.reliableStream,
      );
      if (result is SdkFailure<void>) {
        throw StateError(
          'Failed to connect peer $peerId: ${result.error.message}',
        );
      }
      _ensureOpen();
      _connectedPeers[peerId] = true;
    } catch (_) {
      final operationTraceId = _peerTraceIds.remove(peerId);
      if (operationTraceId != null) {
        _traceRegistry?.releasePeerTrace(
          peerId: peerId,
          traceId: operationTraceId,
        );
      }
      rethrow;
    }
  }

  void _onRawEvent(Uint8List bytes) {
    if (_closed) return;
    final event = NativeNetworkProtocol.decodeEvent(bytes);
    switch (event) {
      case NativeSshStreamDataReceivedEvent(:final handle, :final data):
        _streams[handle]?._onData(data);
      case NativeSshStreamClosedEvent(:final handle):
        final stream = _removeStream(handle);
        stream?._onClosed();
      case NativeCommandResultEvent(
        :final commandId,
        :final accepted,
        :final error,
      ):
        // SshStreamOpen 被 native 同步拒绝（例如对端未连接）时，CommandResult
        // accepted=false；必须让 open 返回的流立即失败，而不是被 default 丢弃
        // 导致 done 永久挂起。
        final handle = _pendingOpens.remove(commandId);
        if (handle == null) {
          // A duplicate/late result has no live stream terminal boundary. Do
          // not retain an unknown command context that can never be released
          // by one. A duplicate for an accepted live stream is ignored so it
          // cannot erase that operation's still-valid correlation edge.
          if (!_acceptedOpenCommands.containsValue(commandId)) {
            _traceRegistry?.completeCommand(commandId);
          }
          break;
        }
        final retainPeerBinding = accepted;
        _traceRegistry?.completeCommand(
          commandId,
          retainPeerBinding: retainPeerBinding,
        );
        if (accepted) _acceptedOpenCommands[handle] = commandId;
        final stream = _streams[handle];
        if (stream == null) break;
        if (!accepted) {
          _removeStream(handle);
          stream._fail(
            StateError(
              error?.message ?? 'SSH stream open was rejected by native.',
            ),
          );
        }
      default:
        break;
    }
  }

  /// 发送 SSH 流数据；gateway 不可用或 native 拒绝命令时返回 false，避免
  /// 字节被静默丢弃导致 SSH/SFTP 会话挂起。
  bool _sendData(NativeStreamHandle handle, String peerId, Uint8List data) {
    final gateway = _gateway;
    if (gateway == null || _closed) return false;
    final status = gateway.sendCommand(
      NativeNetworkProtocol.sshStreamDataCommand(
        commandId: _nextCommandId('ssh-data'),
        peerId: peerId,
        handle: handle,
        data: data,
      ),
    );
    return status == TransportOperationStatus.success;
  }

  void _closeStream(NativeStreamHandle handle, String peerId) {
    _removeStream(handle);
    final gateway = _gateway;
    if (gateway == null || _closed) return;
    gateway.sendCommand(
      NativeNetworkProtocol.sshStreamCloseCommand(
        commandId: _nextCommandId('ssh-close'),
        peerId: peerId,
        handle: handle,
      ),
    );
  }

  _AppSshNativeStream? _removeStream(NativeStreamHandle handle) {
    final acceptedCommand = _acceptedOpenCommands.remove(handle);
    if (acceptedCommand != null) {
      _traceRegistry?.completeCommand(acceptedCommand);
    }
    final pendingCommands = _pendingOpens.entries
        .where((entry) => entry.value == handle)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final commandId in pendingCommands) {
      _pendingOpens.remove(commandId);
      _traceRegistry?.completeCommand(commandId);
    }
    final stream = _streams.remove(handle);
    if (stream != null) _releasePeerWhenNoStreams(stream.peerId);
    return stream;
  }

  /// A peer connect is shared by all streams opened for that peer, but its
  /// trace belongs to the logical SSH operation that established the route.
  /// Once the final stream closes there is no consumer left that can safely
  /// correlate a late route result, so release that exact context and allow a
  /// subsequent operation to establish a fresh one.
  void _releasePeerWhenNoStreams(String peerId) {
    if (_streams.values.any((stream) => stream.peerId == peerId)) return;
    _connectedPeers.remove(peerId);
    final traceId = _peerTraceIds.remove(peerId);
    if (traceId != null) {
      _traceRegistry?.releasePeerTrace(peerId: peerId, traceId: traceId);
    }
  }

  void _failStream(
    NativeStreamHandle handle,
    Object error, [
    StackTrace? stackTrace,
  ]) {
    final stream = _removeStream(handle);
    stream?._fail(error, stackTrace);
  }

  /// 关闭所有活跃流并释放 gateway 监听；幂等。
  @override
  Future<void> closeAll() async {
    if (_closed) return;
    _closed = true;
    await _nativeSubscription?.cancel();
    _nativeSubscription = null;
    _gatewayFuture = null;
    _openerDeviceIdFuture = null;
    final streams = _streams.values.toList();
    for (final commandId in _pendingOpens.keys.toList(growable: false)) {
      _traceRegistry?.completeCommand(commandId);
    }
    for (final commandId in _acceptedOpenCommands.values) {
      _traceRegistry?.completeCommand(commandId);
    }
    _streams.clear();
    _pendingOpens.clear();
    _acceptedOpenCommands.clear();
    for (final stream in streams) {
      stream._abort();
    }
    _gateway = null;
    _connectedPeers.clear();
    final peerOperations = _peerConnectOperations.values.toList(
      growable: false,
    );
    try {
      await Future.wait<void>(peerOperations, eagerError: false);
    } catch (_) {
      // Every peer operation observes `_closed` and releases its own trace;
      // one failed operation must not prevent the remaining cleanup.
    }
    _peerConnectOperations.clear();
    for (final entry in _peerTraceIds.entries) {
      _traceRegistry?.releasePeerTrace(peerId: entry.key, traceId: entry.value);
    }
    _peerTraceIds.clear();
  }

  String _nextCommandId(String operation) {
    _commandSequence = (_commandSequence + 1) & 0x7fffffff;
    return '$operation-${DateTime.now().microsecondsSinceEpoch}-$_commandSequence';
  }
}
