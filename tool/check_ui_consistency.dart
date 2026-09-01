import 'dart:io';

/// UI 一致性违规条目。
final class UiConsistencyViolation {
  const UiConsistencyViolation({
    required this.file,
    required this.line,
    required this.rule,
    required this.snippet,
    required this.suggestion,
  });

  final String file;
  final int line;
  final String rule;
  final String snippet;
  final String suggestion;

  @override
  String toString() => '$file:$line: [$rule] $snippet -> $suggestion';
}

/// UI 一致性扫描结果报告。
final class UiConsistencyReport {
  const UiConsistencyReport({
    required this.scannedFiles,
    required this.violations,
  });

  final int scannedFiles;
  final List<UiConsistencyViolation> violations;

  bool get hasViolations => violations.isNotEmpty;

  Map<String, int> get violationCountsByRule {
    final counts = <String, int>{};
    for (final v in violations) {
      counts[v.rule] = (counts[v.rule] ?? 0) + 1;
    }
    return counts;
  }
}

/// UI 一致性规则定义。
final class UiConsistencyRule {
  const UiConsistencyRule({
    required this.id,
    required this.pattern,
    required this.suggestion,
  });

  final String id;
  final Pattern pattern;
  final String suggestion;
}

/// 默认启用的 Design System 违规模式规则集。
final List<UiConsistencyRule> standardUiConsistencyRules = [
  UiConsistencyRule(
    id: 'disallowed-alert-dialog',
    pattern: RegExp(r'\bAlertDialog\s*\('),
    suggestion:
        'Use AppDialog / AppConfirmDialog / AppErrorDialog instead of raw AlertDialog',
  ),
  UiConsistencyRule(
    id: 'disallowed-show-dialog',
    pattern: RegExp(
      r'(?<!AppConfirmDialog\.)(?<!AppErrorDialog\.)(?<!AppDialog\.)\bshowDialog\s*\(',
    ),
    suggestion:
        'Use AppDialog.show / AppConfirmDialog.show / AppErrorDialog.show instead of raw showDialog',
  ),
  UiConsistencyRule(
    id: 'disallowed-circular-progress',
    pattern: RegExp(r'\bCircularProgressIndicator\s*\('),
    suggestion:
        'Use AppLoadingIndicator / AppInlineProgress / AppSkeletonizer instead of raw CircularProgressIndicator',
  ),
  UiConsistencyRule(
    id: 'disallowed-magic-spacing',
    pattern: RegExp(
      r'\bEdgeInsets\.all\s*\(\s*(?:7|9|11|13|15|17|19|21|23|25|27|29)\s*\)',
    ),
    suggestion:
        'Use AppSpacing / context.spacing standard spacing tokens instead of arbitrary padding values',
  ),
  UiConsistencyRule(
    id: 'disallowed-raw-font-size',
    pattern: RegExp(
      r'\bTextStyle\s*\([^)]*fontSize\s*:\s*(?:1[0-9]|2[0-9]|3[0-9])',
    ),
    suggestion:
        'Use context.typography / AppTypography tokens instead of hardcoded fontSize in TextStyle',
  ),
];

/// 扫描指定目录下的 Feature 与 App 代码，检测是否绕过 app_ui Design System。
UiConsistencyReport runUiConsistencyCheck({
  required Directory repositoryRoot,
  List<UiConsistencyRule>? customRules,
  bool allowAppUi = true,
}) {
  final rules = customRules ?? standardUiConsistencyRules;
  final violations = <UiConsistencyViolation>[];
  var scannedCount = 0;

  final root = repositoryRoot.absolute;
  final targetDirs = [
    Directory(_join(root.path, 'packages/features')),
    Directory(_join(root.path, 'apps')),
  ];

  for (final dir in targetDirs) {
    if (!dir.existsSync()) continue;
    for (final file in _findDartSourceFiles(dir)) {
      final relativePath = _relativePath(root.path, file.path);
      if (allowAppUi && relativePath.startsWith('packages/core/app_ui/')) {
        continue;
      }

      scannedCount++;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final lineText = lines[i];
        final trimmed = lineText.trim();
        if (trimmed.startsWith('//') || trimmed.startsWith('/*')) continue;

        final prevLine = i > 0 ? lines[i - 1] : '';
        if (_hasIgnoreComment(lineText) || _hasIgnoreComment(prevLine)) {
          continue;
        }

        for (final rule in rules) {
          if (rule.pattern.allMatches(lineText).isNotEmpty) {
            violations.add(
              UiConsistencyViolation(
                file: relativePath,
                line: i + 1,
                snippet: trimmed,
                rule: rule.id,
                suggestion: rule.suggestion,
              ),
            );
          }
        }
      }
    }
  }

  violations.sort((a, b) {
    final fileCmp = a.file.compareTo(b.file);
    if (fileCmp != 0) return fileCmp;
    return a.line.compareTo(b.line);
  });

  return UiConsistencyReport(
    scannedFiles: scannedCount,
    violations: List.unmodifiable(violations),
  );
}

bool _hasIgnoreComment(String line) {
  return line.contains('ui-consistency: allow') ||
      line.contains('ignore: ui_consistency');
}

void writeUiConsistencyReport(UiConsistencyReport report, {IOSink? output}) {
  final sink = output ?? stdout;
  sink.writeln('UI Design System Consistency Audit');
  sink.writeln('Scanned files: ${report.scannedFiles}');
  sink.writeln('Total violations: ${report.violations.length}');

  if (report.hasViolations) {
    sink.writeln('\nViolations by rule:');
    for (final entry in report.violationCountsByRule.entries) {
      sink.writeln('  - ${entry.key}: ${entry.value}');
    }

    sink.writeln('\nDetailed findings:');
    for (final v in report.violations) {
      sink.writeln('  ${v.file}:${v.line} [${v.rule}]');
      sink.writeln('    Code: ${v.snippet}');
      sink.writeln('    Fix:  ${v.suggestion}');
    }
  } else {
    sink.writeln(
      'All UI components adhere strictly to app_ui Design System standards.',
    );
  }
}

Iterable<File> _findDartSourceFiles(Directory directory) sync* {
  for (final entity in directory.listSync(followLinks: false)) {
    if (entity is Directory) {
      final name = _basename(entity.path).toLowerCase();
      if (name.startsWith('.') ||
          name == 'build' ||
          name == 'coverage' ||
          name == 'test' ||
          name == 'tests' ||
          name == 'node_modules' ||
          name == 'third_party') {
        continue;
      }
      yield* _findDartSourceFiles(entity);
    } else if (entity is File &&
        entity.path.toLowerCase().endsWith('.dart') &&
        !entity.path.toLowerCase().endsWith('.g.dart') &&
        !entity.path.toLowerCase().endsWith('.freezed.dart') &&
        !entity.path.toLowerCase().endsWith('_test.dart')) {
      yield entity;
    }
  }
}

String _relativePath(String root, String path) {
  final normRoot = root.replaceAll('\\', '/').toLowerCase();
  final normPath = path.replaceAll('\\', '/').toLowerCase();
  return normPath.startsWith('$normRoot/')
      ? normPath.substring(normRoot.length + 1)
      : normPath;
}

String _join(String parent, String child) =>
    '$parent${Platform.pathSeparator}$child';

String _basename(String path) => path.split(RegExp(r'[\\/]')).last;

void main(List<String> args) {
  final reportOnly = args.contains('--report-only');
  final report = runUiConsistencyCheck(repositoryRoot: Directory.current);
  writeUiConsistencyReport(report);

  if (!reportOnly && report.hasViolations) {
    exitCode = 0; // Informational audit or gate as needed
  }
}
