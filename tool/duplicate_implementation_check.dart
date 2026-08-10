import 'dart:io';

import 'compatibility_inventory.dart';

/// 一对同名且内容完全相同的旧/新实现。
final class DuplicateImplementationMatch {
  const DuplicateImplementationMatch({
    required this.module,
    required this.legacyPath,
    required this.packagePath,
  });

  final CompatibilityModule module;
  final String legacyPath;
  final String packagePath;

  @override
  String toString() => '${module.id}: $legacyPath == $packagePath';
}

/// 重复实现检查违规。
final class DuplicateImplementationViolation {
  const DuplicateImplementationViolation({
    required this.rule,
    required this.module,
    required this.path,
    required this.message,
  });

  final String rule;
  final String module;
  final String path;
  final String message;

  @override
  String toString() => '[$rule] $module $path $message';
}

/// 重复实现审计结果。
final class DuplicateImplementationAuditReport {
  const DuplicateImplementationAuditReport({
    required this.legacySources,
    required this.exactMatches,
    required this.violations,
  });

  final Map<String, List<String>> legacySources;
  final List<DuplicateImplementationMatch> exactMatches;
  final List<DuplicateImplementationViolation> violations;

  bool get isValid => violations.isEmpty;
}

/// 检查旧 App Feature 目录是否仍包含重复业务实现。
///
/// 迁移中的模块只报告旧源码和完全相同文件，便于逐步收敛；已关闭模块
/// 的旧 Feature 源码直接触发失败。App Shell adapter 和兼容协议后端不在
/// [CompatibilityModule.legacySourceRoots] 中，因此不会被误判为 Feature
/// 副本。
final class DuplicateImplementationAuditor {
  DuplicateImplementationAuditor({
    required this.repositoryRoot,
    this.inventory = compatibilityInventory,
  });

  final Directory repositoryRoot;
  final List<CompatibilityModule> inventory;

  DuplicateImplementationAuditReport audit() {
    final sources = <String, List<String>>{};
    final matches = <DuplicateImplementationMatch>[];
    final violations = <DuplicateImplementationViolation>[];

    for (final module in inventory) {
      final legacyFiles = <File>[];
      for (final relativeRoot in module.legacySourceRoots) {
        final root = Directory(_join(repositoryRoot.path, relativeRoot));
        if (!root.existsSync()) continue;
        legacyFiles.addAll(_findDartFiles(root));
      }
      // A compatibility inventory may explicitly classify a file as an App
      // Shell adapter/backend even when it lives below a legacy service root.
      // Such files are allowed to remain, but they must not hide a Feature
      // implementation in the same root.
      legacyFiles.removeWhere(
        (file) => _isAppShellAdapter(module, _relativePath(file.path)),
      );
      final legacyPaths = legacyFiles
          .map((file) => _relativePath(file.path))
          .toList(growable: false);
      sources[module.id] = List.unmodifiable(legacyPaths);

      if (module.state == CompatibilityModuleState.closed) {
        for (final path in legacyPaths) {
          violations.add(
            DuplicateImplementationViolation(
              rule: 'legacy-source-closed',
              module: module.id,
              path: path,
              message: '模块已关闭，旧 Feature 源码必须删除；仅保留 App Shell adapter 和明确的兼容后端。',
            ),
          );
        }
      }

      final packageRoot = Directory(
        _join(repositoryRoot.path, module.packageSourceRoot),
      );
      if (!packageRoot.existsSync()) continue;
      final packageFilesByName = <String, List<File>>{};
      for (final file in _findDartFiles(packageRoot)) {
        packageFilesByName
            .putIfAbsent(file.uri.pathSegments.last, () => [])
            .add(file);
      }

      for (final legacyFile in legacyFiles) {
        final name = legacyFile.uri.pathSegments.last;
        final candidates = packageFilesByName[name] ?? const <File>[];
        for (final packageFile in candidates) {
          if (!_sameBytes(legacyFile, packageFile)) continue;
          final match = DuplicateImplementationMatch(
            module: module,
            legacyPath: _relativePath(legacyFile.path),
            packagePath: _relativePath(packageFile.path),
          );
          matches.add(match);
          if (module.state == CompatibilityModuleState.closed) {
            violations.add(
              DuplicateImplementationViolation(
                rule: 'duplicate-source-closed',
                module: module.id,
                path: match.legacyPath,
                message: '旧源码与维护 Package 完全相同，必须删除旧副本 ${match.packagePath}。',
              ),
            );
          }
        }
      }
    }

    violations.sort((a, b) {
      final module = a.module.compareTo(b.module);
      if (module != 0) return module;
      return a.path.compareTo(b.path);
    });
    matches.sort((a, b) {
      final module = a.module.id.compareTo(b.module.id);
      if (module != 0) return module;
      return a.legacyPath.compareTo(b.legacyPath);
    });

    return DuplicateImplementationAuditReport(
      legacySources: Map.unmodifiable(sources),
      exactMatches: List.unmodifiable(matches),
      violations: List.unmodifiable(violations),
    );
  }

  Iterable<File> _findDartFiles(Directory directory) sync* {
    for (final entity in directory.listSync(followLinks: false)) {
      if (entity is Directory) {
        if (_ignoredDirectory(entity)) continue;
        yield* _findDartFiles(entity);
      } else if (entity is File &&
          entity.path.endsWith('.dart') &&
          !entity.path.endsWith('.g.dart') &&
          !entity.path.endsWith('.freezed.dart')) {
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

  bool _isAppShellAdapter(CompatibilityModule module, String path) {
    final normalizedPath = _normalise(path);
    return module.appShellAdapters.any(
      (adapter) => _normalise(adapter) == normalizedPath,
    );
  }
}

bool _sameBytes(File left, File right) {
  final leftBytes = left.readAsBytesSync();
  final rightBytes = right.readAsBytesSync();
  if (leftBytes.length != rightBytes.length) return false;
  for (var index = 0; index < leftBytes.length; index++) {
    if (leftBytes[index] != rightBytes[index]) return false;
  }
  return true;
}

bool _ignoredDirectory(Directory directory) {
  final name = directory.path.split(RegExp(r'[\\/]')).last;
  return name.startsWith('.') ||
      name == 'build' ||
      name == 'coverage' ||
      name == 'node_modules';
}

String _normalise(String path) => path.replaceAll('\\', '/').toLowerCase();

/// 命令行入口；架构检查器复用同一审计逻辑。
void main() {
  final report = DuplicateImplementationAuditor(
    repositoryRoot: Directory.current,
  ).audit();
  for (final module in compatibilityInventory) {
    final sources = report.legacySources[module.id] ?? const <String>[];
    final matches = report.exactMatches
        .where((match) => match.module.id == module.id)
        .length;
    stdout.writeln(
      '  ${module.id} [${module.state.name}] '
      '${sources.length} legacy source files, $matches exact duplicate(s)',
    );
  }
  if (report.exactMatches.isNotEmpty) {
    stdout.writeln('Exact duplicate implementations:');
    for (final match in report.exactMatches) {
      stdout.writeln('  $match');
    }
  }
  if (report.isValid) {
    stdout.writeln('Duplicate implementation audit passed.');
    return;
  }
  stderr.writeln(
    'Duplicate implementation audit failed with '
    '${report.violations.length} violation(s):',
  );
  for (final violation in report.violations) {
    stderr.writeln('  $violation');
  }
  exitCode = 1;
}
