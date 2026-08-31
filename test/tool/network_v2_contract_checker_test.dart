import 'dart:io';

import '../../scripts/bash/contracts/network_v2_contract_checks.dart';
import '../../scripts/bash/contracts/network_v2_contract_sources.dart';

/// Regression coverage for the Network V2 parity checker's split-source input.
///
/// The checker is an executable CI contract rather than a package library, so
/// this test runs its production entrypoint against the repository sources.
void main() {
  final root = _findRepositoryRoot();
  final sources = loadNetworkV2ContractSources(root);

  _expect(sources.rustSourcePaths, <String>[
    'native/network_core/crates/network-protocol/src/lib.rs',
    'native/network_core/crates/network-protocol/src/commands.rs',
    'native/network_core/crates/network-protocol/src/enums.rs',
    'native/network_core/crates/network-protocol/src/events.rs',
    'native/network_core/crates/network-protocol/src/messages.rs',
  ], 'Rust protocol source discovery must include the entrypoint and modules');
  _expect(sources.dartSourcePaths, <String>[
    'apps/ssh_mobile_full/lib/services/network/network_protocol_v2_codec.dart',
    'apps/ssh_mobile_full/lib/app/network/network_protocol_v2_codec_commands.dart',
    'apps/ssh_mobile_full/lib/app/network/network_protocol_v2_codec_envelope.dart',
    'apps/ssh_mobile_full/lib/app/network/network_protocol_v2_codec_peer_events.dart',
    'apps/ssh_mobile_full/lib/app/network/network_protocol_v2_codec_transfer_events.dart',
    'apps/ssh_mobile_full/lib/app/network/network_protocol_v2_codec_stream_events.dart',
    'apps/ssh_mobile_full/lib/app/network/network_protocol_v2_codec_wire.dart',
  ], 'Dart protocol source discovery must include every declared part');

  _expect(
    sources.rustContent.contains('pub struct TransferProgressEvent') &&
        sources.rustContent.contains('pub struct SshStreamClosedEvent'),
    true,
    'Rust parity input must contain declarations from split event modules',
  );
  _expect(
    sources.dartContent.contains('final class _NetworkCommandEncoder') &&
        sources.dartContent.contains('NetworkProtocolFrame _decodeEvent'),
    true,
    'Dart parity input must contain declarations from split codec parts',
  );
  final dispatcher = extractDartMethod(sources.dartContent, '_decodeEvent');
  _expect(
    dispatcher.contains('case 24:') &&
        dispatcher.contains('case 26:') &&
        dispatcher.contains('case 32:'),
    true,
    'Dart parity input must inspect the split envelope dispatcher',
  );

  for (final arguments in const [
    <String>[],
    <String>['--test'],
  ]) {
    final result = Process.runSync(Platform.resolvedExecutable, <String>[
      'run',
      'scripts/bash/contracts/check_network_v2_contract.dart',
      ...arguments,
    ], workingDirectory: root.path);
    if (result.exitCode != 0) {
      throw StateError(
        'Network V2 parity checker must pass against split authoritative sources.\n'
        'arguments: $arguments\n'
        'stdout:\n${result.stdout}\n'
        'stderr:\n${result.stderr}',
      );
    }
  }
  stdout.writeln('Network V2 parity checker split-source regression passed.');
}

void _expect(Object actual, Object expected, String message) {
  if (actual is List && expected is List) {
    if (actual.length == expected.length &&
        actual.asMap().entries.every(
          (entry) => entry.value == expected[entry.key],
        )) {
      return;
    }
  } else if (actual == expected) {
    return;
  }
  throw StateError(message);
}

Directory _findRepositoryRoot() {
  var current = Directory.current;
  while (!File('${current.path}/pubspec.yaml').existsSync()) {
    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Unable to find the repository root.');
    }
    current = parent;
  }
  return current;
}
