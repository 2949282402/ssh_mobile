import 'dart:io';

import '../../tool/architecture_check.dart';

/// 架构守卫的无外部依赖回归测试；使用断言避免为根 workspace 引入第二套
/// 测试框架，CI 通过 `dart run test/tool/architecture_check_test.dart` 执行。
void main() {
  _testCurrentRepositoryPasses();
  _testForbiddenBoundariesAreReported();
  stdout.writeln('Architecture checker tests passed.');
}

void _testCurrentRepositoryPasses() {
  final violations = ArchitectureChecker(
    repositoryRoot: Directory.current,
  ).check();
  _expect(violations.isEmpty, '当前 workspace 不应触发架构守卫：${violations.join('\n')}');
}

void _testForbiddenBoundariesAreReported() {
  final root = Directory.systemTemp.createTempSync('ssh_mobile_architecture_');
  try {
    _write(
      root,
      'packages/features/feature_a/pubspec.yaml',
      'name: feature_a\n',
    );
    _write(
      root,
      'packages/features/feature_b/pubspec.yaml',
      'name: feature_b\n',
    );
    _write(
      root,
      'packages/features/feature_a/lib/a.dart',
      "import 'package:feature_b/feature_b.dart';\n"
          "import 'package:feature_b/src/internal.dart';\n"
          'void create() => NetworkRuntimeImpl();\n'
          'final value = NewService.instance;\n',
    );
    _write(
      root,
      'packages/features/feature_b/lib/internal.dart',
      'class NewService {}\n',
    );

    final violations = ArchitectureChecker(repositoryRoot: root).check();
    final rules = violations.map((item) => item.rule).toSet();
    _expect(rules.contains('feature-to-feature'), '应检查 Feature 依赖边界');
    _expect(rules.contains('cross-package-src'), '应检查跨包 src 导入');
    _expect(rules.contains('feature-creates-core-impl'), '应检查 Feature 实现创建');
    _expect(rules.contains('static-service-locator'), '应检查静态 Service locator');
  } finally {
    root.deleteSync(recursive: true);
  }
}

void _write(Directory root, String relativePath, String content) {
  final file = File(
    '${root.path}${Platform.pathSeparator}${relativePath.replaceAll('/', Platform.pathSeparator)}',
  );
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}
