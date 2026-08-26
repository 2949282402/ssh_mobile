// Critical Network V2 Wire Contract Parity Gate
//
// Automatically verifies tag and field parity of critical commands and events among:
// 1. protocol/proto/network/v2/network.proto (Canonical schema)
// 2. native/network_core/crates/network-protocol/src/lib.rs (Rust prost structs)
// 3. apps/ssh_mobile_full/lib/services/network/network_protocol_v2_codec.dart (Dart hand-written codec)

import 'dart:io';

void main(List<String> args) {
  if (args.contains('--test')) {
    runSelfTests();
    return;
  }

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

  final failures = verifySchemaParity(
    protoContent: protoContent,
    rustContent: rustContent,
    dartContent: dartContent,
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
    'SUCCESS: Critical Network V2 wire contracts verified across proto, Rust, and Dart.',
  );
}

List<String> verifySchemaParity({
  required String protoContent,
  required String rustContent,
  required String dartContent,
}) {
  final failures = <String>[];

  void check(bool condition, String message) {
    if (!condition) {
      failures.add(message);
    }
  }

  // 1. Check TransferProgressEvent block
  final protoProgress = extractProtoMessage(
    protoContent,
    'TransferProgressEvent',
  );
  final rustProgress = extractRustStruct(rustContent, 'TransferProgressEvent');
  final dartProgress = extractDartMethod(dartContent, 'decodeProgress');

  check(
    protoProgress.contains('string transfer_id = 1;') &&
        protoProgress.contains('uint64 bytes_transferred = 2;') &&
        protoProgress.contains('uint64 total_bytes = 3;') &&
        protoProgress.contains('string peer_id = 4;'),
    'network.proto: TransferProgressEvent block missing peer_id = 4 or field mismatch',
  );
  check(
    rustProgress.contains(
      '#[prost(string, tag = "4")]\n    pub peer_id: String,',
    ),
    'Rust lib.rs: TransferProgressEvent struct missing peer_id tag 4',
  );
  check(
    dartProgress.contains(
      'case 4:\n          peerId = utf8.decode(reader.bytes(field.wireType));',
    ),
    'Dart codec: decodeProgress method missing case 4 for peerId',
  );

  // 2. Check IncomingTransferOfferEvent block
  final protoOffer = extractProtoMessage(
    protoContent,
    'IncomingTransferOfferEvent',
  );
  final rustOffer = extractRustStruct(
    rustContent,
    'IncomingTransferOfferEvent',
  );
  final dartOffer = extractDartMethod(dartContent, 'decodeOffer');

  check(
    protoOffer.contains('string transfer_id = 1;') &&
        protoOffer.contains('string peer_id = 2;') &&
        protoOffer.contains('string file_name = 3;') &&
        protoOffer.contains('uint64 file_size = 4;') &&
        protoOffer.contains('RouteType route_type = 5;'),
    'network.proto: IncomingTransferOfferEvent block missing route_type = 5',
  );
  check(
    rustOffer.contains(
      '#[prost(enumeration = "RouteType", optional, tag = "5")]\n    pub route_type: Option<i32>,',
    ),
    'Rust lib.rs: IncomingTransferOfferEvent struct missing route_type tag 5',
  );
  check(
    dartOffer.contains(
      'case 5:\n          route = reader.varint(field.wireType);',
    ),
    'Dart codec: decodeOffer method missing case 5 for route',
  );

  // 3. Check TransferCompletedEvent block
  final protoCompleted = extractProtoMessage(
    protoContent,
    'TransferCompletedEvent',
  );
  final rustCompleted = extractRustStruct(
    rustContent,
    'TransferCompletedEvent',
  );
  final dartCompleted = extractDartMethod(dartContent, 'decodeCompleted');

  check(
    protoCompleted.contains('string transfer_id = 1;') &&
        protoCompleted.contains('string local_path = 2;') &&
        protoCompleted.contains('string peer_id = 3;'),
    'network.proto: TransferCompletedEvent block missing peer_id = 3',
  );
  check(
    rustCompleted.contains(
      '#[prost(string, tag = "3")]\n    pub peer_id: String,',
    ),
    'Rust lib.rs: TransferCompletedEvent struct missing peer_id tag 3',
  );
  check(
    dartCompleted.contains(
      'case 3:\n          peerId = utf8.decode(reader.bytes(field.wireType));',
    ),
    'Dart codec: decodeCompleted method missing case 3 for peerId',
  );

  // 4. Check TransferFailedEvent block
  final protoFailed = extractProtoMessage(protoContent, 'TransferFailedEvent');
  final rustFailed = extractRustStruct(rustContent, 'TransferFailedEvent');
  final dartFailed = extractDartMethod(dartContent, 'decodeFailed');

  check(
    protoFailed.contains('string transfer_id = 1;') &&
        protoFailed.contains('NetworkError error = 2;') &&
        protoFailed.contains('string peer_id = 3;'),
    'network.proto: TransferFailedEvent block missing peer_id = 3',
  );
  check(
    rustFailed.contains(
      '#[prost(string, tag = "3")]\n    pub peer_id: String,',
    ),
    'Rust lib.rs: TransferFailedEvent struct missing peer_id tag 3',
  );
  check(
    dartFailed.contains(
      'case 3:\n          peerId = utf8.decode(reader.bytes(field.wireType));',
    ),
    'Dart codec: decodeFailed method missing case 3 for peerId',
  );

  // 5. Check ConnectPeerCommand block
  final protoConnect = extractProtoMessage(protoContent, 'ConnectPeerCommand');
  final rustConnect = extractRustStruct(rustContent, 'ConnectPeerCommand');
  final dartConnect = extractDartMethod(dartContent, 'connectPeer');

  check(
    protoConnect.contains('string peer_id = 1;') &&
        protoConnect.contains('uint32 intent = 2;') &&
        protoConnect.contains('CommunicationClass communication_class = 3;'),
    'network.proto: ConnectPeerCommand block missing communication_class = 3',
  );
  check(
    rustConnect.contains(
      '#[prost(enumeration = "CommunicationClass", tag = "3")]\n    pub communication_class: i32,',
    ),
    'Rust lib.rs: ConnectPeerCommand struct missing communication_class tag 3',
  );
  check(
    dartConnect.contains('..varint(3, communicationClass.wireValue);'),
    'Dart codec: connectPeer method missing communication_class tag 3',
  );

  // 6. Check SshStream tags in NetworkCommand oneof and NetworkEvent oneof
  final protoCommand = extractProtoMessage(protoContent, 'NetworkCommand');
  final protoEvent = extractProtoMessage(protoContent, 'NetworkEvent');
  final dartDecodeEvent = extractDartMethod(dartContent, 'decodeEvent');

  check(
    protoCommand.contains('SshStreamOpenCommand ssh_stream_open = 25;') &&
        protoCommand.contains('SshStreamDataCommand ssh_stream_data = 26;') &&
        protoCommand.contains('SshStreamCloseCommand ssh_stream_close = 27;'),
    'network.proto: NetworkCommand block missing SSH stream command tags (25, 26, 27)',
  );
  check(
    protoEvent.contains(
          'SshStreamDataReceivedEvent ssh_stream_data_received = 26;',
        ) &&
        protoEvent.contains('SshStreamClosedEvent ssh_stream_closed = 27;'),
    'network.proto: NetworkEvent block missing SSH stream event tags (26, 27)',
  );
  check(
    dartDecodeEvent.contains(
          'case 26:\n          sshStreamData = _streamEvents.decodeData(',
        ) &&
        dartDecodeEvent.contains(
          'case 27:\n          sshStreamClosed = _streamEvents.decodeClosed(',
        ),
    'Dart codec: decodeEvent method missing SSH stream cases (26, 27)',
  );

  // 7. Check Presence tags in NetworkEvent oneof
  check(
    protoEvent.contains(
          'PeerPresenceChangedEvent peer_presence_changed = 24;',
        ) &&
        protoEvent.contains(
          'PeerPresenceSnapshotEvent peer_presence_snapshot = 25;',
        ),
    'network.proto: NetworkEvent block missing Presence event tags (24, 25)',
  );
  check(
    dartDecodeEvent.contains(
          'case 24:\n          event = _peerEvents.decodePresence(',
        ) &&
        dartDecodeEvent.contains(
          'case 25:\n          event = _peerEvents.decodePresenceSnapshot(',
        ),
    'Dart codec: decodeEvent method missing Presence cases (24, 25)',
  );

  return failures;
}

String extractProtoMessage(String source, String messageName) {
  return extractBlock(
    source,
    RegExp(r'message\s+' + RegExp.escape(messageName) + r'\b'),
  );
}

String extractRustStruct(String source, String structName) {
  return extractBlock(
    source,
    RegExp(r'pub\s+struct\s+' + RegExp.escape(structName) + r'\b'),
  );
}

String extractDartMethod(String source, String methodName) {
  final headerPattern = RegExp(
    r'[A-Za-z0-9_<>?]+[\s\n]+\b' + RegExp.escape(methodName) + r'\b\s*\(',
  );
  final match = headerPattern.allMatches(source).firstOrNull;
  if (match == null) return '';
  // Find matching ')' for the parameter list (handling named params {} inside)
  var parenDepth = 1;
  var bodyStart = -1;
  for (var i = match.end; i < source.length; i++) {
    if (source[i] == '(') {
      parenDepth++;
    } else if (source[i] == ')') {
      parenDepth--;
      if (parenDepth == 0) {
        bodyStart = i + 1;
        break;
      }
    }
  }
  if (bodyStart == -1) return '';
  final openIdx = source.indexOf('{', bodyStart);
  if (openIdx == -1) return '';
  var depth = 1;
  for (var i = openIdx + 1; i < source.length; i++) {
    if (source[i] == '{') {
      depth++;
    } else if (source[i] == '}') {
      depth--;
      if (depth == 0) {
        return source.substring(openIdx + 1, i);
      }
    }
  }
  return '';
}

String extractBlock(
  String source,
  Pattern headerPattern, {
  String openChar = '{',
  String closeChar = '}',
}) {
  final match = headerPattern.allMatches(source).firstOrNull;
  if (match == null) return '';
  final startIdx = source.indexOf(openChar, match.end);
  if (startIdx == -1) return '';
  var depth = 1;
  for (var i = startIdx + 1; i < source.length; i++) {
    if (source[i] == openChar) {
      depth++;
    } else if (source[i] == closeChar) {
      depth--;
      if (depth == 0) {
        return source.substring(startIdx + 1, i);
      }
    }
  }
  return '';
}

void runSelfTests() {
  stdout.writeln('Running Parity Gate Self-Tests...');

  // Test 1: Misplaced tag in another message must fail
  const badProto = '''
message SomeOtherMessage {
  string peer_id = 3;
}
message TransferCompletedEvent {
  string transfer_id = 1;
  string local_path = 2;
}
''';
  const goodRust = '''
pub struct TransferCompletedEvent {
    #[prost(string, tag = "3")]
    pub peer_id: String,
}
''';
  const goodDart = '''
SdkTransferCompletedEvent _decodeCompleted(Uint8List payload) {
  switch (field.tag) {
    case 3:
      peerId = utf8.decode(reader.bytes(field.wireType));
  }
}
''';

  final failures = verifySchemaParity(
    protoContent: badProto,
    rustContent: goodRust,
    dartContent: goodDart,
  );

  assert(
    failures.any(
      (f) => f.contains('TransferCompletedEvent block missing peer_id = 3'),
    ),
    'Self-test failed: checker accepted peer_id=3 from the wrong message block!',
  );

  stdout.writeln(
    'Parity Gate Self-Tests PASSED: Block extraction prevents false-positive matches.',
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
