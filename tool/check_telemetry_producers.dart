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
  'packages/core/app_core/lib/src',
  'front/src',
  'relay/internal/telemetry',
];

const Set<String> _sourceExtensions = <String>{
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

  for (final relativeRoot in _producerRoots) {
    final root = Directory('${repoRoot.path}/$relativeRoot');
    if (!root.existsSync()) continue;
    final entities = root.listSync(recursive: true, followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entity in entities) {
      if (entity is! File || !_isSourceFile(entity.path)) continue;
      if (_isTestFile(entity.path)) continue;
      final relativePath = _relativePath(repoRoot, entity.path);
      final source = entity.readAsStringSync();
      if (_isVerifiedGeneratedArtifact(
        relativePath,
        source,
        generatedSources,
      )) {
        continue;
      }
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
  final expected = expectedSources[_canonicalRelativePath(relativePath)];
  return expected != null &&
      source.startsWith(generatedHeader) &&
      source == expected;
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
  final literals = <_StringLiteral>[];
  var index = 0;
  while (index < source.length) {
    final quote = source[index];
    if (quote != "'" && quote != '"' && quote != '`') {
      index++;
      continue;
    }

    final offset = index;
    index++;
    final raw = StringBuffer();
    var closed = false;
    while (index < source.length) {
      final char = source[index];
      if (char == '\\' && index + 1 < source.length) {
        raw
          ..write(char)
          ..write(source[index + 1]);
        index += 2;
        continue;
      }
      if (char == quote) {
        index++;
        closed = true;
        break;
      }
      raw.write(char);
      index++;
    }
    if (!closed) continue;

    final value = quote == '`'
        ? _decodeTemplate(raw.toString())
        : _decodeEscapes(raw.toString());
    if (value != null) {
      literals.add(_StringLiteral(value, offset, index));
    }
  }

  yield* literals;
  for (
    var literalIndex = 0;
    literalIndex + 1 < literals.length;
    literalIndex++
  ) {
    final first = literals[literalIndex];
    var value = first.value;
    var end = first.end;
    for (
      var nextIndex = literalIndex + 1;
      nextIndex < literals.length;
      nextIndex++
    ) {
      final next = literals[nextIndex];
      if (!_isLiteralConcatenation(source.substring(end, next.offset))) {
        break;
      }
      value += next.value;
      end = next.end;
      yield _StringLiteral(value, first.offset, end);
    }
  }
}

bool _isLiteralConcatenation(String between) =>
    RegExp(r'^\s*[()]*\s*\+\s*[()]*\s*$').hasMatch(between);

String? _decodeTemplate(String raw) {
  final result = StringBuffer();
  var index = 0;
  while (index < raw.length) {
    if (raw[index] == '\\' && index + 1 < raw.length) {
      final escape = _decodeEscape(raw, index + 1);
      if (escape == null) return null;
      result.write(escape.value);
      index = escape.nextIndex;
      continue;
    }
    if (raw[index] == '\$' && index + 1 < raw.length && raw[index + 1] == '{') {
      final expressionStart = index + 2;
      final expressionEnd = _findTemplateExpressionEnd(raw, expressionStart);
      if (expressionEnd < 0) return null;
      final expression = raw.substring(expressionStart, expressionEnd).trim();
      final value = _decodeStaticExpression(expression);
      if (value == null) return null;
      result.write(value);
      index = expressionEnd + 1;
      continue;
    }
    result.write(raw[index]);
    index++;
  }
  return result.toString();
}

int _findTemplateExpressionEnd(String source, int expressionStart) {
  var depth = 1;
  String? quote;
  for (var index = expressionStart; index < source.length; index++) {
    final char = source[index];
    if (quote != null) {
      if (char == '\\') {
        index++;
      } else if (char == quote) {
        quote = null;
      }
      continue;
    }
    if (char == "'" || char == '"' || char == '`') {
      quote = char;
    } else if (char == '{') {
      depth++;
    } else if (char == '}' && --depth == 0) {
      return index;
    }
  }
  return -1;
}

String? _decodeStaticExpression(String expression) {
  var source = expression.trim();
  while (_hasWrappingParentheses(source)) {
    source = source.substring(1, source.length - 1).trim();
  }
  if (source.isEmpty) return null;

  final result = StringBuffer();
  var index = 0;
  var expectsLiteral = true;
  while (index < source.length) {
    while (index < source.length && source[index].trim().isEmpty) index++;
    if (index >= source.length) break;
    if (!expectsLiteral) {
      if (source[index] != '+') return null;
      index++;
      expectsLiteral = true;
      continue;
    }

    final quote = source[index];
    if (quote != "'" && quote != '"') return null;
    index++;
    final raw = StringBuffer();
    var closed = false;
    while (index < source.length) {
      final char = source[index];
      if (char == '\\' && index + 1 < source.length) {
        raw
          ..write(char)
          ..write(source[index + 1]);
        index += 2;
        continue;
      }
      if (char == quote) {
        index++;
        closed = true;
        break;
      }
      raw.write(char);
      index++;
    }
    if (!closed) return null;
    final value = _decodeEscapes(raw.toString());
    if (value == null) return null;
    result.write(value);
    expectsLiteral = false;
  }
  return expectsLiteral ? null : result.toString();
}

bool _hasWrappingParentheses(String source) {
  if (source.length < 2 ||
      source[0] != '(' ||
      source[source.length - 1] != ')') {
    return false;
  }
  var depth = 0;
  String? quote;
  for (var index = 0; index < source.length; index++) {
    final char = source[index];
    if (quote != null) {
      if (char == '\\') {
        index++;
      } else if (char == quote) {
        quote = null;
      }
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
    } else if (char == '(') {
      depth++;
    } else if (char == ')' && --depth == 0 && index != source.length - 1) {
      return false;
    }
  }
  return depth == 0 && quote == null;
}

String? _decodeEscapes(String raw) {
  final result = StringBuffer();
  var index = 0;
  while (index < raw.length) {
    if (raw[index] != '\\') {
      result.write(raw[index]);
      index++;
      continue;
    }
    if (index + 1 >= raw.length) return null;
    final escape = _decodeEscape(raw, index + 1);
    if (escape == null) return null;
    result.write(escape.value);
    index = escape.nextIndex;
  }
  return result.toString();
}

_DecodedEscape? _decodeEscape(String source, int escapeIndex) {
  final marker = source[escapeIndex];
  switch (marker) {
    case 'n':
      return _DecodedEscape('\n', escapeIndex + 1);
    case 'r':
      return _DecodedEscape('\r', escapeIndex + 1);
    case 't':
      return _DecodedEscape('\t', escapeIndex + 1);
    case 'b':
      return _DecodedEscape('\b', escapeIndex + 1);
    case 'f':
      return _DecodedEscape('\f', escapeIndex + 1);
    case 'v':
      return _DecodedEscape('\v', escapeIndex + 1);
    case '0':
      return _DecodedEscape('\u0000', escapeIndex + 1);
    case '\\':
      return _DecodedEscape('\\', escapeIndex + 1);
    case "'":
      return _DecodedEscape("'", escapeIndex + 1);
    case '"':
      return _DecodedEscape('"', escapeIndex + 1);
    case '`':
      return _DecodedEscape('`', escapeIndex + 1);
    case 'x':
      return _decodeHexEscape(source, escapeIndex, 2);
    case 'u':
      if (escapeIndex + 1 < source.length && source[escapeIndex + 1] == '{') {
        final close = source.indexOf('}', escapeIndex + 2);
        if (close < 0) return null;
        final hex = source.substring(escapeIndex + 2, close);
        final codePoint = int.tryParse(hex, radix: 16);
        if (codePoint == null || codePoint > 0x10ffff) return null;
        return _DecodedEscape(String.fromCharCode(codePoint), close + 1);
      }
      return _decodeHexEscape(source, escapeIndex, 4);
    default:
      // JavaScript/TypeScript treat an unknown escape as the escaped
      // character; accepting it here keeps the checker useful for escaped
      // contract names without interpreting arbitrary source expressions.
      return _DecodedEscape(marker, escapeIndex + 1);
  }
}

_DecodedEscape? _decodeHexEscape(String source, int escapeIndex, int length) {
  final end = escapeIndex + 1 + length;
  if (end > source.length) return null;
  final hex = source.substring(escapeIndex + 1, end);
  final codePoint = int.tryParse(hex, radix: 16);
  if (codePoint == null) return null;
  return _DecodedEscape(String.fromCharCode(codePoint), end);
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
        } else if (char == '`') {
          result.write(char);
          index++;
          state = _LexState.backtick;
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
      case _LexState.backtick:
        result.write(char);
        index++;
        if (char == '\\' && index < source.length) {
          result.write(source[index]);
          index++;
        } else if (char == '`') {
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

enum _LexState {
  code,
  lineComment,
  blockComment,
  singleQuote,
  doubleQuote,
  backtick,
}

class _ContractNames {
  const _ContractNames(this.eventNames, this.errorCodes);

  final Set<String> eventNames;
  final Set<String> errorCodes;
}

class _StringLiteral {
  const _StringLiteral(this.value, this.offset, this.end);

  final String value;
  final int offset;
  final int end;
}

class _DecodedEscape {
  const _DecodedEscape(this.value, this.nextIndex);

  final String value;
  final int nextIndex;
}
