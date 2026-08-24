import 'dart:io';

import 'compatibility_inventory.dart';

/// 一条旧入口引用，保留来源和行号供迁移时直接定位。
final class CompatibilityReference {
  const CompatibilityReference({
    required this.module,
    required this.path,
    required this.line,
    required this.importUri,
    required this.approvedAppShellAdapterTest,
  });

  final CompatibilityModule module;
  final String path;
  final int line;
  final String importUri;
  final bool approvedAppShellAdapterTest;

  @override
  String toString() => '${module.id}: $path:$line $importUri';
}

/// 兼容引用门禁违规。
final class CompatibilityViolation {
  const CompatibilityViolation({
    required this.rule,
    required this.module,
    required this.path,
    required this.line,
    required this.message,
  });

  final String rule;
  final String module;
  final String path;
  final int line;
  final String message;

  @override
  String toString() => '[$rule] $module $path:$line $message';
}

/// 兼容层引用审计结果。
final class CompatibilityAuditReport {
  const CompatibilityAuditReport({
    required this.references,
    required this.violations,
  });

  final List<CompatibilityReference> references;
  final List<CompatibilityViolation> violations;

  bool get isValid => violations.isEmpty;

  int referenceCountFor(CompatibilityModule module) =>
      references.where((reference) => reference.module.id == module.id).length;

  int sourceCountFor(CompatibilityModule module) => references
      .where((reference) => reference.module.id == module.id)
      .map((reference) => reference.path)
      .toSet()
      .length;

  int gatedReferenceCountFor(CompatibilityModule module) => references
      .where(
        (reference) =>
            reference.module.id == module.id &&
            !reference.approvedAppShellAdapterTest,
      )
      .length;

  int gatedSourceCountFor(CompatibilityModule module) => references
      .where(
        (reference) =>
            reference.module.id == module.id &&
            !reference.approvedAppShellAdapterTest,
      )
      .map((reference) => reference.path)
      .toSet()
      .length;

  int approvedAdapterTestReferenceCountFor(CompatibilityModule module) =>
      references
          .where(
            (reference) =>
                reference.module.id == module.id &&
                reference.approvedAppShellAdapterTest,
          )
          .length;
}

/// 扫描 Workspace 中旧 App URI，并执行“只减不增/关闭即零引用”门禁。
final class CompatibilityAuditor {
  CompatibilityAuditor({
    required this.repositoryRoot,
    this.inventory = compatibilityInventory,
  });

  final Directory repositoryRoot;
  final List<CompatibilityModule> inventory;

  CompatibilityAuditReport audit() {
    final references = <CompatibilityReference>[];
    for (final file in _findDartFiles()) {
      final lines = file.readAsLinesSync();
      for (var index = 0; index < lines.length; index++) {
        final match = _packageDirective.firstMatch(lines[index]);
        if (match == null) continue;
        final importUri = 'package:${match.group(1)}/${match.group(2)}';
        final module = _moduleForImport(importUri);
        if (module == null) continue;
        final path = _relativePath(file.path);
        references.add(
          CompatibilityReference(
            module: module,
            path: path,
            line: index + 1,
            importUri: importUri,
            approvedAppShellAdapterTest: _isApprovedAppShellAdapterTest(
              module: module,
              path: path,
              importUri: importUri,
            ),
          ),
        );
      }
    }

    final violations = <CompatibilityViolation>[];
    for (final module in inventory) {
      final moduleReferences = references
          .where(
            (reference) =>
                reference.module.id == module.id &&
                !reference.approvedAppShellAdapterTest,
          )
          .toList();
      if (module.state == CompatibilityModuleState.closed) {
        for (final reference in moduleReferences) {
          violations.add(
            CompatibilityViolation(
              rule: 'legacy-import-closed',
              module: module.id,
              path: reference.path,
              line: reference.line,
              message:
                  '模块已关闭，禁止继续导入 ${reference.importUri}；请使用 ${module.packageName} 公共入口。',
            ),
          );
        }
        continue;
      }

      if (moduleReferences.length > module.baselineReferenceCount) {
        violations.add(
          CompatibilityViolation(
            rule: 'legacy-import-budget',
            module: module.id,
            path: moduleReferences.first.path,
            line: moduleReferences.first.line,
            message:
                '旧引用 ${moduleReferences.length} 条，超过迁移基线 '
                '${module.baselineReferenceCount} 条；兼容层只能减少，不能新增。',
          ),
        );
      }

      final sourceCount = moduleReferences
          .map((item) => item.path)
          .toSet()
          .length;
      if (sourceCount > module.baselineSourceCount) {
        violations.add(
          CompatibilityViolation(
            rule: 'legacy-source-budget',
            module: module.id,
            path: moduleReferences.first.path,
            line: moduleReferences.first.line,
            message:
                '旧引用来源文件 ${sourceCount} 个，超过迁移基线 '
                '${module.baselineSourceCount} 个；请先迁移调用方。',
          ),
        );
      }
    }

    violations.sort((a, b) {
      final module = a.module.compareTo(b.module);
      if (module != 0) return module;
      final path = a.path.compareTo(b.path);
      if (path != 0) return path;
      return a.line.compareTo(b.line);
    });
    return CompatibilityAuditReport(
      references: List.unmodifiable(references),
      violations: List.unmodifiable(violations),
    );
  }

  CompatibilityModule? _moduleForImport(String importUri) {
    for (final module in inventory) {
      if (module.matches(importUri)) return module;
    }
    return null;
  }

  Iterable<File> _findDartFiles() sync* {
    for (final relativeRoot in _scanRoots) {
      final root = Directory(_join(repositoryRoot.path, relativeRoot));
      if (!root.existsSync()) continue;
      yield* _findDartFilesIn(root);
    }
  }

  Iterable<File> _findDartFilesIn(Directory directory) sync* {
    for (final entity in directory.listSync(followLinks: false)) {
      if (entity is Directory) {
        if (_ignoredDirectory(entity)) continue;
        yield* _findDartFilesIn(entity);
      } else if (entity is File && entity.path.endsWith('.dart')) {
        yield entity;
      }
    }
  }

  String _relativePath(String path) {
    final root = _normalise(repositoryRoot.absolute.path);
    final value = _normalise(path);
    return value.startsWith('$root/')
        ? value.substring(root.length + 1)
        : value;
  }

  String _join(String parent, String child) =>
      '$parent${Platform.pathSeparator}$child';

  bool _isApprovedAppShellAdapterTest({
    required CompatibilityModule module,
    required String path,
    required String importUri,
  }) {
    // App Shell adapters are compatibility owners, so their behavior tests
    // may import the adapter directly. Keep this exception narrow: only test
    // sources under apps/*/test may use a target explicitly listed in the
    // module inventory. Production callers and unlisted legacy paths remain
    // rejected by the closed-module gate.
    final segments = path.split('/');
    if (segments.length < 4 ||
        segments[0] != 'apps' ||
        segments[1].isEmpty ||
        segments[2] != 'test') {
      return false;
    }
    return module.appShellAdapters
        .map(_appShellAdapterImportUri)
        .whereType<String>()
        .contains(importUri);
  }

  String? _appShellAdapterImportUri(String path) {
    const appLibPrefix = 'apps/ssh_mobile_full/lib/';
    if (!path.startsWith(appLibPrefix)) return null;
    return 'package:ssh_mobile/${path.substring(appLibPrefix.length)}';
  }
}

const _scanRoots = <String>[
  'apps',
  'packages/core',
  'packages/features',
  'packages/infrastructure',
];

final _packageDirective = RegExp(
  r'''^\s*(?:import|export|part)\s+['"]package:([A-Za-z0-9_]+)/([^'"]*)['"]''',
);

bool _ignoredDirectory(Directory directory) {
  final name = directory.path.split(RegExp(r'[\\/]')).last;
  return name.startsWith('.') ||
      name == 'build' ||
      name == 'coverage' ||
      name == 'node_modules';
}

String _normalise(String path) => path.replaceAll('\\', '/').toLowerCase();

/// 命令行审计入口；架构检查器也会调用同一份审计逻辑。
void main() {
  final report = CompatibilityAuditor(
    repositoryRoot: Directory.current,
  ).audit();
  for (final module in compatibilityInventory) {
    stdout.writeln(
      '  ${module.id} [${module.state.name}] '
      '${report.gatedReferenceCountFor(module)} gated refs / '
      '${module.baselineReferenceCount} baseline, '
      '${report.approvedAdapterTestReferenceCountFor(module)} approved adapter-test refs, '
      '${report.gatedSourceCountFor(module)} gated source files / '
      '${module.baselineSourceCount} baseline -> ${module.packageName}',
    );
  }
  if (report.isValid) {
    stdout.writeln('Compatibility import audit passed.');
    return;
  }
  stderr.writeln(
    'Compatibility import audit failed with '
    '${report.violations.length} violation(s):',
  );
  for (final violation in report.violations) {
    stderr.writeln('  $violation');
  }
  exitCode = 1;
}
