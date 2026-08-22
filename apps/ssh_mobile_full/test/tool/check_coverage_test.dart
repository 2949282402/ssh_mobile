import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_coverage.dart';

void main() {
  test('summarizeLcov excludes generated and third-party sources', () {
    final summary = summarizeLcov(const [
      'SF:lib/services/example.dart',
      'DA:1,1',
      'DA:2,0',
      'LF:999',
      'LH:999',
      'end_of_record',
      r'SF:lib\services\app_log_database.g.dart',
      'DA:3,1',
      'end_of_record',
      'SF:third_party/example.dart',
      'DA:4,1',
      'end_of_record',
      'SF:lib/third_party/another.dart',
      'DA:5,1',
      'end_of_record',
    ]);

    expect(summary.linesFound, 2);
    expect(summary.linesHit, 1);
    expect(summary.percentage, 50);
  });

  test('deduplicates the same source lines across shards and unions hits', () {
    final summary = summarizeLcovFiles([
      const ['SF:lib/foo.dart', 'DA:10,1', 'DA:11,0', 'end_of_record'],
      const ['SF:lib/foo.dart', 'DA:10,0', 'DA:11,1', 'end_of_record'],
    ]);

    expect(summary.linesFound, 2);
    expect(summary.linesHit, 2);
    expect(summary.percentage, 100);
  });

  test('deduplicates partially overlapping source line sets', () {
    final summary = summarizeLcovFiles([
      const ['SF:lib/foo.dart', 'DA:10,1', 'DA:11,1', 'end_of_record'],
      const ['SF:lib/foo.dart', 'DA:11,0', 'DA:12,1', 'end_of_record'],
    ]);

    expect(summary.linesFound, 3);
    expect(summary.linesHit, 3);
  });

  test('counts a line hit in both shards only once', () {
    final summary = summarizeLcovFiles([
      const ['SF:lib/foo.dart', 'DA:10,1', 'end_of_record'],
      const ['SF:lib/foo.dart', 'DA:10,1', 'end_of_record'],
    ]);

    expect(summary.linesFound, 1);
    expect(summary.linesHit, 1);
  });

  test('keeps equal line numbers in different sources distinct', () {
    final summary = summarizeLcovFiles([
      const ['SF:lib/foo.dart', 'DA:10,1', 'end_of_record'],
      const ['SF:lib/bar.dart', 'DA:10,1', 'end_of_record'],
    ]);

    expect(summary.linesFound, 2);
    expect(summary.linesHit, 2);
  });

  test('can scope coverage to an owner path and reports missed lines', () {
    final summary = summarizeLcov(
      const [
        'SF:/workspace/apps/ssh_mobile_full/lib/services/network/foo.dart',
        'DA:10,1',
        'DA:11,0',
        'end_of_record',
        'SF:lib/features/other.dart',
        'DA:20,0',
        'end_of_record',
      ],
      includePrefixes: const ['lib/services/network/'],
    );

    expect(summary.linesFound, 2);
    expect(summary.linesHit, 1);
    expect(
      summary.uncoveredLinesBySource,
      containsPair(
        '/workspace/apps/ssh_mobile_full/lib/services/network/foo.dart',
        [11],
      ),
    );
    expect(
      summary.uncoveredLinesBySource,
      isNot(contains('lib/features/other.dart')),
    );
  });
}
