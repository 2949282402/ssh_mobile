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

  // 8. Check PeerTransferProgressEvent (wire tag 32)
  final protoPeerProgress = extractProtoMessage(
    protoContent,
    'PeerTransferProgressEvent',
  );
  final rustPeerProgress = extractRustStruct(
    rustContent,
    'PeerTransferProgressEvent',
  );
  final dartPeerProgress = extractDartMethod(
    dartContent,
    'decodePeerTransferProgress',
  );

  check(
    protoEvent.contains(
      'PeerTransferProgressEvent peer_transfer_progress = 32;',
    ),
    'network.proto: NetworkEvent block missing PeerTransferProgressEvent tag 32',
  );
  check(
    rustContent.contains(
      '#[prost(message, tag = "32")]\n        PeerTransferProgress(PeerTransferProgressEvent),',
    ),
    'Rust lib.rs: NetworkEvent payload missing PeerTransferProgress tag 32',
  );
  check(
    dartDecodeEvent.contains(
      'case 32:\n          event = _transferEvents.decodePeerTransferProgress(',
    ),
    'Dart codec: decodeEvent method missing case 32 for PeerTransferProgressEvent',
  );

  check(
    protoPeerProgress.contains('string peer_id = 1;') &&
        protoPeerProgress.contains('string transfer_id = 2;') &&
        protoPeerProgress.contains('uint64 confirmed_offset = 3;') &&
        protoPeerProgress.contains('uint64 total_bytes = 4;') &&
        protoPeerProgress.contains('bool paused = 5;'),
    'network.proto: PeerTransferProgressEvent block missing fields (peer_id=1, transfer_id=2, confirmed_offset=3, total_bytes=4, paused=5)',
  );
  check(
    rustPeerProgress.contains(
          '#[prost(string, tag = "1")]\n    pub peer_id: String,',
        ) &&
        rustPeerProgress.contains(
          '#[prost(string, tag = "2")]\n    pub transfer_id: String,',
        ) &&
        rustPeerProgress.contains(
          '#[prost(uint64, tag = "3")]\n    pub confirmed_offset: u64,',
        ) &&
        rustPeerProgress.contains(
          '#[prost(uint64, tag = "4")]\n    pub total_bytes: u64,',
        ) &&
        rustPeerProgress.contains(
          '#[prost(bool, tag = "5")]\n    pub paused: bool,',
        ),
    'Rust lib.rs: PeerTransferProgressEvent struct missing fields (tag 1..5)',
  );
  check(
    dartPeerProgress.contains(
          'case 1:\n          peerId = utf8.decode(reader.bytes(field.wireType));',
        ) &&
        dartPeerProgress.contains(
          'case 2:\n          transferId = utf8.decode(reader.bytes(field.wireType));',
        ) &&
        dartPeerProgress.contains(
          'case 3:\n          confirmedOffset = reader.varint(field.wireType);',
        ) &&
        dartPeerProgress.contains(
          'case 4:\n          totalBytes = reader.varint(field.wireType);',
        ) &&
        dartPeerProgress.contains(
          'case 5:\n          paused = reader.varint(field.wireType) != 0;',
        ),
    'Dart codec: decodePeerTransferProgress method missing cases for tags 1..5',
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

  final repoRoot = _findRepoRoot();
  final protoContent = File(
    '${repoRoot.path}/protocol/proto/network/v2/network.proto',
  ).readAsStringSync();
  final rustContent = File(
    '${repoRoot.path}/native/network_core/crates/network-protocol/src/lib.rs',
  ).readAsStringSync();
  final dartContent = File(
    '${repoRoot.path}/apps/ssh_mobile_full/lib/services/network/network_protocol_v2_codec.dart',
  ).readAsStringSync();

  // Baseline must pass
  final baselineFailures = verifySchemaParity(
    protoContent: protoContent,
    rustContent: rustContent,
    dartContent: dartContent,
  );
  assert(
    baselineFailures.isEmpty,
    'Baseline self-test failed with errors: $baselineFailures',
  );

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
  final test1Failures = verifySchemaParity(
    protoContent: badProto,
    rustContent: rustContent,
    dartContent: dartContent,
  );
  assert(
    test1Failures.any(
      (f) => f.contains('TransferCompletedEvent block missing peer_id = 3'),
    ),
    'Self-test 1 failed: checker accepted peer_id=3 from the wrong message block!',
  );

  // Test 2: Missing Dart decodeEvent case 32 must fail
  final dartWithoutCase32 = dartContent.replaceAll(
    'case 32:\n          event = _transferEvents.decodePeerTransferProgress(',
    '// removed case 32',
  );
  final test2Failures = verifySchemaParity(
    protoContent: protoContent,
    rustContent: rustContent,
    dartContent: dartWithoutCase32,
  );
  assert(
    test2Failures.any((f) => f.contains('decodeEvent method missing case 32')),
    'Self-test 2 failed: checker did not detect missing case 32 in decodeEvent!',
  );

  // Test 3: Misplaced case 32 (put into decodeOffer instead of decodeEvent)
  final dartMisplacedCase32 = dartWithoutCase32.replaceAll(
    'case 5:\n          route = reader.varint(field.wireType);',
    'case 5:\n          route = reader.varint(field.wireType);\n        case 32:\n          event = _transferEvents.decodePeerTransferProgress(',
  );
  final test3Failures = verifySchemaParity(
    protoContent: protoContent,
    rustContent: rustContent,
    dartContent: dartMisplacedCase32,
  );
  assert(
    test3Failures.any((f) => f.contains('decodeEvent method missing case 32')),
    'Self-test 3 failed: checker accepted case 32 in wrong method (decodeOffer)!',
  );

  // Test 4: Tag error in decodePeerTransferProgress (e.g. tag 3 mutated)
  final dartWrongTagInPeerProgress = dartContent.replaceAll(
    'case 3:\n          confirmedOffset = reader.varint(field.wireType);',
    'case 99:\n          confirmedOffset = reader.varint(field.wireType);',
  );
  final test4Failures = verifySchemaParity(
    protoContent: protoContent,
    rustContent: rustContent,
    dartContent: dartWrongTagInPeerProgress,
  );
  assert(
    test4Failures.any(
      (f) => f.contains(
        'decodePeerTransferProgress method missing cases for tags 1..5',
      ),
    ),
    'Self-test 4 failed: checker did not detect mutated tag in decodePeerTransferProgress!',
  );

  // Test 5: Missing field in proto PeerTransferProgressEvent
  final protoMissingField = protoContent.replaceAll(
    'bool paused = 5;',
    '// removed paused',
  );
  final test5Failures = verifySchemaParity(
    protoContent: protoMissingField,
    rustContent: rustContent,
    dartContent: dartContent,
  );
  assert(
    test5Failures.any(
      (f) => f.contains('PeerTransferProgressEvent block missing fields'),
    ),
    'Self-test 5 failed: checker did not detect missing field in proto PeerTransferProgressEvent!',
  );

  stdout.writeln(
    'Parity Gate Self-Tests PASSED: All 5 mutation tests verified successfully.',
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
