/// Checks that telemetry producers use the generated typed contract API.
///
/// The YAML files under `contracts/telemetry` are the only source of event and
/// error-code names. Production source may refer to those names through the
/// generated definitions, but must not copy string literals or revive the
/// deleted app-local contract mirror.
library;

import 'dart:io';

import 'gen_telemetry_contract.dart';

const List<String> _producerRoots = <String>[
  'apps/ssh_mobile_full/lib',
  'packages/core/app_core/lib/src/telemetry',
  'front/src',
  'relay/internal/telemetry',
];

const Set<String> _sourceExtensions = <String>{
  '.dart',
  '.go',
  '.js',
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
  final violations = <String>[];

  for (final relativeRoot in _producerRoots) {
    final root = Directory('${repoRoot.path}/$relativeRoot');
    if (!root.existsSync()) continue;
    final entities = root.listSync(recursive: true, followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entity in entities) {
      if (entity is! File || !_isSourceFile(entity.path)) continue;
      if (_isTestFile(entity.path)) continue;
      if (_isGeneratedPath(entity.path)) continue;
      final relativePath = _relativePath(repoRoot, entity.path);
      final source = entity.readAsStringSync();
      final code = _withoutComments(source);

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

      for (final literal in _stringLiterals(code)) {
        if (contractNames.eventNames.contains(literal.value)) {
          violations.add(
            '$relativePath:${_lineNumber(code, literal.offset)}: raw telemetry event literal "${literal.value}"',
          );
        }
        if (contractNames.errorCodes.contains(literal.value)) {
          violations.add(
            '$relativePath:${_lineNumber(code, literal.offset)}: raw telemetry error-code literal "${literal.value}"',
          );
        }
      }
    }
  }

  final mirrorJsonPaths = <String>[
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

void main() {
  final repoRoot = _repoRoot();
  final violations = scanForViolations(repoRoot);
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
      '$relativePath:${_lineNumber(source, match.start)}: $message',
    );
  }
}

Iterable<_StringLiteral> _stringLiterals(String source) sync* {
  final pattern = RegExp(r'''(['"])((?:\\.|(?!\1)[^\\])*)\1''');
  for (final match in pattern.allMatches(source)) {
    final value = match.group(2);
    if (value != null) yield _StringLiteral(value, match.start);
  }
}

/// Replaces comments with whitespace while preserving string literals and line
/// positions, keeping source-ban diagnostics useful without matching examples
/// mentioned in comments.
String _withoutComments(String source) {
  final result = StringBuffer();
  var index = 0;
  var state = _LexState.code;
  while (index < source.length) {
    final char = source[index];
    final next = index + 1 < source.length ? source[index + 1] : '';
    switch (state) {
      case _LexState.code:
        if (char == '/' && next == '/') {
          result.write('  ');
          index += 2;
          state = _LexState.lineComment;
        } else if (char == '/' && next == '*') {
          result.write('  ');
          index += 2;
          state = _LexState.blockComment;
        } else if (char == "'") {
          result.write(char);
          index++;
          state = _LexState.singleQuote;
        } else if (char == '"') {
          result.write(char);
          index++;
          state = _LexState.doubleQuote;
        } else {
          result.write(char);
          index++;
        }
      case _LexState.lineComment:
        if (char == '\n') {
          result.write('\n');
          state = _LexState.code;
        } else {
          result.write(' ');
        }
        index++;
      case _LexState.blockComment:
        if (char == '*' && next == '/') {
          result.write('  ');
          index += 2;
          state = _LexState.code;
        } else {
          result.write(char == '\n' ? '\n' : ' ');
          index++;
        }
      case _LexState.singleQuote:
        result.write(char);
        index++;
        if (char == '\\' && index < source.length) {
          result.write(source[index]);
          index++;
        } else if (char == "'") {
          state = _LexState.code;
        }
      case _LexState.doubleQuote:
        result.write(char);
        index++;
        if (char == '\\' && index < source.length) {
          result.write(source[index]);
          index++;
        } else if (char == '"') {
          state = _LexState.code;
        }
    }
  }
  return result.toString();
}

bool _isSourceFile(String path) =>
    _sourceExtensions.contains(_extension(path).toLowerCase());

bool _isTestFile(String path) {
  final name = _basename(path).toLowerCase();
  return name.endsWith('_test.dart') ||
      name.endsWith('_test.go') ||
      name.endsWith('.test.ts') ||
      name.endsWith('.test.tsx') ||
      name.endsWith('.spec.ts') ||
      name.endsWith('.spec.tsx');
}

bool _isGeneratedPath(String path) =>
    path.split(Platform.pathSeparator).contains('generated');

String _relativePath(Directory root, String path) => path.substring(
  root.path.length + (root.path.endsWith(Platform.pathSeparator) ? 0 : 1),
);

String _basename(String path) => path.split(Platform.pathSeparator).last;

String _extension(String path) {
  final name = _basename(path);
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot);
}

int _lineNumber(String source, int offsetOrLiteral) {
  var line = 1;
  for (
    var index = 0;
    index < offsetOrLiteral && index < source.length;
    index++
  ) {
    if (source.codeUnitAt(index) == 10) line++;
  }
  return line;
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

enum _LexState { code, lineComment, blockComment, singleQuote, doubleQuote }

class _ContractNames {
  const _ContractNames(this.eventNames, this.errorCodes);

  final Set<String> eventNames;
  final Set<String> errorCodes;
}

class _StringLiteral {
  const _StringLiteral(this.value, this.offset);

  final String value;
  final int offset;
}
