import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_coverage.dart';

void main() {
  test('summarizeLcov excludes generated and third-party sources', () {
    final summary = summarizeLcov(const [
      'SF:lib/services/example.dart',
      'LF:20',
      'LH:10',
      'end_of_record',
      'SF:lib/data/database/example.g.dart',
      'LF:100',
      'LH:100',
      'end_of_record',
      'SF:third_party/example.dart',
      'LF:50',
      'LH:50',
      'end_of_record',
    ]);

    expect(summary.linesFound, 20);
    expect(summary.linesHit, 10);
    expect(summary.percentage, 50);
  });
}
