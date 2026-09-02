import 'dart:io';

import 'file_size_exemptions.dart';

/// Step31 的文件尺寸治理阈值。
///
/// 300 行以上需要人工复核职责，400 行以上需要检查是否可以按职责拆分，
/// 500 行以上必须按功能/职责边界拆分。已有文件只能通过带 owner、reason、
/// review date 和 expiry 的临时豁免继续通过；禁止用 part_01/file_01 等编号
/// 切片或无意义过度拆分。
const fileSizeReviewThreshold = 300;
const fileSizeSplitThreshold = 400;
const fileSizeCriticalThreshold = 500;

/// 单个 Dart 文件的相对路径和有效行数。
final class DartFileSize {
  const DartFileSize({required this.path, required this.lineCount});

  /// 相对于 workspace 根目录的路径，便于报告直接定位文件。
  final String path;

  /// 使用 `readAsLinesSync()` 统计的源文件行数。
  final int lineCount;
}

/// workspace 非 generated Dart 文件的尺寸报告。
final class DartFileSizeReport {
  const DartFileSizeReport(
    this.files, {
    this.testRootViolations = const <String>[],
    this.numberedSplitViolations = const <String>[],
    this.criticalViolations = const <DartFileSize>[],
    this.expiredExemptions = const <String>[],
    this.invalidExemptions = const <String>[],
  });

  /// 已按相对路径排序的文件记录。
  final List<DartFileSize> files;

  /// 返回超过指定阈值的文件，并保持稳定的路径顺序。
  List<DartFileSize> above(int threshold) =>
      files.where((file) => file.lineCount > threshold).toList(growable: false);

  /// Dart 测试文件不在 package/app 专属 test/tests 根下的路径。
  final List<String> testRootViolations;

  /// Dart source paths using mechanically numbered part/file chunks.
  final List<String> numberedSplitViolations;

  /// Production files above the critical threshold without a valid exemption.
  final List<DartFileSize> criticalViolations;

  /// Oversized files whose time-boxed exemption has expired.
  final List<String> expiredExemptions;

  /// Oversized files with malformed or incomplete exemption metadata.
  final List<String> invalidExemptions;
}

/// 扫描代码、工具和测试目录，收集所有非 generated Dart 文件的行数。
///
/// 只扫描仓库中有明确源码职责的目录，避免把 Flutter 缓存、构建产物和
/// vendored 第三方代码混入治理结果。调用方可以传入临时目录以便测试扫描规则。
DartFileSizeReport collectDartFileSizeReport({
  required Directory repositoryRoot,
}) {
  final root = repositoryRoot.absolute;
  final files = <DartFileSize>[];
  final testRootViolations = <String>[];
  final numberedSplitViolations = <String>[];
  for (final relativeRoot in _scanRoots) {
    final directory = Directory(_join(root.path, relativeRoot));
    if (!directory.existsSync()) continue;
    for (final file in _findDartFiles(directory)) {
      final relativePath = _relativePath(root.path, file.path);
      if (_isDartTestFile(file.path) && !_hasDedicatedTestRoot(relativePath)) {
        testRootViolations.add(relativePath);
      }
      if (_isNumberedSplitPath(relativePath)) {
        numberedSplitViolations.add(relativePath);
      }
      files.add(
        DartFileSize(
          path: relativePath,
          lineCount: file.readAsLinesSync().length,
        ),
      );
    }
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  testRootViolations.sort();
  numberedSplitViolations.sort();
  final criticalViolations = <DartFileSize>[];
  final expiredExemptions = <String>[];
  final invalidExemptions = <String>[];
  for (final file in files) {
    if (file.lineCount <= fileSizeCriticalThreshold || _isTestPath(file.path)) {
      continue;
    }
    final exemption = fileSizeExemptions[file.path];
    if (exemption == null) {
      criticalViolations.add(file);
      continue;
    }
    if (!_hasValidExemptionMetadata(exemption)) {
      invalidExemptions.add(file.path);
      continue;
    }
    if (_isExemptionExpired(exemption)) {
      expiredExemptions.add(file.path);
    }
  }
  return DartFileSizeReport(
    List<DartFileSize>.unmodifiable(files),
    testRootViolations: List<String>.unmodifiable(testRootViolations),
    numberedSplitViolations: List<String>.unmodifiable(numberedSplitViolations),
    criticalViolations: List<DartFileSize>.unmodifiable(criticalViolations),
    expiredExemptions: List<String>.unmodifiable(expiredExemptions),
    invalidExemptions: List<String>.unmodifiable(invalidExemptions),
  );
}

/// 将三个治理档位写入标准输出，供本地检查和 CI 日志使用。
void writeDartFileSizeReport(DartFileSizeReport report, {IOSink? output}) {
  final sink = output ?? stdout;
  sink.writeln('Dart file size report: ${report.files.length} file(s).');
  sink.writeln(
    'Files over $fileSizeCriticalThreshold lines require functional/responsibility '
    'decomposition; numbered chunks are prohibited.',
  );
  _writeBucket(
    sink,
    '> $fileSizeReviewThreshold',
    report.above(fileSizeReviewThreshold),
  );
  _writeBucket(
    sink,
    '> $fileSizeSplitThreshold',
    report.above(fileSizeSplitThreshold),
  );
  _writeBucket(
    sink,
    '> $fileSizeCriticalThreshold',
    report.above(fileSizeCriticalThreshold),
  );
  sink.writeln(
    'Dart test-root violations: ${report.testRootViolations.length}',
  );
  for (final path in report.testRootViolations) {
    sink.writeln('  $path: move under a dedicated test/ or tests/ root');
  }
  sink.writeln(
    'Numbered split violations: ${report.numberedSplitViolations.length}',
  );
  for (final path in report.numberedSplitViolations) {
    sink.writeln('  $path: split by responsibility, not a numbered chunk');
  }
  sink.writeln(
    'Critical production size violations: ${report.criticalViolations.length}',
  );
  for (final file in report.criticalViolations) {
    sink.writeln(
      '  ${file.path}: ${file.lineCount} (add a time-boxed exemption or split)',
    );
  }
  sink.writeln('Expired size exemptions: ${report.expiredExemptions.length}');
  for (final path in report.expiredExemptions) {
    sink.writeln('  $path: renew with review evidence or split');
  }
  sink.writeln('Invalid size exemptions: ${report.invalidExemptions.length}');
  for (final path in report.invalidExemptions) {
    sink.writeln('  $path: owner/reason/reviewedOn/expiresOn are required');
  }
}

void _writeBucket(IOSink sink, String label, List<DartFileSize> files) {
  sink.writeln('$label: ${files.length}');
  for (final file in files) {
    sink.writeln('  ${file.path}: ${file.lineCount}');
  }
}

Iterable<File> _findDartFiles(Directory directory) sync* {
  for (final entity in directory.listSync(followLinks: false)) {
    if (entity is Directory) {
      if (_ignoredDirectory(entity)) continue;
      yield* _findDartFiles(entity);
    } else if (entity is File &&
        entity.path.toLowerCase().endsWith('.dart') &&
        !_isGenerated(entity.path) &&
        !_isGovernanceConfig(entity.path)) {
      yield entity;
    }
  }
}

bool _ignoredDirectory(Directory directory) {
  final name = _basename(directory.path).toLowerCase();
  return name.startsWith('.') ||
      name == 'build' ||
      name == 'coverage' ||
      name == 'node_modules' ||
      name == 'third_party';
}

bool _isGenerated(String path) {
  final lowerPath = path.toLowerCase();
  return _generatedSuffixes.any(lowerPath.endsWith);
}

bool _isGovernanceConfig(String path) {
  final normalized = path.replaceAll('\\', '/').toLowerCase();
  return normalized.endsWith('/tool/file_size_exemptions.dart');
}

bool _isDartTestFile(String path) => path.toLowerCase().endsWith('_test.dart');

bool _hasDedicatedTestRoot(String relativePath) {
  final segments = relativePath.replaceAll('\\', '/').split('/');
  for (var index = 0; index < segments.length - 1; index++) {
    if (segments[index] != 'test' && segments[index] != 'tests') continue;
    if (index == 0) return true;
    final parent = segments[index - 1].toLowerCase();
    if (parent != 'lib' && parent != 'src') return true;
  }
  return false;
}

bool _isTestPath(String relativePath) {
  final segments = relativePath.replaceAll('\\', '/').split('/');
  return segments.any((segment) => segment == 'test' || segment == 'tests');
}

bool _hasValidExemptionMetadata(FileSizeExemption exemption) {
  return exemption.owner.trim().isNotEmpty &&
      exemption.reason.trim().isNotEmpty &&
      DateTime.tryParse(exemption.reviewedOn) != null &&
      DateTime.tryParse(exemption.expiresOn) != null;
}

bool _isExemptionExpired(FileSizeExemption exemption) {
  final expiry = DateTime.tryParse('${exemption.expiresOn}T23:59:59Z');
  return expiry == null || expiry.isBefore(DateTime.now().toUtc());
}

bool _isNumberedSplitPath(String relativePath) {
  final fileName = relativePath.replaceAll('\\', '/').split('/').last;
  return RegExp(
    r'^(?:part|file)[_-][0-9]+(?:[_-].*)?\.[^.]+$',
    caseSensitive: false,
  ).hasMatch(fileName);
}

String _relativePath(String root, String path) {
  final normalisedRoot = _normalise(root);
  final normalisedPath = _normalise(path);
  return normalisedPath.startsWith('$normalisedRoot/')
      ? normalisedPath.substring(normalisedRoot.length + 1)
      : normalisedPath;
}

String _join(String parent, String child) =>
    '$parent${Platform.pathSeparator}$child';

String _basename(String path) => path.split(RegExp(r'[\\/]')).last;

String _normalise(String path) => path.replaceAll('\\', '/').toLowerCase();

const _scanRoots = <String>['apps', 'packages', 'tool', 'test'];
const _generatedSuffixes = <String>[
  '.g.dart',
  '.freezed.dart',
  '.generated.dart',
];

void main() {
  final report = collectDartFileSizeReport(repositoryRoot: Directory.current);
  writeDartFileSizeReport(report);
  if (report.testRootViolations.isNotEmpty ||
      report.numberedSplitViolations.isNotEmpty ||
      report.criticalViolations.isNotEmpty ||
      report.expiredExemptions.isNotEmpty ||
      report.invalidExemptions.isNotEmpty) {
    exitCode = 1;
  }
}
