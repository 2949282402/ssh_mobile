import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/ai_chat/services/plan_command_parser.dart';

void main() {
  test('parses only an exact case-insensitive plan command token', () {
    const accepted = <String, String>{
      '/plan': '',
      '/PLAN': '',
      '  /PlAn  ': '',
      '/plan inspect   nginx': 'inspect   nginx',
      '/plan\tinspect nginx': 'inspect nginx',
      '/plan\ninspect nginx': 'inspect nginx',
    };
    for (final entry in accepted.entries) {
      expect(
        parsePlanCommand(entry.key)?.arguments,
        entry.value,
        reason: entry.key,
      );
    }

    for (final input in const [
      '/planner',
      '/planet',
      '/plan-mode',
      '/planx',
      '/plan/',
      '/ plan',
      'run /plan',
    ]) {
      expect(parsePlanCommand(input), isNull, reason: input);
    }
  });
}
