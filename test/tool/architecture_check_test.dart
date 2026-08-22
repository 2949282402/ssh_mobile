import 'dart:io';

import '../../tool/architecture_check.dart';
import '../../tool/compatibility_check.dart';
import '../../tool/compatibility_inventory.dart';
import '../../tool/duplicate_implementation_check.dart';

/// 架构守卫的无外部依赖回归测试；使用断言避免为根 workspace 引入第二套
/// 测试框架，CI 通过 `dart run test/tool/architecture_check_test.dart` 执行。
void main() {
  _testCurrentRepositoryPasses();
  _testForbiddenBoundariesAreReported();
  _testCompatibilityBudgetIsReported();
  _testClosedCompatibilityModuleIsReported();
  _testClosedAppShellAdapterTestIsAllowed();
  _testClosedDuplicateImplementationIsReported();
  stdout.writeln('Architecture checker tests passed.');
}

void _testCompatibilityBudgetIsReported() {
  final root = Directory.systemTemp.createTempSync('ssh_mobile_compatibility_');
  try {
    _write(
      root,
      'apps/ssh_mobile_full/lib/legacy.dart',
      "import 'package:ssh_mobile/features/terminal/views/terminal_screen.dart';\n",
    );
    final module = CompatibilityModule(
      id: 'terminal',
      packageName: 'feature_terminal',
      state: CompatibilityModuleState.migrating,
      legacyImportPrefixes: const <String>[
        'package:ssh_mobile/features/terminal/',
      ],
      packageSourceRoot: 'packages/features/feature_terminal/lib',
      legacySourceRoots: const <String>[],
      baselineReferenceCount: 0,
      baselineSourceCount: 0,
      appShellAdapters: const <String>[],
      removalCondition: 'test',
    );
    final report = CompatibilityAuditor(
      repositoryRoot: root,
      inventory: <CompatibilityModule>[module],
    ).audit();
    _expect(
      report.violations.any((item) => item.rule == 'legacy-import-budget'),
      '新增旧引用必须触发预算门禁',
    );
  } finally {
    root.deleteSync(recursive: true);
  }
}

void _testClosedCompatibilityModuleIsReported() {
  final root = Directory.systemTemp.createTempSync('ssh_mobile_compatibility_');
  try {
    _write(
      root,
      'apps/ssh_mobile_full/lib/legacy.dart',
      "export 'package:ssh_mobile/features/mcp_console/mcp_console_screen.dart';\n",
    );
    final module = CompatibilityModule(
      id: 'mcp',
      packageName: 'feature_mcp',
      state: CompatibilityModuleState.closed,
      legacyImportPrefixes: const <String>[
        'package:ssh_mobile/features/mcp_console/',
      ],
      packageSourceRoot: 'packages/features/feature_mcp/lib',
      legacySourceRoots: const <String>[],
      baselineReferenceCount: 0,
      baselineSourceCount: 0,
      appShellAdapters: const <String>[],
      removalCondition: 'test',
    );
    final report = CompatibilityAuditor(
      repositoryRoot: root,
      inventory: <CompatibilityModule>[module],
    ).audit();
    _expect(
      report.violations.any((item) => item.rule == 'legacy-import-closed'),
      '已关闭模块必须拒绝旧引用',
    );
  } finally {
    root.deleteSync(recursive: true);
  }
}

void _testClosedDuplicateImplementationIsReported() {
  final root = Directory.systemTemp.createTempSync('ssh_mobile_duplicate_');
  try {
    const content = 'class DuplicateImplementation {}\n';
    _write(root, 'apps/ssh_mobile_full/lib/features/demo/demo.dart', content);
    _write(root, 'packages/features/feature_demo/lib/demo.dart', content);
    final module = CompatibilityModule(
      id: 'demo',
      packageName: 'feature_demo',
      state: CompatibilityModuleState.closed,
      legacyImportPrefixes: const <String>[],
      packageSourceRoot: 'packages/features/feature_demo/lib',
      legacySourceRoots: const <String>[
        'apps/ssh_mobile_full/lib/features/demo',
      ],
      baselineReferenceCount: 0,
      baselineSourceCount: 0,
      appShellAdapters: const <String>[],
      removalCondition: 'test',
    );
    final report = DuplicateImplementationAuditor(
      repositoryRoot: root,
      inventory: <CompatibilityModule>[module],
    ).audit();
    _expect(report.exactMatches.length == 1, '应识别完全相同的旧/新实现');
    _expect(
      report.violations.any((item) => item.rule == 'legacy-source-closed'),
      '已关闭模块不得保留旧 Feature 源码',
    );
  } finally {
    root.deleteSync(recursive: true);
  }
}

void _testClosedAppShellAdapterTestIsAllowed() {
  final root = Directory.systemTemp.createTempSync('ssh_mobile_compatibility_');
  try {
    _write(
      root,
      'apps/ssh_mobile_full/test/services/network/network_service_test.dart',
      "import 'package:ssh_mobile/services/network/network_service.dart';\n",
    );
    final module = CompatibilityModule(
      id: 'network',
      packageName: 'network_transport / network_sdk',
      state: CompatibilityModuleState.closed,
      legacyImportPrefixes: const <String>[
        'package:ssh_mobile/services/network/',
      ],
      packageSourceRoot: 'packages/infrastructure/network_transport/lib',
      legacySourceRoots: const <String>[],
      baselineReferenceCount: 0,
      baselineSourceCount: 0,
      appShellAdapters: const <String>[
        'apps/ssh_mobile_full/lib/services/network/network_service.dart',
      ],
      removalCondition: 'test',
    );
    final report = CompatibilityAuditor(
      repositoryRoot: root,
      inventory: <CompatibilityModule>[module],
    ).audit();
    _expect(
      report.violations.isEmpty,
      'App Shell adapter 的专属测试应允许直接覆盖 adapter 行为',
    );
  } finally {
    root.deleteSync(recursive: true);
  }
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
