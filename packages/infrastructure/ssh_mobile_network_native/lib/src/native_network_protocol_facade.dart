part of 'native_realtime_protocol.dart';

/// Bounded Protobuf command/event codec for the native Realtime API.
/// Bounded Protobuf command/event facade for the native SDK API.
final class NativeNetworkProtocol {
  /// Current native protocol version.
  static const int protocolVersion = _protocolVersion;

  const NativeNetworkProtocol._();

  static Uint8List connectPeerCommand({
    required String commandId,
    required String peerId,
    int intent = 0,
    int communicationClass = 2,
  }) => _NativeProtocolCommandEncoder.connectPeerCommand(
    commandId: commandId,
    peerId: peerId,
    intent: intent,
    communicationClass: communicationClass,
  );

  static Uint8List disconnectPeerCommand({
    required String commandId,
    required String peerId,
  }) => _NativeProtocolCommandEncoder.disconnectPeerCommand(
    commandId: commandId,
    peerId: peerId,
  );

  static Uint8List sendMessageCommand({
    required String commandId,
    required String peerId,
    required String channelId,
    required Uint8List payload,
    int deliveryPolicy = 2,
  }) => _NativeProtocolCommandEncoder.sendMessageCommand(
    commandId: commandId,
    peerId: peerId,
    channelId: channelId,
    payload: payload,
    deliveryPolicy: deliveryPolicy,
  );

  static Uint8List sendMessageV2Command({
    required String commandId,
    required String peerId,
    required String messageId,
    required String channelId,
    required Uint8List payload,
    int deliveryPolicy = 2,
    NativeE2eePolicy e2eePolicy = NativeE2eePolicy.required,
  }) => _NativeProtocolCommandEncoder.sendMessageV2Command(
    commandId: commandId,
    peerId: peerId,
    messageId: messageId,
    channelId: channelId,
    payload: payload,
    deliveryPolicy: deliveryPolicy,
    e2eePolicy: e2eePolicy,
  );

  static Uint8List upsertPeerV2Command({
    required String commandId,
    required NativePeerConfig config,
  }) => _NativeProtocolCommandEncoder.upsertPeerV2Command(
    commandId: commandId,
    config: config,
  );

  static Uint8List removePeerCommand({
    required String commandId,
    required String peerId,
  }) => _NativeProtocolCommandEncoder.removePeerCommand(
    commandId: commandId,
    peerId: peerId,
  );

  static Uint8List transferCommand({
    required String commandId,
    required String peerId,
    required String transferId,
    required String filePath,
    int confirmedOffset = 0,
    bool resume = false,
  }) => _NativeProtocolCommandEncoder.transferCommand(
    commandId: commandId,
    peerId: peerId,
    transferId: transferId,
    filePath: filePath,
    confirmedOffset: confirmedOffset,
    resume: resume,
  );

  static Uint8List peerDiagnosticsCommand({
    required String commandId,
    required String peerId,
  }) => _NativeProtocolCommandEncoder.peerDiagnosticsCommand(
    commandId: commandId,
    peerId: peerId,
  );

  static Uint8List networkEnvironmentChangedCommand({
    required String commandId,
    required int generation,
    required bool hasConnectivity,
    required bool isForeground,
    required bool isMetered,
  }) => _NativeProtocolCommandEncoder.networkEnvironmentChangedCommand(
    commandId: commandId,
    generation: generation,
    hasConnectivity: hasConnectivity,
    isForeground: isForeground,
    isMetered: isMetered,
  );

  static Uint8List sendFileCommand({
    required String commandId,
    required String peerId,
    required String transferId,
    required String filePath,
  }) => _NativeProtocolCommandEncoder.sendFileCommand(
    commandId: commandId,
    peerId: peerId,
    transferId: transferId,
    filePath: filePath,
  );

  static Uint8List cancelTransferCommand({
    required String commandId,
    required String transferId,
  }) => _NativeProtocolCommandEncoder.cancelTransferCommand(
    commandId: commandId,
    transferId: transferId,
  );

  static Uint8List startRealtimeSessionCommand({
    required String commandId,
    required String realtimeId,
    required String peerId,
  }) => _NativeProtocolCommandEncoder.startRealtimeSessionCommand(
    commandId: commandId,
    realtimeId: realtimeId,
    peerId: peerId,
  );

  static Uint8List stopRealtimeSessionCommand({
    required String commandId,
    required String realtimeId,
  }) => _NativeProtocolCommandEncoder.stopRealtimeSessionCommand(
    commandId: commandId,
    realtimeId: realtimeId,
  );

  static Uint8List sendRealtimeSignalCommand({
    required String commandId,
    required String realtimeId,
    required String peerId,
    required NativeRealtimeSignalKind kind,
    required int revision,
    required Uint8List payload,
  }) => _NativeProtocolCommandEncoder.sendRealtimeSignalCommand(
    commandId: commandId,
    realtimeId: realtimeId,
    peerId: peerId,
    kind: kind,
    revision: revision,
    payload: payload,
  );

  static Uint8List sshStreamOpenCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
    String service = 'ssh',
  }) => _NativeProtocolCommandEncoder.sshStreamOpenCommand(
    commandId: commandId,
    peerId: peerId,
    handle: handle,
    service: service,
  );

  static Uint8List sshStreamDataCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
    required Uint8List data,
  }) => _NativeProtocolCommandEncoder.sshStreamDataCommand(
    commandId: commandId,
    peerId: peerId,
    handle: handle,
    data: data,
  );

  static Uint8List sshStreamCloseCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
  }) => _NativeProtocolCommandEncoder.sshStreamCloseCommand(
    commandId: commandId,
    peerId: peerId,
    handle: handle,
  );

  static NativeNetworkEvent? decodeEvent(Uint8List bytes) =>
      _NativeProtocolEventDecoder.decodeEvent(bytes);
}
