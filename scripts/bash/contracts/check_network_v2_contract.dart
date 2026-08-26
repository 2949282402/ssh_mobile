// Network Protocol V2 Schema Parity Gate
//
// Automatically verifies tag and field parity among:
// 1. protocol/proto/network/v2/network.proto (Canonical schema)
// 2. native/network_core/crates/network-protocol/src/lib.rs (Rust prost structs)
// 3. apps/ssh_mobile_full/lib/services/network/network_protocol_v2_codec.dart (Dart hand-written codec)

import 'dart:io';

void main() {
  final repoRoot = _findRepoRoot();
  final protoFile = File(
    '${repoRoot.path}/protocol/proto/network/v2/network.proto',
  );
  final rustFile = File(
    '${repoRoot.path}/native/network_core/crates/network-protocol/src/lib.rs',
  );
  final dartCodecFile = File(
    '${repoRoot.path}/apps/ssh_mobile_full/lib/services/network/network_protocol_v2_codec.dart',
  );

  if (!protoFile.existsSync() ||
      !rustFile.existsSync() ||
      !dartCodecFile.existsSync()) {
    stderr.writeln('ERROR: One or more protocol contract files missing.');
    exit(1);
  }

  final protoContent = protoFile.readAsStringSync();
  final rustContent = rustFile.readAsStringSync();
  final dartContent = dartCodecFile.readAsStringSync();

  final failures = <String>[];

  void check(bool condition, String message) {
    if (!condition) {
      failures.add(message);
    }
  }

  // 1. Check TransferProgressEvent tags
  check(
    protoContent.contains('message TransferProgressEvent') &&
        protoContent.contains('string transfer_id = 1;') &&
        protoContent.contains('uint64 bytes_transferred = 2;') &&
        protoContent.contains('uint64 total_bytes = 3;') &&
        protoContent.contains('string peer_id = 4;'),
    'network.proto: TransferProgressEvent missing peer_id = 4 or field mismatch',
  );
  check(
    rustContent.contains('pub struct TransferProgressEvent') &&
        rustContent.contains(
          '#[prost(string, tag = "4")]\n    pub peer_id: String,',
        ),
    'Rust lib.rs: TransferProgressEvent missing peer_id tag 4',
  );
  check(
    dartContent.contains(
      'case 4:\n          peerId = utf8.decode(reader.bytes(field.wireType));',
    ),
    'Dart codec: decodeProgress missing case 4 for peerId',
  );

  // 2. Check IncomingTransferOfferEvent tags
  check(
    protoContent.contains('message IncomingTransferOfferEvent') &&
        protoContent.contains('string transfer_id = 1;') &&
        protoContent.contains('string peer_id = 2;') &&
        protoContent.contains('string file_name = 3;') &&
        protoContent.contains('uint64 file_size = 4;') &&
        protoContent.contains('RouteType route_type = 5;'),
    'network.proto: IncomingTransferOfferEvent missing route_type = 5',
  );
  check(
    rustContent.contains('pub struct IncomingTransferOfferEvent') &&
        rustContent.contains(
          '#[prost(enumeration = "RouteType", optional, tag = "5")]\n    pub route_type: Option<i32>,',
        ),
    'Rust lib.rs: IncomingTransferOfferEvent missing route_type tag 5',
  );
  check(
    dartContent.contains(
      'case 5:\n          route = reader.varint(field.wireType);',
    ),
    'Dart codec: decodeOffer missing case 5 for route',
  );

  // 3. Check TransferCompletedEvent tags
  check(
    protoContent.contains('message TransferCompletedEvent') &&
        protoContent.contains('string transfer_id = 1;') &&
        protoContent.contains('string local_path = 2;') &&
        protoContent.contains('string peer_id = 3;'),
    'network.proto: TransferCompletedEvent missing peer_id = 3',
  );
  check(
    rustContent.contains('pub struct TransferCompletedEvent') &&
        rustContent.contains(
          '#[prost(string, tag = "3")]\n    pub peer_id: String,',
        ),
    'Rust lib.rs: TransferCompletedEvent missing peer_id tag 3',
  );
  check(
    dartContent.contains(
      'case 3:\n          peerId = utf8.decode(reader.bytes(field.wireType));',
    ),
    'Dart codec: decodeCompleted missing case 3 for peerId',
  );

  // 4. Check TransferFailedEvent tags
  check(
    protoContent.contains('message TransferFailedEvent') &&
        protoContent.contains('string transfer_id = 1;') &&
        protoContent.contains('NetworkError error = 2;') &&
        protoContent.contains('string peer_id = 3;'),
    'network.proto: TransferFailedEvent missing peer_id = 3',
  );
  check(
    rustContent.contains('pub struct TransferFailedEvent') &&
        rustContent.contains(
          '#[prost(string, tag = "3")]\n    pub peer_id: String,',
        ),
    'Rust lib.rs: TransferFailedEvent missing peer_id tag 3',
  );
  check(
    dartContent.contains(
      'case 3:\n          peerId = utf8.decode(reader.bytes(field.wireType));',
    ),
    'Dart codec: decodeFailed missing case 3 for peerId',
  );

  // 5. Check ConnectPeerCommand tags
  check(
    protoContent.contains('message ConnectPeerCommand') &&
        protoContent.contains('string peer_id = 1;') &&
        protoContent.contains('uint32 intent = 2;') &&
        protoContent.contains('CommunicationClass communication_class = 3;'),
    'network.proto: ConnectPeerCommand missing communication_class = 3',
  );
  check(
    rustContent.contains('pub struct ConnectPeerCommand') &&
        rustContent.contains(
          '#[prost(enumeration = "CommunicationClass", tag = "3")]\n    pub communication_class: i32,',
        ),
    'Rust lib.rs: ConnectPeerCommand missing communication_class tag 3',
  );
  check(
    dartContent.contains('..varint(3, communicationClass.wireValue);'),
    'Dart codec: connectPeer missing communication_class tag 3',
  );

  // 6. Check SshStream tags in NetworkCommand oneof and NetworkEvent oneof
  check(
    protoContent.contains('SshStreamOpenCommand ssh_stream_open = 25;') &&
        protoContent.contains('SshStreamDataCommand ssh_stream_data = 26;') &&
        protoContent.contains('SshStreamCloseCommand ssh_stream_close = 27;'),
    'network.proto: NetworkCommand missing SSH stream command tags (25, 26, 27)',
  );
  check(
    protoContent.contains(
          'SshStreamDataReceivedEvent ssh_stream_data_received = 26;',
        ) &&
        protoContent.contains('SshStreamClosedEvent ssh_stream_closed = 27;'),
    'network.proto: NetworkEvent missing SSH stream event tags (26, 27)',
  );
  check(
    dartContent.contains(
          'case 26:\n          sshStreamData = _streamEvents.decodeData(',
        ) &&
        dartContent.contains(
          'case 27:\n          sshStreamClosed = _streamEvents.decodeClosed(',
        ),
    'Dart codec: decodeEvent missing SSH stream cases (26, 27)',
  );

  // 7. Check Presence tags in NetworkEvent oneof
  check(
    protoContent.contains(
          'PeerPresenceChangedEvent peer_presence_changed = 24;',
        ) &&
        protoContent.contains(
          'PeerPresenceSnapshotEvent peer_presence_snapshot = 25;',
        ),
    'network.proto: NetworkEvent missing Presence event tags (24, 25)',
  );
  check(
    dartContent.contains(
          'case 24:\n          event = _peerEvents.decodePresence(',
        ) &&
        dartContent.contains(
          'case 25:\n          event = _peerEvents.decodePresenceSnapshot(',
        ),
    'Dart codec: decodeEvent missing Presence cases (24, 25)',
  );

  if (failures.isNotEmpty) {
    stderr.writeln(
      'FAILED: Protocol V2 Schema Parity Gate detected mismatches:',
    );
    for (final f in failures) {
      stderr.writeln('  - $f');
    }
    exit(1);
  }

  stdout.writeln(
    'SUCCESS: Network Protocol V2 Canonical Wire Parity verified across proto, Rust, and Dart.',
  );
}

Directory _findRepoRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/CLAUDE.md').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('Cannot find repo root containing CLAUDE.md');
    }
    dir = parent;
  }
  return dir;
}
