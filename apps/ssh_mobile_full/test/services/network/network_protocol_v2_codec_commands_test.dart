// Network Protocol V2 command and ReliableStream command golden tests.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:ssh_mobile/services/network/network_protocol_v2_codec.dart';

import 'network_protocol_v2_codec_test_utils.dart';

void main() {
  const codec = NetworkProtocolV2Codec();

  test('ssh stream commands encode native tags 25/26/27', () {
    final open = codec.sshStreamOpenCommand(
      commandId: 'open-1',
      peerId: 'peer-a',
      handle: const SshStreamHandle(openerDeviceId: 'device-a', streamId: 7),
      service: 'ssh',
    );
    expect(open, isNotEmpty);
    expect(open, contains(0xca)); // field 25 key prefix
    expect(open, contains(0x07)); // stream_id = 7

    final data = codec.sshStreamDataCommand(
      commandId: 'data-1',
      peerId: 'peer-a',
      handle: const SshStreamHandle(openerDeviceId: 'device-a', streamId: 7),
      data: Uint8List.fromList(<int>[0xde, 0xad, 0xbe, 0xef]),
    );
    expect(data, isNotEmpty);
    expect(data, contains(0xd2)); // field 26 key prefix
    expect(data, contains(0xde));
    expect(data, contains(0xef));

    final close = codec.sshStreamCloseCommand(
      commandId: 'close-1',
      peerId: 'peer-a',
      handle: const SshStreamHandle(openerDeviceId: 'device-a', streamId: 7),
    );
    expect(close, isNotEmpty);
    expect(close, contains(0xda)); // field 27 key prefix
  });

  test('control commands encode every V2 command payload boundary', () {
    final commands = <Uint8List>[
      codec.configureRuntimeCommand(
        commandId: 'configure',
        config: NetworkRuntimeConfig(
          deviceId: 'device-a',
          identityPrivateKey: Uint8List.fromList(List.filled(32, 1)),
          e2ePrivateKey: Uint8List.fromList(List.filled(32, 2)),
          listenAddress: '127.0.0.1:0',
          receiveDirectory: '/tmp/receive',
        ),
      ),
      codec.upsertPeerCommand(
        commandId: 'upsert',
        peer: PeerConfig(
          peerId: 'peer-a',
          endpointAddress: '127.0.0.1:4433',
          identityPublicKey: Uint8List.fromList(List.filled(32, 3)),
          e2ePublicKey: Uint8List.fromList(List.filled(32, 4)),
        ),
      ),
      codec.removePeerCommand(commandId: 'remove', peerId: 'peer-a'),
      codec.disconnectPeerCommand(commandId: 'disconnect', peerId: 'peer-a'),
      codec.sendFileCommand(
        commandId: 'send',
        transferId: 'transfer-a',
        peerId: 'peer-a',
        filePath: '/tmp/payload.bin',
      ),
      codec.cancelTransferCommand(
        commandId: 'cancel',
        transferId: 'transfer-a',
      ),
      codec.respondIncomingTransferCommand(
        commandId: 'accept',
        transferId: 'transfer-a',
        accept: true,
      ),
      codec.respondIncomingTransferCommand(
        commandId: 'reject',
        transferId: 'transfer-a',
        accept: false,
      ),
      codec.configureRelayCommand(
        commandId: 'relay',
        config: RelayConfig(
          relayUrl: 'wss://relay.example.test/ws',
          relayCredential: 'credential',
          relaySigningSeed: Uint8List.fromList(List.filled(32, 5)),
        ),
      ),
    ];

    expect(commands, everyElement(isNotEmpty));
    expect(
      commands.map(codec.commandId),
      containsAll(<String>[
        'configure',
        'upsert',
        'disconnect',
        'send',
        'cancel',
        'accept',
        'reject',
        'relay',
      ]),
    );
  });

  test('peer registration carries explicit Direct and Relay authorization', () {
    final encoded = codec.upsertPeerCommand(
      commandId: 'u',
      peer: PeerConfig(
        peerId: 'peer-a',
        endpointAddress: '',
        identityPublicKey: Uint8List(32),
        e2ePublicKey: Uint8List(32),
        allowDirect: true,
        allowRelay: true,
      ),
    );

    // PeerConfig fields 6 and 7 are bool route authorizations.  They are
    // intentionally carried on the V2 command rather than inferred from
    // endpoint discovery or local Relay enrollment.
    expect(containsSubsequence(encoded, <int>[0x28, 0x00]), isTrue);
    expect(containsSubsequence(encoded, <int>[0x30, 0x01]), isTrue);
    expect(containsSubsequence(encoded, <int>[0x38, 0x01]), isTrue);
  });
}
