/// Source-tree scanning and contract-name checks for the telemetry producer
/// boundary. Kept separate from the lexical helpers so each module remains
/// small enough to review and test independently.
library;

import 'dart:io';

import 'check_telemetry_producers_lexer.dart' as lexer;
import 'gen_telemetry_contract.dart';

const List<String> producerRoots = <String>[
  'apps/ssh_mobile_full/lib',
  'packages/core/app_core/lib/src',
  'front/src',
  'relay/internal/telemetry',
];

const Set<String> sourceExtensions = <String>{
  '.dart',
  '.go',
  '.cjs',
  '.js',
  '.mjs',
  '.jsx',
  '.ts',
  '.tsx',
};

/// Returns one human-readable violation for each forbidden producer reference.
///
/// [repoRoot] must be the repository root. Missing contract YAML files are
/// tolerated so fixture tests can exercise the structural bans in isolation;
/// the CI entry point always runs from a complete checkout and therefore also
/// checks every event and error-code literal loaded from YAML.
List<String> scanForViolations(Directory repoRoot) {
  final contractNames = _contractNames(repoRoot);
  final generatedSources = _expectedGeneratedSources(repoRoot);
  final violations = <String>[];

  for (final relativeRoot in producerRoots) {
    final root = Directory('${repoRoot.path}/$relativeRoot');
    if (!root.existsSync()) continue;
    final entities = root.listSync(recursive: true, followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entity in entities) {
      if (entity is! File || !_isSourceFile(entity.path)) continue;
      if (_isTestFile(entity.path)) continue;
      final relativePath = _canonicalRelativePath(
        _relativePath(repoRoot, entity.path),
      );
      final source = entity.readAsStringSync();
      if (_isVerifiedGeneratedArtifact(
        relativePath,
        source,
        generatedSources,
      )) {
        continue;
      }
      final code = lexer.withoutComments(source);

      if (_basename(entity.path) == 'app_telemetry_contract.dart') {
        violations.add('$relativePath: deleted app telemetry contract mirror');
      }
      _addPatternViolations(
        violations,
        relativePath,
        code,
        RegExp(r'\bAppTelemetry(?:Events|ErrorCodes|Contract)\b'),
        'legacy AppTelemetry contract reference',
      );
      _addPatternViolations(
        violations,
        relativePath,
        code,
        RegExp(r'\bapp_telemetry_contract(?:\.dart)?\b'),
        'legacy app_telemetry_contract mirror reference',
      );
      _addPatternViolations(
        violations,
        relativePath,
        code,
        RegExp(r'\b(?:recordEvent|recordDiagnostic)\s*\('),
        'legacy telemetry recording API (recordEvent/recordDiagnostic); use record(event: ...)',
      );
      if (_basename(entity.path) != 'telemetry_catalog.dart') {
        _addPatternViolations(
          violations,
          relativePath,
          code,
          RegExp(r'\bTelemetryEventDefinition\s*\('),
          'business code must use a generated TelemetryEvents definition',
        );
      }
      if (relativePath.startsWith('front/src/') &&
          RegExp(
            r'contracts/telemetry/(?:events|error_codes)\.json',
          ).hasMatch(code)) {
        violations.add(
          '$relativePath: direct root contracts/telemetry events/error_codes import; use generated contract output',
        );
      }

      for (final literal in lexer.stringLiterals(code)) {
        if (contractNames.eventNames.contains(literal.value)) {
          violations.add(
            '$relativePath:${lexer.lineNumber(code, literal.offset)}: raw telemetry event literal "${literal.value}"',
          );
        }
        if (contractNames.errorCodes.contains(literal.value)) {
          violations.add(
            '$relativePath:${lexer.lineNumber(code, literal.offset)}: raw telemetry error-code literal "${literal.value}"',
          );
        }
      }
    }
  }

  const mirrorJsonPaths = <String>[
    'relay/internal/telemetry/contracts/telemetry/events.json',
    'relay/internal/telemetry/contracts/telemetry/error_codes.json',
  ];
  for (final relativePath in mirrorJsonPaths) {
    if (File('${repoRoot.path}/$relativePath').existsSync()) {
      violations.add(
        '$relativePath: duplicate relay telemetry contract mirror',
      );
    }
  }

  return violations;
}

Map<String, String> _expectedGeneratedSources(Directory repoRoot) {
  try {
    return expectedFiles(repoRoot);
  } on Object {
    // Keep structural checks useful for isolated fixture roots that omit the
    // contract YAML. A complete checkout is checked by the contract gate.
    return const <String, String>{};
  }
}

bool _isVerifiedGeneratedArtifact(
  String relativePath,
  String source,
  Map<String, String> expectedSources,
) {
  final expected = expectedSources[relativePath];
  return expected != null &&
      source.startsWith(generatedHeader) &&
      source == expected;
}

_ContractNames _contractNames(Directory repoRoot) {
  final eventsFile = File('${repoRoot.path}/contracts/telemetry/events.yaml');
  final errorsFile = File(
    '${repoRoot.path}/contracts/telemetry/error_codes.yaml',
  );
  if (!eventsFile.existsSync() || !errorsFile.existsSync()) {
    return const _ContractNames(<String>{}, <String>{});
  }
  final contract = loadContract(repoRoot);
  return _ContractNames(
    contract.events.map((event) => event.name).toSet(),
    contract.errorCodes.map((error) => error.code).toSet(),
  );
}

void _addPatternViolations(
  List<String> violations,
  String relativePath,
  String source,
  Pattern pattern,
  String message,
) {
  for (final match in pattern.allMatches(source)) {
    violations.add(
      '$relativePath:${lexer.lineNumber(source, match.start)}: $message',
    );
  }
}

bool _isSourceFile(String path) =>
    sourceExtensions.contains(_extension(path).toLowerCase());

bool _isTestFile(String path) {
  final name = _basename(path).toLowerCase();
  return name.endsWith('_test.dart') ||
      name.endsWith('_test.go') ||
      name.endsWith('.test.ts') ||
      name.endsWith('.test.tsx') ||
      name.endsWith('.spec.ts') ||
      name.endsWith('.spec.tsx');
}

String _canonicalRelativePath(String path) =>
    path.replaceAll(Platform.pathSeparator, '/');

String _relativePath(Directory root, String path) => path.substring(
  root.path.length + (root.path.endsWith(Platform.pathSeparator) ? 0 : 1),
);

String _basename(String path) => path.split(Platform.pathSeparator).last;

String _extension(String path) {
  final name = _basename(path);
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot);
}

class _ContractNames {
  const _ContractNames(this.eventNames, this.errorCodes);

  final Set<String> eventNames;
  final Set<String> errorCodes;
}
