import 'dart:io';

import '../../tool/check_file_sizes.dart';

/// 文件尺寸报告的无外部依赖回归测试，覆盖扫描范围、generated 排除和阈值统计。
///
/// 根 workspace 使用 `dart run test/tool/file_size_report_test.dart` 执行，
/// 因此不需要为治理脚本额外引入测试框架或依赖。
void main() {
  _testGeneratedFilesAreExcludedAndPathsAreSorted();
  _testCurrentWorkspaceCanBeScanned();
  stdout.writeln('File size report tests passed.');
}

void _testGeneratedFilesAreExcludedAndPathsAreSorted() {
  final root = Directory.systemTemp.createTempSync('ssh_mobile_file_sizes_');
  try {
    _writeLines(
      root,
      'packages/demo/lib/large.dart',
      fileSizeReviewThreshold + 1,
    );
    _writeLines(root, 'packages/demo/lib/generated.g.dart', 1000);
    _writeLines(root, 'apps/demo/test/small.dart', 2);
    _writeLines(root, 'tool/ignored.freezed.dart', 1000);
    _writeLines(root, 'test/also_ignored.generated.dart', 1000);
    _writeLines(root, 'packages/demo/notes.txt', 1000);

    final report = collectDartFileSizeReport(repositoryRoot: root);
    final paths = report.files.map((file) => file.path).toList();

    _expect(paths.length == 2, '应只统计两个非 generated Dart 文件，实际为 ${paths.length}');
    _expect(paths.first == 'apps/demo/test/small.dart', '报告应按路径排序');
    _expect(paths.last == 'packages/demo/lib/large.dart', '报告应保留源码路径');
    _expect(
      report.above(fileSizeReviewThreshold).length == 1,
      '应正确统计超过复核阈值的文件',
    );
    _expect(report.above(fileSizeSplitThreshold).isEmpty, '测试文件只应超过 300 行阈值');
  } finally {
    root.deleteSync(recursive: true);
  }
}

void _testCurrentWorkspaceCanBeScanned() {
  final report = collectDartFileSizeReport(repositoryRoot: Directory.current);
  _expect(report.files.isNotEmpty, '当前 workspace 应至少包含一个 Dart 文件');
  _expect(
    report.files.every((file) => !file.path.endsWith('.g.dart')),
    '报告不得包含 generated Dart 文件',
  );
  _expect(
    report.files.every((file) => !file.path.contains('third_party')),
    '报告不得包含 vendored 第三方代码',
  );
}

void _writeLines(Directory root, String relativePath, int lineCount) {
  final file = File(
    '${root.path}${Platform.pathSeparator}${relativePath.replaceAll('/', Platform.pathSeparator)}',
  );
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    List<String>.filled(lineCount, 'void main() {}').join('\n'),
  );
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}
