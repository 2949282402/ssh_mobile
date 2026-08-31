/// Lexical helpers used by the telemetry producer source-ban checker.
///
/// This intentionally remains dependency-free: the contract gate runs with
/// `dart run` in a fresh checkout and must not require a parser package.
library;

/// A source string literal and its byte offsets in the comment-free source.
class StringLiteral {
  const StringLiteral(this.value, this.offset, this.end);

  final String value;
  final int offset;
  final int end;
}

/// Extracts static string literals from Dart, Go, JavaScript, and TypeScript
/// source. It handles quoted strings, template literals, escapes, and simple
/// literal concatenation while ignoring dynamic expressions.
Iterable<StringLiteral> stringLiterals(String source) sync* {
  final literals = <StringLiteral>[];
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
      literals.add(StringLiteral(value, offset, index));
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
      yield StringLiteral(value, first.offset, end);
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
      // character; accepting it keeps the checker useful for escaped
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
String withoutComments(String source) {
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

int lineNumber(String source, int offset) {
  var line = 1;
  for (var index = 0; index < offset && index < source.length; index++) {
    if (source.codeUnitAt(index) == 10) line++;
  }
  return line;
}

enum _LexState {
  code,
  lineComment,
  blockComment,
  singleQuote,
  doubleQuote,
  backtick,
}

class _DecodedEscape {
  const _DecodedEscape(this.value, this.nextIndex);

  final String value;
  final int nextIndex;
}
