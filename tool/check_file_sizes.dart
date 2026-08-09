import 'dart:io';

/// Step31 的文件尺寸治理阈值。
///
/// 300 行以上需要人工复核职责，400 行以上需要检查是否可以按职责拆分，
/// 500 行以上视为高风险文件。脚本只负责报告，不会为了通过阈值机械改写代码。
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
  const DartFileSizeReport(this.files);

  /// 已按相对路径排序的文件记录。
  final List<DartFileSize> files;

  /// 返回超过指定阈值的文件，并保持稳定的路径顺序。
  List<DartFileSize> above(int threshold) =>
      files.where((file) => file.lineCount > threshold).toList(growable: false);
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
  for (final relativeRoot in _scanRoots) {
    final directory = Directory(_join(root.path, relativeRoot));
    if (!directory.existsSync()) continue;
    for (final file in _findDartFiles(directory)) {
      files.add(
        DartFileSize(
          path: _relativePath(root.path, file.path),
          lineCount: file.readAsLinesSync().length,
        ),
      );
    }
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return DartFileSizeReport(List<DartFileSize>.unmodifiable(files));
}

/// 将三个治理档位写入标准输出，供本地检查和 CI 日志使用。
void writeDartFileSizeReport(DartFileSizeReport report, {IOSink? output}) {
  final sink = output ?? stdout;
  sink.writeln('Dart file size report: ${report.files.length} file(s).');
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
        !_isGenerated(entity.path)) {
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
}
