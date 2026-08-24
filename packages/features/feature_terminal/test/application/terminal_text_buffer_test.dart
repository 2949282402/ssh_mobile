import 'package:flutter_test/flutter_test.dart';
import 'package:feature_terminal/src/application/terminal_text_buffer.dart';

void main() {
  test('retains the newest bounded tail across chunks', () {
    final buffer = TerminalTextBuffer(maxChars: 8);

    buffer
      ..add('abc')
      ..add('defghijk');

    expect(buffer.charCount, 8);
    expect(buffer.isNotEmpty, isTrue);
    expect(buffer.takeAll(), 'defghijk');
    expect(buffer.isEmpty, isTrue);
    expect(buffer.charCount, 0);
    expect(buffer.takeAll(), isEmpty);
  });

  test('oversized chunks and trimming preserve surrogate pairs', () {
    final buffer = TerminalTextBuffer(maxChars: 4);

    buffer.add('ab🚀cde');
    expect(buffer.takeAll(), 'cde');

    buffer
      ..add('a🚀b')
      ..add('cde');
    expect(buffer.takeAll(), 'bcde');
  });

  test('bounded reads preserve pairs and leave the remainder queued', () {
    final buffer = TerminalTextBuffer(maxChars: 20)
      ..add('a🚀bc')
      ..add('def');

    expect(buffer.takeUpTo(2), 'a');
    expect(buffer.charCount, 7);
    expect(buffer.takeUpTo(4), '🚀bc');
    expect(buffer.takeUpTo(20), 'def');
    expect(buffer.takeUpTo(0), isEmpty);
    expect(buffer.isEmpty, isTrue);
  });

  test('clear and empty input are idempotent', () {
    final buffer = TerminalTextBuffer(maxChars: 3)
      ..add('')
      ..clear()
      ..clear();

    expect(buffer.takeUpTo(1), isEmpty);
    expect(buffer.charCount, 0);
  });
}
