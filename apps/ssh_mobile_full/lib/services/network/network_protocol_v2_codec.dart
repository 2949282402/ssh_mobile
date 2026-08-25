// Network Protocol V2 手写编解码器，由 Dart FFI 服务与测试共同使用。
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

/// 解码后的 V2 信封，包含内部命令结果或公开事件。
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

/// 当前 network.v2 线协议契约的手写编解码器。
final class NetworkProtocolV2Codec {
  static const int protocolVersion = 2;
  static const _commands = _NetworkCommandEncoder();
  static const _peerEvents = _PeerEventDecoder();
  static const _transferEvents = _TransferEventDecoder();
  static const _streamEvents = _SshStreamEventDecoder();

  /// 创建无状态 V2 编解码器。
  const NetworkProtocolV2Codec();

  /// 编码运行时配置命令。
  Uint8List configureRuntimeCommand({
    required String commandId,
    required NetworkRuntimeConfig config,
  }) => _commands.configureRuntime(commandId: commandId, config: config);

  /// 编码对端新增或替换命令。
  Uint8List upsertPeerCommand({
    required String commandId,
    required PeerConfig peer,
  }) => _commands.upsertPeer(commandId: commandId, peer: peer);

  /// 编码显式删除对端 trust/configuration 命令。
  Uint8List removePeerCommand({
    required String commandId,
    required String peerId,
  }) => _commands.removePeer(commandId: commandId, peerId: peerId);

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
  }) => _commands.connectPeer(
    commandId: commandId,
    peerId: peerId,
    communicationClass: communicationClass,
  );

  /// 编码异步对端断开命令。
  Uint8List disconnectPeerCommand({
    required String commandId,
    required String peerId,
  }) => _commands.disconnectPeer(commandId: commandId, peerId: peerId);

  /// 编码文件传输注册命令。
  Uint8List sendFileCommand({
    required String commandId,
    required String transferId,
    required String peerId,
    required String filePath,
  }) => _commands.sendFile(
    commandId: commandId,
    transferId: transferId,
    peerId: peerId,
    filePath: filePath,
  );

  /// 编码传输取消命令。
  Uint8List cancelTransferCommand({
    required String commandId,
    required String transferId,
  }) => _commands.cancelTransfer(commandId: commandId, transferId: transferId);

  /// 编码传入传输审批或拒绝命令。
  Uint8List respondIncomingTransferCommand({
    required String commandId,
    required String transferId,
    required bool accept,
  }) => _commands.respondIncomingTransfer(
    commandId: commandId,
    transferId: transferId,
    accept: accept,
  );

  /// 为原生数据面编码 Relay 配置凭据。
  Uint8List configureRelayCommand({
    required String commandId,
    required RelayConfig config,
  }) => _commands.configureRelay(commandId: commandId, config: config);

  /// 编码 Relay 断开命令。
  Uint8List disconnectRelayCommand({required String commandId}) =>
      _commands.disconnectRelay(commandId: commandId);

  /// 编码打开一条到对端的 ReliableStream（native tag 25）。
  Uint8List sshStreamOpenCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
    String service = 'ssh',
  }) => _commands.openSshStream(
    commandId: commandId,
    peerId: peerId,
    handle: handle,
    service: service,
  );

  /// 编码向已打开流追加 SSH/SFTP 字节（native tag 26）。
  Uint8List sshStreamDataCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
    required Uint8List data,
  }) => _commands.sendSshStreamData(
    commandId: commandId,
    peerId: peerId,
    handle: handle,
    data: data,
  );

  /// 编码关闭一条 ReliableStream（native tag 27）。
  Uint8List sshStreamCloseCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
  }) => _commands.closeSshStream(
    commandId: commandId,
    peerId: peerId,
    handle: handle,
  );

  /// 从 V2 命令信封读取命令标识。
  String commandId(Uint8List command) {
    return _commands.commandId(command);
  }

  /// 解码 V2 事件信封及可选的内部命令结果。
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
          event = _peerEvents.decodeState(
            eventId,
            timestampMs,
            reader.bytes(field.wireType),
          );
        case 11:
          event = _transferEvents.decodeProgress(
            eventId,
            timestampMs,
            reader.bytes(field.wireType),
          );
        case 13:
          final result = _decodeCommandResult(reader.bytes(field.wireType));
          commandId = result.commandId;
          commandAccepted = result.accepted;
          commandError = result.error;
        case 29:
          final result = _decodeCommandResultV2(reader.bytes(field.wireType));
          commandId = result.commandId;
          commandAccepted = result.accepted;
          commandError = result.error;
        case 14:
          event = _transferEvents.decodeOffer(
            eventId,
            timestampMs,
            reader.bytes(field.wireType),
          );
        case 15:
          event = _transferEvents.decodeCompleted(
            eventId,
            timestampMs,
            reader.bytes(field.wireType),
          );
        case 16:
          event = _transferEvents.decodeFailed(
            eventId,
            timestampMs,
            reader.bytes(field.wireType),
          );
        case 17:
          event = _peerEvents.decodeRouteChanged(
            eventId,
            timestampMs,
            reader.bytes(field.wireType),
          );
        case 18:
          event = _peerEvents.decodeRelayStateChanged(
            eventId,
            timestampMs,
            reader.bytes(field.wireType),
          );
        case 24:
          event = _peerEvents.decodePresence(
            eventId,
            timestampMs,
            reader.bytes(field.wireType),
          );
        case 25:
          event = _peerEvents.decodePresenceSnapshot(
            eventId,
            timestampMs,
            reader.bytes(field.wireType),
          );
        case 26:
          sshStreamData = _streamEvents.decodeData(
            eventId,
            timestampMs,
            reader.bytes(field.wireType),
          );
        case 27:
          sshStreamClosed = _streamEvents.decodeClosed(
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
          error = _decodeNetworkError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    return _CommandResult(commandId, accepted, error);
  }

  /// 解码 Network V2 的类型化命令结果载荷。
  ///
  /// Native Protocol V2 使用 `CommandResult.state` 表达成功、失败或取消；
  /// App 内部仍以 [NetworkProtocolFrame.commandAccepted] 和 [commandError]
  /// 完成待处理命令，因此在此处统一转换两种结果格式。
  _CommandResult _decodeCommandResultV2(Uint8List bytes) {
    final reader = _ProtoReader(bytes);
    var commandId = '';
    var state = 0;
    NetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          commandId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          // peer_id is carried for scoped diagnostics but is not needed by the
          // command completer here.
          reader.bytes(field.wireType);
        case 3:
          state = reader.varint(field.wireType);
        case 4:
          error = _decodeNetworkError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    if (commandId.isEmpty) {
      throw const FormatException('V2 command result has no command ID.');
    }
    return _CommandResult(commandId, state == 0, error);
  }
}

/// 独占 Peer、Route、Relay 与 Presence 事件的类型化映射。
final class _PeerEventDecoder {
  const _PeerEventDecoder();

  PeerStateChanged decodeState(
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
          error = _decodeNetworkError(reader.bytes(field.wireType));
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
      timestamp: _eventTimestamp(timestampMs),
      peerId: peerId,
      state: PeerConnectionState.fromWire(state),
      routeType: NetworkRouteType.fromWire(route),
      routeTopology: NetworkRouteTopology.fromWire(topology),
      routeTransport: NetworkRouteTransport.fromWire(transport),
      error: error,
    );
  }

  RouteChanged decodeRouteChanged(
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
      timestamp: _eventTimestamp(timestampMs),
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

  RelayStateChanged decodeRelayStateChanged(
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
          error = _decodeNetworkError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    return RelayStateChanged(
      eventId: eventId,
      timestamp: _eventTimestamp(timestampMs),
      state: RelayConnectionState.fromWire(state),
      error: error,
    );
  }

  PeerPresenceChanged decodePresence(
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
      timestamp: _eventTimestamp(timestampMs),
      peerId: peerId,
      generation: generation,
      state: PeerPresenceState.fromWire(state),
    );
  }

  PeerPresenceSnapshot decodePresenceSnapshot(
    String eventId,
    int timestampMs,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    final peers = <PeerPresenceChanged>[];
    while (!reader.isDone) {
      final field = reader.field();
      if (field.number != 1) {
        reader.skip(field.wireType);
        continue;
      }
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
          timestamp: _eventTimestamp(timestampMs),
          peerId: peerId,
          generation: generation,
          state: PeerPresenceState.fromWire(state),
        ),
      );
    }
    return PeerPresenceSnapshot(
      eventId: eventId,
      timestamp: _eventTimestamp(timestampMs),
      peers: peers,
    );
  }
}

/// 独占文件传输事件的类型化映射。
final class _TransferEventDecoder {
  const _TransferEventDecoder();

  TransferProgress decodeProgress(
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
      timestamp: _eventTimestamp(timestampMs),
      transferId: transferId,
      bytesTransferred: transferred,
      totalBytes: total,
    );
  }

  IncomingTransferOffer decodeOffer(
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
      timestamp: _eventTimestamp(timestampMs),
      transferId: transferId,
      peerId: peerId,
      fileName: fileName,
      fileSize: fileSize,
      routeType: NetworkRouteType.fromWire(route),
    );
  }

  TransferCompleted decodeCompleted(
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
      timestamp: _eventTimestamp(timestampMs),
      transferId: transferId,
      localPath: localPath,
    );
  }

  TransferFailed decodeFailed(
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
          error = _decodeNetworkError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    return TransferFailed(
      eventId: eventId,
      timestamp: _eventTimestamp(timestampMs),
      transferId: transferId,
      error:
          error ??
          const NetworkError(
            code: NetworkErrorCode.unspecified,
            message: 'transfer failed',
          ),
    );
  }
}

/// 独占 SSH ReliableStream handle 与事件载荷解码。
final class _SshStreamEventDecoder {
  const _SshStreamEventDecoder();

  SshStreamDataReceivedEvent decodeData(
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
          handle = _decodeHandle(reader.bytes(field.wireType));
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
      timestamp: _eventTimestamp(timestampMs),
      peerId: peerId,
      handle: streamHandle,
      data: data,
    );
  }

  SshStreamClosedEvent decodeClosed(
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
          handle = _decodeHandle(reader.bytes(field.wireType));
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
      timestamp: _eventTimestamp(timestampMs),
      peerId: peerId,
      handle: streamHandle,
    );
  }

  NativeStreamHandle _decodeHandle(Uint8List bytes) {
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
}

DateTime _eventTimestamp(int timestampMs) =>
    DateTime.fromMillisecondsSinceEpoch(timestampMs);

NetworkError _decodeNetworkError(Uint8List bytes) {
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

/// 独占 Network V2 命令载荷与信封编码，不参与事件解释。
final class _NetworkCommandEncoder {
  const _NetworkCommandEncoder();

  Uint8List configureRuntime({
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

  Uint8List upsertPeer({required String commandId, required PeerConfig peer}) {
    final config = _ProtoWriter()
      ..string(1, peer.peerId)
      ..string(2, peer.endpointAddress)
      ..bytesField(3, peer.identityPublicKey)
      ..bytesField(4, peer.e2ePublicKey)
      // SdkPeerConfig exposes only the required application E2EE contract;
      // E2EE_POLICY_REQUIRED is the zero-valued wire enum.
      ..varint(5, 0)
      ..varint(6, peer.allowDirect ? 1 : 0)
      ..varint(7, peer.allowRelay ? 1 : 0);
    final payload = _ProtoWriter()..message(1, config.takeBytes());
    return _command(commandId, 28, payload.takeBytes());
  }

  Uint8List removePeer({required String commandId, required String peerId}) =>
      _command(commandId, 29, (_ProtoWriter()..string(1, peerId)).takeBytes());

  Uint8List connectPeer({
    required String commandId,
    required String peerId,
    required CommunicationClass communicationClass,
  }) {
    final payload = _ProtoWriter()
      ..string(1, peerId)
      ..varint(2, 0)
      ..varint(3, communicationClass.wireValue);
    return _command(commandId, 10, payload.takeBytes());
  }

  Uint8List disconnectPeer({
    required String commandId,
    required String peerId,
  }) =>
      _command(commandId, 17, (_ProtoWriter()..string(1, peerId)).takeBytes());

  Uint8List sendFile({
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

  Uint8List cancelTransfer({
    required String commandId,
    required String transferId,
  }) => _command(
    commandId,
    12,
    (_ProtoWriter()..string(1, transferId)).takeBytes(),
  );

  Uint8List respondIncomingTransfer({
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

  Uint8List configureRelay({
    required String commandId,
    required RelayConfig config,
  }) {
    final payload = _ProtoWriter()
      ..string(1, config.relayUrl)
      ..string(2, config.relayCredential)
      ..bytesField(3, config.relaySigningSeed);
    return _command(commandId, 16, payload.takeBytes());
  }

  Uint8List disconnectRelay({required String commandId}) =>
      _command(commandId, 18, Uint8List(0));

  Uint8List openSshStream({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
    required String service,
  }) {
    final payload = _ProtoWriter()
      ..string(1, peerId)
      ..message(2, _encodeSshStreamHandle(handle))
      ..string(3, service);
    return _command(commandId, 25, payload.takeBytes());
  }

  Uint8List sendSshStreamData({
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

  Uint8List closeSshStream({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
  }) {
    final payload = _ProtoWriter()
      ..string(1, peerId)
      ..message(2, _encodeSshStreamHandle(handle));
    return _command(commandId, 27, payload.takeBytes());
  }

  String commandId(Uint8List command) {
    final reader = _ProtoReader(command);
    while (!reader.isDone) {
      final field = reader.field();
      if (field.number == 1) return utf8.decode(reader.bytes(field.wireType));
      reader.skip(field.wireType);
    }
    throw const FormatException('Network command has no command ID.');
  }

  Uint8List _encodeSshStreamHandle(NativeStreamHandle handle) =>
      (_ProtoWriter()
            ..string(1, handle.openerDeviceId)
            ..varint(2, handle.streamId))
          .takeBytes();

  Uint8List _command(String commandId, int field, Uint8List payload) =>
      (_ProtoWriter()
            ..string(1, commandId)
            ..varint(2, NetworkProtocolV2Codec.protocolVersion)
            ..message(field, payload))
          .takeBytes();
}

/// 用于完成 Dart 命令 Future 的内部命令结果值。
final class _CommandResult {
  /// 创建命令结果值。
  const _CommandResult(this.commandId, this.accepted, this.error);

  final String commandId;
  final bool accepted;
  final NetworkError? error;
}

/// 用于 Network Protocol V2 命令字段的最小 Protobuf 写入器。
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

/// 用于 Network Protocol V2 事件字段的最小 Protobuf 读取器。
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
