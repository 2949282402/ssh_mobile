// Critical Network V2 Wire Contract Parity Gate.
//
// The schema is canonical; the Rust and Dart hand-written bindings are loaded
// from their stable entrypoints and all reachable split modules before the
// field/tag/case checks run.

import 'dart:io';

import 'network_v2_contract_checks.dart';
import 'network_v2_contract_self_tests.dart';
import 'network_v2_contract_sources.dart';

export 'network_v2_contract_checks.dart';
export 'network_v2_contract_sources.dart';

void main(List<String> args) {
  final sources = _loadSourcesOrExit();
  if (args.contains('--test')) {
    runNetworkV2ContractSelfTests(sources);
    return;
  }

  final failures = verifySchemaParity(
    protoContent: sources.protoContent,
    rustContent: sources.rustContent,
    dartContent: sources.dartContent,
  );
  if (failures.isNotEmpty) {
    stderr.writeln(
      'FAILED: Protocol V2 Schema Parity Gate detected mismatches:',
    );
    for (final failure in failures) {
      stderr.writeln('  - $failure');
    }
    exit(1);
  }

  stdout.writeln(
    'SUCCESS: Critical Network V2 wire contracts verified across proto, Rust, and Dart.',
  );
}

/// Retains the historical script-level self-test entrypoint for callers that
/// import this checker while keeping the self-test implementation separate.
void runSelfTests() {
  runNetworkV2ContractSelfTests(_loadSourcesOrExit());
}

NetworkV2ContractSources _loadSourcesOrExit() {
  final repoRoot = _findRepoRoot();
  try {
    return loadNetworkV2ContractSources(repoRoot);
  } on Object catch (error) {
    stderr.writeln('ERROR: Unable to load Network V2 contract sources: $error');
    exit(1);
  }
}

Directory _findRepoRoot() {
  var directory = Directory.current;
  while (!File('${directory.path}/CLAUDE.md').existsSync()) {
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('Cannot find repo root containing CLAUDE.md');
    }
    directory = parent;
  }
  return directory;
}
