import 'dart:typed_data';

import 'network_route_models.dart';

final class SdkRuntimeConfig {
  const SdkRuntimeConfig({
    required this.deviceId,
    required this.identityPrivateKey,
    required this.e2ePrivateKey,
    required this.listenAddress,
    required this.receiveDirectory,
  });

  final String deviceId;
  final Uint8List identityPrivateKey;
  final Uint8List e2ePrivateKey;
  final String listenAddress;
  final String receiveDirectory;
}

final class SdkPeerConfig {
  const SdkPeerConfig({
    required this.peerId,
    required this.endpointAddress,
    required this.identityPublicKey,
    required this.e2ePublicKey,
    this.allowDirect = true,
    this.allowRelay = false,
  });

  final String peerId;
  final String endpointAddress;
  final Uint8List identityPublicKey;
  final Uint8List e2ePublicKey;
  final bool allowDirect;
  final bool allowRelay;
}

final class SdkRelayConfig {
  const SdkRelayConfig({
    required this.relayUrl,
    required this.relayCredential,
    required this.relaySigningSeed,
  });

  final String relayUrl;
  final String relayCredential;
  final Uint8List relaySigningSeed;
}

final class SdkTransferSession {
  const SdkTransferSession({
    required this.transferId,
    required this.peerId,
    required this.filePath,
    required this.routeType,
  });

  final String transferId;
  final String peerId;
  final String filePath;
  final NetworkRouteType routeType;
}

final class SdkRouteSnapshot {
  const SdkRouteSnapshot({
    required this.peerId,
    required this.routeType,
    this.topology = NetworkRouteTopology.unspecified,
    this.transport = NetworkRouteTransport.unspecified,
    this.endpoint,
    this.rtt,
    this.loss,
  });

  final String peerId;
  final NetworkRouteType routeType;
  final NetworkRouteTopology topology;
  final NetworkRouteTransport transport;
  final String? endpoint;
  final Duration? rtt;
  final double? loss;
}
