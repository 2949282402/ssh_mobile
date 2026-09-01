import 'dart:io';

import '../../tool/check_ui_consistency.dart';

void main() {
  _testViolationsAreDetected();
  _testInlineIgnoresAreRespected();
  _testAppUiAndGeneratedFilesAreExcluded();
  _testCleanWorkspacePasses();
  stdout.writeln('UI consistency checker tests passed.');
}

void _testViolationsAreDetected() {
  final root = Directory.systemTemp.createTempSync('ssh_mobile_ui_check_');
  try {
    _writeFile(root, 'packages/features/feature_foo/lib/bad_widget.dart', '''
import 'package:flutter/material.dart';

class BadWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        CircularProgressIndicator(strokeWidth: 2),
        AlertDialog(title: Text('Hi')),
        Padding(padding: EdgeInsets.all(13), child: Text('Test', style: TextStyle(fontSize: 18))),
      ],
    );
  }
}
''');

    final report = runUiConsistencyCheck(repositoryRoot: root);
    _expect(report.scannedFiles == 1, 'Should scan 1 file');
    _expect(report.hasViolations, 'Should detect violations');
    _expect(
      report.violations.length >= 4,
      'Should detect at least 4 violations',
    );

    final rules = report.violations.map((v) => v.rule).toSet();
    _expect(
      rules.contains('disallowed-circular-progress'),
      'Should detect circular progress',
    );
    _expect(
      rules.contains('disallowed-alert-dialog'),
      'Should detect alert dialog',
    );
    _expect(
      rules.contains('disallowed-magic-spacing'),
      'Should detect magic spacing 13',
    );
    _expect(
      rules.contains('disallowed-raw-font-size'),
      'Should detect raw font size 18',
    );
  } finally {
    root.deleteSync(recursive: true);
  }
}

void _testInlineIgnoresAreRespected() {
  final root = Directory.systemTemp.createTempSync('ssh_mobile_ui_check_');
  try {
    _writeFile(
      root,
      'packages/features/feature_foo/lib/ignored_widget.dart',
      '''
import 'package:flutter/material.dart';

class IgnoredWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ui-consistency: allow
        CircularProgressIndicator(),
        // ignore: ui_consistency
        AlertDialog(title: Text('Allowed')),
      ],
    );
  }
}
''',
    );

    final report = runUiConsistencyCheck(repositoryRoot: root);
    _expect(report.scannedFiles == 1, 'Should scan 1 file');
    _expect(
      !report.hasViolations,
      'Violations with inline ignore comments should be skipped',
    );
  } finally {
    root.deleteSync(recursive: true);
  }
}

void _testAppUiAndGeneratedFilesAreExcluded() {
  final root = Directory.systemTemp.createTempSync('ssh_mobile_ui_check_');
  try {
    // In app_ui, standard primitives like CircularProgressIndicator are allowed
    _writeFile(
      root,
      'packages/core/app_ui/lib/src/widgets/app_loading.dart',
      '''
import 'package:flutter/material.dart';
class AppLoadingIndicator extends StatelessWidget {
  Widget build(BuildContext context) => CircularProgressIndicator();
}
''',
    );

    // Generated files are excluded
    _writeFile(root, 'packages/features/feature_foo/lib/gen.g.dart', '''
import 'package:flutter/material.dart';
final x = CircularProgressIndicator();
''');

    // Test files are excluded from product consistency check
    _writeFile(root, 'packages/features/feature_foo/test/widget_test.dart', '''
import 'package:flutter/material.dart';
void main() { final x = CircularProgressIndicator(); }
''');

    final report = runUiConsistencyCheck(repositoryRoot: root);
    _expect(
      report.violations.isEmpty,
      'app_ui, generated and test files should be excluded',
    );
  } finally {
    root.deleteSync(recursive: true);
  }
}

void _testCleanWorkspacePasses() {
  final root = Directory.systemTemp.createTempSync('ssh_mobile_ui_check_');
  try {
    _writeFile(root, 'packages/features/feature_foo/lib/clean_widget.dart', '''
import 'package:app_ui/app_ui.dart';
import 'package:flutter/material.dart';

class CleanWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final typography = context.typography;
    final spacing = context.spacing;

    return AppPageSurface(
      child: Column(
        children: [
          AppLoadingIndicator(),
          Text('Title', style: typography.pageTitle),
          SizedBox(height: spacing.md),
        ],
      ),
    );
  }
}
''');

    final report = runUiConsistencyCheck(repositoryRoot: root);
    _expect(report.scannedFiles == 1, 'Should scan 1 file');
    _expect(
      !report.hasViolations,
      'Clean widget adhering to app_ui should pass',
    );
  } finally {
    root.deleteSync(recursive: true);
  }
}

void _writeFile(Directory root, String relativePath, String content) {
  final file = File(
    '${root.path}${Platform.pathSeparator}${relativePath.replaceAll('/', Platform.pathSeparator)}',
  );
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}
