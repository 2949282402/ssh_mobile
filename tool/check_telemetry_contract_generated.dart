/// Staleness checker for generated telemetry contract artifacts.
///
/// Re-runs the exact generation pipeline exposed by
/// `tool/gen_telemetry_contract.dart` ([loadContract] + [renderAll]) and
/// compares every output byte-for-byte against the file on disk. Exits
/// nonzero when any generated file is missing or drifted from the YAML source
/// of truth.
///
/// Usage:
///   dart run tool/check_telemetry_contract_generated.dart
library;

import 'dart:io';

import 'gen_telemetry_contract.dart';

/// Verifies every generated artifact is up to date with the current YAML
/// sources of truth under [repoRoot]. Returns `true` when all files match;
/// prints the list of drifted/missing files to stderr and returns `false`
/// otherwise.
bool checkGenerated(Directory repoRoot) {
  final expected = expectedFiles(repoRoot);
  var allCurrent = true;
  for (final entry in expected.entries) {
    final file = File('${repoRoot.path}/${entry.key}');
    if (!file.existsSync()) {
      stderr.writeln('[STALE] missing: ${entry.key}');
      allCurrent = false;
      continue;
    }
    if (file.readAsStringSync() != entry.value) {
      stderr.writeln('[STALE] drift: ${entry.key}');
      allCurrent = false;
    }
  }
  return allCurrent;
}

Directory _repoRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      stderr.writeln(
          'Could not locate repo root from ${Directory.current.path}');
      throw const FormatException('repo root not found');
    }
    dir = parent;
  }
  return dir;
}

void main() {
  final repoRoot = _repoRoot();
  final ok = checkGenerated(repoRoot);
  if (ok) {
    stdout.writeln('Generated telemetry contract artifacts are up to date.');
  }
  exitCode = ok ? 0 : 1;
}