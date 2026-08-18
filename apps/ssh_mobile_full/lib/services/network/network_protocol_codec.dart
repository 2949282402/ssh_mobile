// v1 手写网络线协议编解码器，由 Dart FFI 服务与测试共同使用。
//
// Protobuf schema 仍是唯一线协议来源；本编解码器只镜像仓库中的字段 tag，
// 不引入生成绑定。

import 'dart:convert';
import 'dart:typed_data';

import 'package:network_sdk/network_sdk.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

/// Stable identity for a logical ReliableStream.
typedef SshStreamHandle = NativeStreamHandle;

/// ReliableStream 收到对端 SSH/SFTP 字节的事件（network-protocol tag 26）。
final class SshStreamDataReceivedEvent {
  /// 创建 SSH 流数据事件。
  const SshStreamDataReceivedEvent({
    required this.eventId,
    required this.timestamp,
    required this.peerId,
    required this.handle,
    required this.data,
  });

  final String eventId;
  final DateTime timestamp;
  final String peerId;
  final NativeStreamHandle handle;
  int get streamId => handle.streamId;
  final Uint8List data;
}

/// ReliableStream 关闭事件（network-protocol tag 27）。
final class SshStreamClosedEvent {
  /// 创建 SSH 流关闭事件。
  const SshStreamClosedEvent({
    required this.eventId,
    required this.timestamp,
    required this.peerId,
    required this.handle,
  });

  final String eventId;
  final DateTime timestamp;
  final String peerId;
  final NativeStreamHandle handle;
  int get streamId => handle.streamId;
}

/// 解码后的 v1 信封，包含内部命令结果或公开事件。
final class NetworkProtocolFrame {
  /// 创建解码后的协议帧。
  const NetworkProtocolFrame({
    required this.eventId,
    required this.protocolVersion,
    this.commandId,
    this.commandAccepted = false,
    this.commandError,
    this.event,
    this.sshStreamData,
    this.sshStreamClosed,
  });

  final String eventId;
  final int protocolVersion;
  final String? commandId;
  final bool commandAccepted;
  final NetworkError? commandError;
  final NetworkEvent? event;

  /// native SSH 流数据事件（tag 26），不进入业务 [event] 流。
  final SshStreamDataReceivedEvent? sshStreamData;

  /// native SSH 流关闭事件（tag 27），不进入业务 [event] 流。
  final SshStreamClosedEvent? sshStreamClosed;
}

/// 当前 network.v1 线协议契约的手写编解码器。
final class NetworkProtocolCodec {
  static const int protocolVersion = 1;

  /// 创建无状态 v1 编解码器。
  const NetworkProtocolCodec();

  Uint8List _encodeSshStreamHandle(NativeStreamHandle handle) =>
      (_ProtoWriter()
            ..string(1, handle.openerDeviceId)
            ..varint(2, handle.streamId))
          .takeBytes();

  NativeStreamHandle _decodeSshStreamHandle(Uint8List bytes) {
    final reader = _ProtoReader(bytes);
    var openerDeviceId = '';
    var streamId = 0;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          openerDeviceId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          streamId = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    if (openerDeviceId.isEmpty || streamId < 1 || streamId > 0xffff) {
      throw const FormatException('SSH stream handle is invalid.');
    }
    return NativeStreamHandle(
      openerDeviceId: openerDeviceId,
      streamId: streamId,
    );
  }

  /// 编码运行时配置命令。
  Uint8List configureRuntimeCommand({
    required String commandId,
    required NetworkRuntimeConfig config,
  }) {
    final payload = _ProtoWriter()
      ..string(1, config.deviceId)
      ..bytesField(2, config.identityPrivateKey)
      ..bytesField(3, config.e2ePrivateKey)
      ..string(4, config.listenAddress)
      ..string(5, config.receiveDirectory);
    return _command(commandId, 13, payload.takeBytes());
  }

  /// 编码对端新增或替换命令。
  Uint8List upsertPeerCommand({
    required String commandId,
    required PeerConfig peer,
  }) {
    final payload = _ProtoWriter()
      ..string(1, peer.peerId)
      ..string(2, peer.endpointAddress)
      ..bytesField(3, peer.identityPublicKey)
      ..bytesField(4, peer.e2ePublicKey);
    return _command(commandId, 14, payload.takeBytes());
  }

  /// 编码异步对端连接命令。
  ///
  /// 载荷镜像 network_protocol ConnectPeerCommand：peer_id(1)、intent(2)、
  /// communication_class(3)。communication_class 的取值与 Rust 侧
  /// `CommunicationClass` 枚举一致（reliableStream=1 … realtimeMedia=5），
  /// 由 [CommunicationClass.wireValue] 提供。
  Uint8List connectPeerCommand({
    required String commandId,
    required String peerId,
    CommunicationClass communicationClass = CommunicationClass.reliableStream,
  }) {
    final payload = _ProtoWriter()
      ..string(1, peerId)
      ..varint(2, 0)
      ..varint(3, communicationClass.wireValue);
    return _command(commandId, 10, payload.takeBytes());
  }

  /// 编码异步对端断开命令。
  Uint8List disconnectPeerCommand({
    required String commandId,
    required String peerId,
  }) =>
      _command(commandId, 17, (_ProtoWriter()..string(1, peerId)).takeBytes());

  /// 编码文件传输注册命令。
  Uint8List sendFileCommand({
    required String commandId,
    required String transferId,
    required String peerId,
    required String filePath,
  }) {
    final payload = _ProtoWriter()
      ..string(1, transferId)
      ..string(2, peerId)
      ..string(3, filePath);
    return _command(commandId, 11, payload.takeBytes());
  }

  /// 编码传输取消命令。
  Uint8List cancelTransferCommand({
    required String commandId,
    required String transferId,
  }) => _command(
    commandId,
    12,
    (_ProtoWriter()..string(1, transferId)).takeBytes(),
  );

  /// 编码传入传输审批或拒绝命令。
  Uint8List respondIncomingTransferCommand({
    required String commandId,
    required String transferId,
    required bool accept,
  }) => _command(
    commandId,
    15,
    ((_ProtoWriter()
          ..string(1, transferId)
          ..varint(2, accept ? 1 : 0))
        .takeBytes()),
  );

  /// 为原生数据面编码 Relay 配置凭据。
  Uint8List configureRelayCommand({
    required String commandId,
    required RelayConfig config,
  }) {
    final payload = _ProtoWriter()
      ..string(1, config.relayUrl)
      ..string(2, config.relayCredential)
      ..bytesField(3, config.relaySigningSeed);
    return _command(commandId, 16, payload.takeBytes());
  }

  /// 编码 Relay 断开命令。
  Uint8List disconnectRelayCommand({required String commandId}) =>
      _command(commandId, 18, Uint8List(0));

  /// 编码打开一条到对端的 ReliableStream（native tag 25）。
  Uint8List sshStreamOpenCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
    String service = 'ssh',
  }) {
    final payload = _ProtoWriter()
      ..string(1, peerId)
      ..message(2, _encodeSshStreamHandle(handle))
      ..string(3, service);
    return _command(commandId, 25, payload.takeBytes());
  }

  /// 编码向已打开流追加 SSH/SFTP 字节（native tag 26）。
  Uint8List sshStreamDataCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
    required Uint8List data,
  }) {
    final payload = _ProtoWriter()
      ..string(1, peerId)
      ..message(2, _encodeSshStreamHandle(handle))
      ..bytesField(3, data);
    return _command(commandId, 26, payload.takeBytes());
  }

  /// 编码关闭一条 ReliableStream（native tag 27）。
  Uint8List sshStreamCloseCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
  }) {
    final payload = _ProtoWriter()
      ..string(1, peerId)
      ..message(2, _encodeSshStreamHandle(handle));
    return _command(commandId, 27, payload.takeBytes());
  }

  /// 从 v1 命令信封读取命令标识。
  String commandId(Uint8List command) {
    final reader = _ProtoReader(command);
    while (!reader.isDone) {
      final field = reader.field();
      if (field.number == 1) return utf8.decode(reader.bytes(field.wireType));
      reader.skip(field.wireType);
    }
    throw const FormatException('Network command has no command ID.');
  }

  /// 解码 v1 事件信封及可选的内部命令结果。
  NetworkProtocolFrame decodeEvent(Uint8List bytes) {
    final reader = _ProtoReader(bytes);
    var eventId = '';
    var timestampMs = 0;
    var protocolVersion = 0;
    String? commandId;
    var commandAccepted = false;
    NetworkError? commandError;
    NetworkEvent? event;
    SshStreamDataReceivedEvent? sshStreamData;
    SshStreamClosedEvent? sshStreamClosed;

    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          eventId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          timestampMs = reader.varint(field.wireType);
        case 3:
          protocolVersion = reader.varint(field.wireType);
        case 10:
          event = _decodePeerState(
            eventId,
            timestampMs,
            reader.bytes(field.wireType),
          );
        case 11:
          event = _decodeProgress(
            eventId,
            timestampMs,
            reader.bytes(field.wireType),
          );
        case 13:
          final result = _decodeCommandResult(reader.bytes(field.wireType));
          commandId = result.commandId;
          commandAccepted = result.accepted;
          commandError = result.error;
        case 14:
          event = _decodeOffer(
            eventId,
            timestampMs,
            reader.bytes(field.wireType),
          );
        case 15:
          event = _decodeCompleted(
            eventId,
            timestampMs,
            reader.bytes(field.wireType),
          );
        case 16:
          event = _decodeFailed(
            eventId,
            timestampMs,
            reader.bytes(field.wireType),
          );
        case 17:
          event = _decodeRouteChanged(
            eventId,
            timestampMs,
            reader.bytes(field.wireType),
          );
        case 18:
          event = _decodeRelayStateChanged(
            eventId,
            timestampMs,
            reader.bytes(field.wireType),
          );
        case 24:
          event = _decodePeerPresence(
            eventId,
            timestampMs,
            reader.bytes(field.wireType),
          );
        case 25:
          event = _decodePeerPresenceSnapshot(
            eventId,
            timestampMs,
            reader.bytes(field.wireType),
          );
        case 26:
          sshStreamData = _decodeSshStreamData(
            eventId,
            timestampMs,
            reader.bytes(field.wireType),
          );
        case 27:
          sshStreamClosed = _decodeSshStreamClosed(
            eventId,
            timestampMs,
            reader.bytes(field.wireType),
          );
        default:
          reader.skip(field.wireType);
      }
    }
    return NetworkProtocolFrame(
      eventId: eventId,
      protocolVersion: protocolVersion,
      commandId: commandId,
      commandAccepted: commandAccepted,
      commandError: commandError,
      event: event,
      sshStreamData: sshStreamData,
      sshStreamClosed: sshStreamClosed,
    );
  }

  /// 将命令载荷包装到通用 v1 命令信封中。
  Uint8List _command(String commandId, int field, Uint8List payload) =>
      (_ProtoWriter()
            ..string(1, commandId)
            ..varint(2, protocolVersion)
            ..message(field, payload))
          .takeBytes();

  /// 将线协议时间戳转换为 Dart [DateTime]。
  DateTime _timestamp(int timestampMs) =>
      DateTime.fromMillisecondsSinceEpoch(timestampMs);

  /// 解码类型化对端状态事件载荷。
  PeerStateChanged _decodePeerState(
    String eventId,
    int timestampMs,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    var state = 0;
    var route = 0;
    var topology = 0;
    var transport = 0;
    NetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          state = reader.varint(field.wireType);
        case 3:
          route = reader.varint(field.wireType);
        case 4:
          error = _decodeError(reader.bytes(field.wireType));
        case 5:
          topology = reader.varint(field.wireType);
        case 6:
          transport = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    return PeerStateChanged(
      eventId: eventId,
      timestamp: _timestamp(timestampMs),
      peerId: peerId,
      state: PeerConnectionState.fromWire(state),
      routeType: NetworkRouteType.fromWire(route),
      routeTopology: NetworkRouteTopology.fromWire(topology),
      routeTransport: NetworkRouteTransport.fromWire(transport),
      error: error,
    );
  }

  /// 解码传输进度事件载荷。
  TransferProgress _decodeProgress(
    String eventId,
    int timestampMs,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var transferId = '';
    var transferred = 0;
    var total = 0;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          transferId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          transferred = reader.varint(field.wireType);
        case 3:
          total = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    return TransferProgress(
      eventId: eventId,
      timestamp: _timestamp(timestampMs),
      transferId: transferId,
      bytesTransferred: transferred,
      totalBytes: total,
    );
  }

  /// 解码内部命令结果载荷。
  _CommandResult _decodeCommandResult(Uint8List bytes) {
    final reader = _ProtoReader(bytes);
    var commandId = '';
    var accepted = false;
    NetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          commandId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          accepted = reader.varint(field.wireType) != 0;
        case 3:
          error = _decodeError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    return _CommandResult(commandId, accepted, error);
  }

  /// 解码传入传输申请载荷。
  IncomingTransferOffer _decodeOffer(
    String eventId,
    int timestampMs,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var transferId = '';
    var peerId = '';
    var fileName = '';
    var fileSize = 0;
    var route = 0;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          transferId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          peerId = utf8.decode(reader.bytes(field.wireType));
        case 3:
          fileName = utf8.decode(reader.bytes(field.wireType));
        case 4:
          fileSize = reader.varint(field.wireType);
        case 5:
          route = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    return IncomingTransferOffer(
      eventId: eventId,
      timestamp: _timestamp(timestampMs),
      transferId: transferId,
      peerId: peerId,
      fileName: fileName,
      fileSize: fileSize,
      routeType: NetworkRouteType.fromWire(route),
    );
  }

  /// 解码传输完成载荷。
  TransferCompleted _decodeCompleted(
    String eventId,
    int timestampMs,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var transferId = '';
    var localPath = '';
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          transferId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          localPath = utf8.decode(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    return TransferCompleted(
      eventId: eventId,
      timestamp: _timestamp(timestampMs),
      transferId: transferId,
      localPath: localPath,
    );
  }

  /// 解码传输失败载荷。
  TransferFailed _decodeFailed(
    String eventId,
    int timestampMs,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var transferId = '';
    NetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          transferId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          error = _decodeError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    return TransferFailed(
      eventId: eventId,
      timestamp: _timestamp(timestampMs),
      transferId: transferId,
      error:
          error ??
          const NetworkError(
            code: NetworkErrorCode.unspecified,
            message: 'transfer failed',
          ),
    );
  }

  /// 解码路由变化载荷。
  RouteChanged _decodeRouteChanged(
    String eventId,
    int timestampMs,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    var route = 0;
    String? endpoint;
    int? rtt;
    int? loss;
    var topology = 0;
    var transport = 0;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          route = reader.varint(field.wireType);
        case 3:
          endpoint = utf8.decode(reader.bytes(field.wireType));
        case 4:
          rtt = reader.varint(field.wireType);
        case 5:
          loss = reader.varint(field.wireType);
        case 6:
          topology = reader.varint(field.wireType);
        case 7:
          transport = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    return RouteChanged(
      eventId: eventId,
      timestamp: _timestamp(timestampMs),
      snapshot: RouteSnapshot(
        peerId: peerId,
        routeType: NetworkRouteType.fromWire(route),
        topology: NetworkRouteTopology.fromWire(topology),
        transport: NetworkRouteTransport.fromWire(transport),
        endpoint: endpoint,
        rtt: rtt == null ? null : Duration(milliseconds: rtt),
        loss: loss == null ? null : loss / 1000,
      ),
    );
  }

  /// 解码 Relay Presence 推送的对端状态载荷（tag 24）。
  ///
  /// 字段镜像 network_protocol PeerPresenceChangedEvent：peer_id(1)、
  /// generation(2)、state(3)。单个事件表示一台设备的 online/updated/offline 变化。
  PeerPresenceChanged _decodePeerPresence(
    String eventId,
    int timestampMs,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    var generation = 0;
    var state = 0;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          generation = reader.varint(field.wireType);
        case 3:
          state = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    return PeerPresenceChanged(
      eventId: eventId,
      timestamp: _timestamp(timestampMs),
      peerId: peerId,
      generation: generation,
      state: PeerPresenceState.fromWire(state),
    );
  }

  /// 解码 Relay Presence 完整在线设备快照（tag 25）。
  ///
  /// 字段镜像 network_protocol PeerPresenceSnapshotEvent：peers(1) 是重复的
  /// PeerPresenceChangedEvent 消息。快照在设备认证连接后推送一次，作为其本地
  /// 设备列表基线。
  PeerPresenceSnapshot _decodePeerPresenceSnapshot(
    String eventId,
    int timestampMs,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    final peers = <PeerPresenceChanged>[];
    while (!reader.isDone) {
      final field = reader.field();
      if (field.number == 1) {
        final peerReader = _ProtoReader(reader.bytes(field.wireType));
        var peerId = '';
        var generation = 0;
        var state = 0;
        while (!peerReader.isDone) {
          final peerField = peerReader.field();
          switch (peerField.number) {
            case 1:
              peerId = utf8.decode(peerReader.bytes(peerField.wireType));
            case 2:
              generation = peerReader.varint(peerField.wireType);
            case 3:
              state = peerReader.varint(peerField.wireType);
            default:
              peerReader.skip(peerField.wireType);
          }
        }
        peers.add(
          PeerPresenceChanged(
            eventId: eventId,
            timestamp: _timestamp(timestampMs),
            peerId: peerId,
            generation: generation,
            state: PeerPresenceState.fromWire(state),
          ),
        );
      } else {
        reader.skip(field.wireType);
      }
    }
    return PeerPresenceSnapshot(
      eventId: eventId,
      timestamp: _timestamp(timestampMs),
      peers: peers,
    );
  }

  /// 解码 SSH 流数据载荷（tag 26）。
  SshStreamDataReceivedEvent _decodeSshStreamData(
    String eventId,
    int timestampMs,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    NativeStreamHandle? handle;
    var data = Uint8List(0);
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          handle = _decodeSshStreamHandle(reader.bytes(field.wireType));
        case 3:
          data = Uint8List.fromList(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    final streamHandle = handle;
    if (streamHandle == null) {
      throw const FormatException('SSH stream event has no stream handle.');
    }
    return SshStreamDataReceivedEvent(
      eventId: eventId,
      timestamp: _timestamp(timestampMs),
      peerId: peerId,
      handle: streamHandle,
      data: data,
    );
  }

  /// 解码 SSH 流关闭载荷（tag 27）。
  SshStreamClosedEvent _decodeSshStreamClosed(
    String eventId,
    int timestampMs,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    NativeStreamHandle? handle;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          handle = _decodeSshStreamHandle(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    final streamHandle = handle;
    if (streamHandle == null) {
      throw const FormatException('SSH stream event has no stream handle.');
    }
    return SshStreamClosedEvent(
      eventId: eventId,
      timestamp: _timestamp(timestampMs),
      peerId: peerId,
      handle: streamHandle,
    );
  }

  /// 解码 Relay 状态载荷。
  RelayStateChanged _decodeRelayStateChanged(
    String eventId,
    int timestampMs,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var state = 0;
    NetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          state = reader.varint(field.wireType);
        case 2:
          error = _decodeError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    return RelayStateChanged(
      eventId: eventId,
      timestamp: _timestamp(timestampMs),
      state: RelayConnectionState.fromWire(state),
      error: error,
    );
  }

  /// 解码结构化 v1 网络错误载荷。
  NetworkError _decodeError(Uint8List bytes) {
    final reader = _ProtoReader(bytes);
    var code = 0;
    var message = '';
    NetworkOperation? operation;
    String? peerId;
    var retryDisposition = RetryDisposition.unspecified;
    var retryAfterSeconds = 0;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          code = reader.varint(field.wireType);
        case 2:
          message = utf8.decode(reader.bytes(field.wireType));
        case 3:
          operation = NetworkOperation.fromWire(
            utf8.decode(reader.bytes(field.wireType)),
          );
        case 4:
          peerId = utf8.decode(reader.bytes(field.wireType));
        case 5:
          retryDisposition = RetryDisposition.fromWire(
            reader.varint(field.wireType),
          );
        case 6:
          retryAfterSeconds = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    return NetworkError(
      code: NetworkErrorCode.fromWire(code),
      message: message,
      operation: operation,
      peerId: peerId?.isEmpty == true ? null : peerId,
      retryDisposition: retryDisposition,
      retryAfterSeconds: retryAfterSeconds,
    );
  }
}

/// 用于完成 Dart 命令 Future 的内部命令结果值。
final class _CommandResult {
  /// 创建命令结果值。
  const _CommandResult(this.commandId, this.accepted, this.error);

  final String commandId;
  final bool accepted;
  final NetworkError? error;
}

/// 用于网络命令 v1 字段的最小 Protobuf 写入器。
final class _ProtoWriter {
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  /// 写入 varint 字段。
  void varint(int fieldNumber, int value) {
    _writeVarint((fieldNumber << 3));
    _writeVarint(value);
  }

  /// 写入 UTF-8 字符串字段。
  void string(int fieldNumber, String value) =>
      message(fieldNumber, Uint8List.fromList(utf8.encode(value)));

  /// 写入长度分隔的字节字段。
  void bytesField(int fieldNumber, Uint8List value) =>
      message(fieldNumber, value);

  /// 写入长度分隔的嵌套消息。
  void message(int fieldNumber, Uint8List value) {
    _writeVarint((fieldNumber << 3) | 2);
    _writeVarint(value.length);
    _bytes.add(value);
  }

  /// 写入原始 Protobuf varint。
  void _writeVarint(int value) {
    var remaining = value;
    while (remaining >= 0x80) {
      _bytes.addByte((remaining & 0x7f) | 0x80);
      remaining >>= 7;
    }
    _bytes.addByte(remaining);
  }

  /// 返回已写入的全部字节，并重置构建器。
  Uint8List takeBytes() => _bytes.takeBytes();
}

/// 已解析的 Protobuf 字段 key 与 wire type。
final class _ProtoField {
  /// 创建已解析的字段描述。
  const _ProtoField(this.number, this.wireType);

  final int number;
  final int wireType;
}

/// 用于网络事件 v1 字段的最小 Protobuf 读取器。
final class _ProtoReader {
  /// 创建读取 [bytes] 的读取器。
  _ProtoReader(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  /// 输入字节是否已经全部读取。
  bool get isDone => _offset >= _bytes.length;

  /// 读取下一个 Protobuf 字段 key。
  _ProtoField field() {
    final key = _readVarint();
    return _ProtoField(key >> 3, key & 7);
  }

  /// 校验 wire type 后读取 varint 字段。
  int varint(int wireType) {
    if (wireType != 0) throw const FormatException('Invalid varint wire type.');
    return _readVarint();
  }

  /// 校验 wire type 后读取长度分隔字段。
  Uint8List bytes(int wireType) {
    if (wireType != 2) throw const FormatException('Invalid bytes wire type.');
    final length = _readVarint();
    final end = _offset + length;
    if (end > _bytes.length) {
      throw const FormatException('Truncated protobuf field.');
    }
    final value = Uint8List.sublistView(_bytes, _offset, end);
    _offset = end;
    return value;
  }

  /// 跳过未知 Protobuf 字段，同时保持流对齐。
  void skip(int wireType) {
    switch (wireType) {
      case 0:
        _readVarint();
      case 1:
        _advance(8);
      case 2:
        _advance(_readVarint());
      case 5:
        _advance(4);
      default:
        throw const FormatException('Unsupported protobuf wire type.');
    }
  }

  /// 读取一个原始 Protobuf varint。
  int _readVarint() {
    var value = 0;
    for (var shift = 0; shift < 64; shift += 7) {
      if (_offset >= _bytes.length) {
        throw const FormatException('Truncated protobuf varint.');
      }
      final byte = _bytes[_offset++];
      value |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) return value;
    }
    throw const FormatException('Protobuf varint is too long.');
  }

  /// 前进 [count] 个字节，并拒绝被截断的输入。
  void _advance(int count) {
    final end = _offset + count;
    if (end > _bytes.length) {
      throw const FormatException('Truncated protobuf field.');
    }
    _offset = end;
  }
}
