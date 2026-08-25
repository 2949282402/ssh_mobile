import 'dart:typed_data';

import 'package:network_sdk/network_sdk.dart';
import 'package:test/test.dart';

void main() {
  test('connectPeer never registers trust implicitly', () async {
    final sessions = _RecordingSessionClient();
    final facade = NetworkFacadeImpl(sessions: sessions);

    final result = await facade.connectPeer('peer-a');

    expect(result, isA<SdkSuccess<void>>());
    expect(sessions.upserted, isEmpty);
    expect(sessions.connectedPeerIds, <String>['peer-a']);
  });

  test(
    'removePeer is an explicit trust and connection deletion operation',
    () async {
      final sessions = _RecordingSessionClient();
      final facade = NetworkFacadeImpl(sessions: sessions);

      final result = await facade.removePeer('peer-a');

      expect(result, isA<SdkSuccess<void>>());
      expect(sessions.removedPeerIds, <String>['peer-a']);
    },
  );

  test('peer route authorization is carried in the V2 config', () {
    final config = SdkPeerConfig(
      peerId: 'peer-a',
      endpointAddress: '',
      identityPublicKey: Uint8List.fromList(<int>[1, 2, 3]),
      e2ePublicKey: Uint8List.fromList(<int>[4, 5, 6]),
      allowDirect: true,
      allowRelay: true,
    );

    expect(config.allowDirect, isTrue);
    expect(config.allowRelay, isTrue);
  });

  test(
    'bulk transfer is the only file communication class accepted by facade',
    () async {
      final sessions = _RecordingSessionClient();
      final facade = NetworkFacadeImpl(sessions: sessions);

      final result = await facade.transferFile(
        transferId: 'transfer-a',
        peerId: 'peer-a',
        filePath: '/tmp/payload.bin',
        communicationClass: CommunicationClass.reliableStream,
      );

      expect(result, isA<SdkFailure<SdkTransferSession>>());
      expect(
        (result as SdkFailure<SdkTransferSession>).error.code,
        NetworkErrorCode.invalidArgument,
      );
      expect(sessions.sentTransferIds, isEmpty);
    },
  );
}

final class _RecordingSessionClient implements SessionClient {
  final List<SdkPeerConfig> upserted = <SdkPeerConfig>[];
  final List<String> removedPeerIds = <String>[];
  final List<String> connectedPeerIds = <String>[];
  final List<String> sentTransferIds = <String>[];

  @override
  Future<SdkResult<void>> upsertPeer(SdkPeerConfig peer) async {
    upserted.add(peer);
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> removePeer(String peerId) async {
    removedPeerIds.add(peerId);
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> connect(
    String peerId, {
    CommunicationClass communicationClass = CommunicationClass.reliableStream,
  }) async {
    connectedPeerIds.add(peerId);
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<SdkTransferSession>> send({
    required String transferId,
    required String peerId,
    required String filePath,
  }) async {
    sentTransferIds.add(transferId);
    return SdkSuccess(
      SdkTransferSession(
        transferId: transferId,
        peerId: peerId,
        filePath: filePath,
        routeType: NetworkRouteType.quicDirect,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected SessionClient call: $invocation');
}
