import 'dart:collection';

/// Character-bounded FIFO for terminal output under history/render backpressure.
///
/// Oversized chunks retain their newest tail, and every trim boundary preserves
/// UTF-16 surrogate pairs so buffering cannot manufacture malformed text.
final class TerminalTextBuffer {
  TerminalTextBuffer({required this.maxChars}) : assert(maxChars > 0);

  final int maxChars;
  final ListQueue<String> _chunks = ListQueue<String>();
  int _charCount = 0;

  int get charCount => _charCount;
  bool get isEmpty => _chunks.isEmpty;
  bool get isNotEmpty => _chunks.isNotEmpty;

  void add(String value) {
    if (value.isEmpty) return;
    if (value.length >= maxChars) {
      clear();
      var start = value.length - maxChars;
      if (start > 0 &&
          start < value.length &&
          _isLowSurrogate(value.codeUnitAt(start)) &&
          _isHighSurrogate(value.codeUnitAt(start - 1))) {
        start++;
      }
      final tail = value.substring(start);
      _chunks.add(tail);
      _charCount = tail.length;
      return;
    }

    _chunks.add(value);
    _charCount += value.length;
    var overflow = _charCount - maxChars;
    while (overflow > 0 && _chunks.isNotEmpty) {
      final first = _chunks.removeFirst();
      if (first.length <= overflow) {
        _charCount -= first.length;
        overflow -= first.length;
        continue;
      }
      var start = overflow;
      if (start < first.length &&
          _isLowSurrogate(first.codeUnitAt(start)) &&
          _isHighSurrogate(first.codeUnitAt(start - 1))) {
        start++;
      }
      final remaining = first.substring(start);
      _chunks.addFirst(remaining);
      _charCount -= start;
      overflow = 0;
    }
  }

  String takeAll() {
    if (_chunks.isEmpty) return '';
    final value = _chunks.join();
    clear();
    return value;
  }

  String takeUpTo(int maxLength) {
    if (maxLength <= 0 || _chunks.isEmpty) return '';
    final output = StringBuffer();
    var remaining = maxLength;
    while (_chunks.isNotEmpty && remaining > 0) {
      final first = _chunks.removeFirst();
      if (first.length <= remaining) {
        output.write(first);
        remaining -= first.length;
        _charCount -= first.length;
        continue;
      }
      var end = remaining;
      if (end < first.length &&
          _isHighSurrogate(first.codeUnitAt(end - 1)) &&
          _isLowSurrogate(first.codeUnitAt(end))) {
        end--;
      }
      if (end == 0) {
        _chunks.addFirst(first);
        break;
      }
      output.write(first.substring(0, end));
      _chunks.addFirst(first.substring(end));
      _charCount -= end;
      remaining -= end;
    }
    return output.toString();
  }

  void clear() {
    _chunks.clear();
    _charCount = 0;
  }

  static bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

  static bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;
}
