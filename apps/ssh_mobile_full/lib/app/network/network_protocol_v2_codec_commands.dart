part of '../../services/network/network_protocol_v2_codec.dart';

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
