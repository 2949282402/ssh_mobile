/// Entry point for the dependency-free telemetry producer source-ban checker.
library;

import 'dart:io';

import 'check_telemetry_producers_scan.dart' as scanner;

/// Scans the repository for forbidden telemetry producer references.
List<String> scanForViolations(Directory repoRoot) =>
    scanner.scanForViolations(repoRoot);

void main() {
  final violations = scanForViolations(_repoRoot());
  if (violations.isEmpty) {
    stdout.writeln('Telemetry producer source-ban check passed.');
    return;
  }

  stderr.writeln('Telemetry producer source-ban violations:');
  for (final violation in violations) {
    stderr.writeln('  $violation');
  }
  exitCode = 1;
}

Directory _repoRoot() {
  var directory = Directory.current;
  while (!File('${directory.path}/pubspec.yaml').existsSync()) {
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError(
        'Could not locate repository root from ${Directory.current.path}',
      );
    }
    directory = parent;
  }
  return directory;
}
