import 'dart:io';

import 'network_v2_contract_checks.dart';
import 'network_v2_contract_sources.dart';

void runNetworkV2ContractSelfTests(NetworkV2ContractSources sources) {
  stdout.writeln('Running Parity Gate Self-Tests...');

  final protoContent = sources.protoContent;
  final rustContent = sources.rustContent;
  final dartContent = sources.dartContent;

  void requireSelfTest(bool condition, String message) {
    if (!condition) {
      throw StateError(message);
    }
  }

  // Baseline must pass
  final baselineFailures = verifySchemaParity(
    protoContent: protoContent,
    rustContent: rustContent,
    dartContent: dartContent,
  );
  requireSelfTest(
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
  requireSelfTest(
    test1Failures.any(
      (f) => f.contains('TransferCompletedEvent block missing peer_id = 3'),
    ),
    'Self-test 1 failed: checker accepted peer_id=3 from the wrong message block!',
  );

  // Test 2: Missing Dart decodeEvent case 32 must fail
  final dartWithoutCase32 = dartContent.replaceFirst(
    RegExp(
      r'case\s+32:\s+event\s*=\s+(?:NetworkProtocolV2Codec\.)?_transferEvents\s*\.decodePeerTransferProgress\(',
    ),
    '// removed case 32',
  );
  final test2Failures = verifySchemaParity(
    protoContent: protoContent,
    rustContent: rustContent,
    dartContent: dartWithoutCase32,
  );
  requireSelfTest(
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
  requireSelfTest(
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
  requireSelfTest(
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
  requireSelfTest(
    test5Failures.any(
      (f) => f.contains('PeerTransferProgressEvent block missing fields'),
    ),
    'Self-test 5 failed: checker did not detect missing field in proto PeerTransferProgressEvent!',
  );

  // Test 6: Tag 32 misplaced in wrong Rust enum (outside network_event::Payload)
  final rustMisplacedTag32 = rustContent
      .replaceAll(
        '#[prost(message, tag = "32")]\n        PeerTransferProgress(PeerTransferProgressEvent),',
        '// removed from Payload',
      )
      .replaceAll(
        'pub enum RealtimeSignalKind {',
        'pub enum RealtimeSignalKind {\n        #[prost(message, tag = "32")]\n        PeerTransferProgress(PeerTransferProgressEvent),',
      );
  final test6Failures = verifySchemaParity(
    protoContent: protoContent,
    rustContent: rustMisplacedTag32,
    dartContent: dartContent,
  );
  requireSelfTest(
    test6Failures.any(
      (f) => f.contains(
        'network_event::Payload enum missing PeerTransferProgress tag 32',
      ),
    ),
    'Self-test 6 failed: checker accepted PeerTransferProgress tag 32 outside network_event::Payload!',
  );

  stdout.writeln(
    'Parity Gate Self-Tests PASSED: All 6 mutation tests verified successfully.',
  );
}
