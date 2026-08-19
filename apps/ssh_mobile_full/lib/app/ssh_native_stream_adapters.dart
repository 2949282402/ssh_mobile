// SSH 到 native ReliableStream 的 App Shell 适配器。
//
// [AppSshNativeStreamConnector] 是 ssh_core `SshNativeStreamConnector` 的 App
// 实现：它借用 AppRuntime-owned 的 native command gateway，先通过
// `NetworkFacade.connectPeer(communicationClass: reliableStream)` 建立对端连接，
// 再发送 `SshStreamOpen` 命令，并把 `SshStreamDataReceived` / `SshStreamClosed`
// 事件按完整 NativeStreamHandle 路由到对应的 [SshNativeStream]（dartssh2 仍负责 SSH/SFTP 协议）。

import 'dart:async';
import 'dart:typed_data';

import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_core/ssh_core.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

/// 打开 AppRuntime-owned native command gateway 的提供者。
typedef SshNativeGatewayProvider = Future<NetworkCommandGateway> Function();

/// 提供当前 runtime 的稳定本地设备身份。
typedef SshNativeOpenerDeviceIdProvider = Future<String> Function();

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
  }) : _gatewayProvider = gatewayProvider,
       _openerDeviceIdProvider = openerDeviceIdProvider,
       _facade = facade;

  final SshNativeGatewayProvider _gatewayProvider;
  final SshNativeOpenerDeviceIdProvider _openerDeviceIdProvider;
  final NetworkFacade? _facade;
  final Map<String, bool> _connectedPeers = <String, bool>{};
  final Map<NativeStreamHandle, _AppSshNativeStream> _streams =
      <NativeStreamHandle, _AppSshNativeStream>{};
  // 等待 native CommandResult 确认的 SshStreamOpen：commandId → StreamHandle。
  final Map<String, NativeStreamHandle> _pendingOpens =
      <String, NativeStreamHandle>{};

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
  }) async {
    final openerDeviceId = await _ensureOpenerDeviceId();
    final gateway = await _ensureGateway();
    if (_facade != null) await _ensurePeerConnected(peerId);

    final handle = _allocateStreamHandle(openerDeviceId);
    final stream = _AppSshNativeStream(
      connector: this,
      peerId: peerId,
      handle: handle,
    );
    _streams[handle] = stream;
    final commandId = _nextCommandId('ssh-open');
    _pendingOpens[commandId] = handle;
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
      throw StateError(
        'Failed to queue native SSH stream open: ' + status.name + '.',
      );
    }
    return stream;
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
    final future = _openerDeviceIdProvider().then((deviceId) {
      if (deviceId.isEmpty) {
        throw StateError('The local opener device ID is unavailable.');
      }
      return deviceId;
    });
    _openerDeviceIdFuture = future;
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

  Future<void> _ensurePeerConnected(String peerId) async {
    if (_connectedPeers.containsKey(peerId)) return;
    final facade = _facade;
    if (facade == null) {
      _connectedPeers[peerId] = true;
      return;
    }
    final result = await facade.connectPeer(
      peerId,
      communicationClass: CommunicationClass.reliableStream,
    );
    if (result is SdkFailure<void>) {
      throw StateError(
        'Failed to connect peer $peerId: ${result.error.message}',
      );
    }
    _connectedPeers[peerId] = true;
  }

  void _onRawEvent(Uint8List bytes) {
    if (_closed) return;
    final event = NativeNetworkProtocol.decodeEvent(bytes);
    switch (event) {
      case NativeSshStreamDataReceivedEvent(:final handle, :final data):
        _streams[handle]?._onData(data);
      case NativeSshStreamClosedEvent(:final handle):
        final stream = _streams.remove(handle);
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
        if (handle == null) break;
        final stream = _streams[handle];
        if (stream == null) break;
        if (!accepted) {
          _streams.remove(handle);
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
    _streams.remove(handle);
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

  /// 关闭所有活跃流并释放 gateway 监听；幂等。
  @override
  Future<void> closeAll() async {
    if (_closed) return;
    _closed = true;
    await _nativeSubscription?.cancel();
    _nativeSubscription = null;
    final streams = _streams.values.toList();
    _streams.clear();
    _pendingOpens.clear();
    for (final stream in streams) {
      stream._abort();
    }
    _gateway = null;
    _connectedPeers.clear();
  }

  String _nextCommandId(String operation) {
    _commandSequence = (_commandSequence + 1) & 0x7fffffff;
    return '$operation-${DateTime.now().microsecondsSinceEpoch}-$_commandSequence';
  }
}

/// App Shell 的 [SshNativeStream] 实现。
final class _AppSshNativeStream implements SshNativeStream {
  _AppSshNativeStream({
    required this.connector,
    required this.peerId,
    required this.handle,
  });

  final AppSshNativeStreamConnector connector;
  final String peerId;
  final NativeStreamHandle handle;
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  final Completer<void> _done = Completer<void>();
  bool _closed = false;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> send(Uint8List data) async {
    if (_closed) throw StateError('SSH native stream is closed.');
    if (!connector._sendData(handle, peerId, data)) {
      // 字节未被真正投递到 native 时，立即以错误终止流并向上抛出，
      // 让 dartssh2 的 socket.done 拿到失败而不是永久挂起。
      final error = StateError(
        'SSH native stream send was dropped: the gateway is closed '
        'or rejected the command.',
      );
      _fail(error);
      throw error;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return _done.future;
    _closed = true;
    connector._closeStream(handle, peerId);
    // 单订阅 StreamController 在无监听者时 await close() 会永久挂起，必须 unawaited。
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_done.isCompleted) _done.complete();
    return _done.future;
  }

  @override
  void destroy() {
    if (_closed) return;
    _closed = true;
    connector._closeStream(handle, peerId);
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_done.isCompleted) _done.complete();
  }

  void _onData(Uint8List data) {
    if (_closed) return;
    _incoming.add(data);
  }

  void _onClosed() {
    if (_closed) return;
    _closed = true;
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_done.isCompleted) _done.complete();
  }

  /// native 拒绝打开（CommandResult accepted=false）时以错误终止流，
  /// 让调用方立即拿到可操作失败而不是永久挂起。
  void _fail(Object error, [StackTrace? stackTrace]) {
    if (_closed) return;
    _closed = true;
    if (!_incoming.isClosed) {
      _incoming.addError(error, stackTrace ?? StackTrace.current);
      unawaited(_incoming.close());
    }
    if (!_done.isCompleted) {
      _done.completeError(error, stackTrace ?? StackTrace.current);
    }
  }

  void _abort() {
    if (_closed) return;
    _closed = true;
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_done.isCompleted) _done.complete();
  }
}
