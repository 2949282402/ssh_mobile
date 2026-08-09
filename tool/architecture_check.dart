import 'dart:io';

/// 架构守卫的显式例外清单。
///
/// 迁移期间仍存在少量兼容实现，因此这里只允许已经审计过的公共边界和
/// 兼容单例名称。新增例外必须先完成架构评审，再修改这份清单；Feature
/// 到 Feature 的默认例外保持为空。
const architectureAllowlist = ArchitectureAllowlist(
  featureDependencies: <String, Set<String>>{
    // AI 只使用 PlaybookAutomationPort 等公共契约，不导入 Playbook/src。
    'feature_ai': <String>{'feature_playbook'},
  },
  legacyStaticServiceLocators: <String>{
    // 这些名称仍由兼容层提供，后续迁移完成后应逐步移除。
    'AppLogService.instance',
    'ClientSystemToolService.instance',
    'ClientWebViewService.instance',
    'DataProtectionService.instance',
    'NativeMemoryService.instance',
  },
);

/// 架构例外的集中描述，便于测试和审计脚本行为。
final class ArchitectureAllowlist {
  const ArchitectureAllowlist({
    this.featureDependencies = const <String, Set<String>>{},
    this.legacyStaticServiceLocators = const <String>{},
  });

  /// 允许某个 Feature 通过公共入口依赖另一个 Feature 的契约。
  final Map<String, Set<String>> featureDependencies;

  /// 迁移期间保留的已知兼容单例名称。
  final Set<String> legacyStaticServiceLocators;

  /// 判断 Feature 依赖是否经过显式批准。
  bool allowsFeatureDependency(String source, String target) =>
      featureDependencies[source]?.contains(target) ?? false;

  /// 判断静态服务定位器是否属于已记录的兼容例外。
  bool allowsStaticServiceLocator(String value) =>
      legacyStaticServiceLocators.contains(value);
}

/// 单条架构守卫违规，包含可直接定位到源文件的行号。
final class ArchitectureViolation {
  const ArchitectureViolation({
    required this.rule,
    required this.path,
    required this.line,
    required this.message,
  });

  final String rule;
  final String path;
  final int line;
  final String message;

  @override
  String toString() => '[$rule] $path:$line $message';
}

/// 扫描 workspace 源文件并执行 Plan Step 28 定义的禁止规则。
final class ArchitectureChecker {
  ArchitectureChecker({
    required this.repositoryRoot,
    this.allowlist = architectureAllowlist,
  });

  final Directory repositoryRoot;
  final ArchitectureAllowlist allowlist;

  /// 返回全部违规；调用方负责将非空结果转换为 CI 失败。
  List<ArchitectureViolation> check() {
    final packages = _discoverPackages();
    final sources = _discoverSources(packages);
    final violations = <ArchitectureViolation>[];

    for (final source in sources) {
      final lines = source.file.readAsLinesSync();
      for (var index = 0; index < lines.length; index++) {
        final line = lines[index];
        _checkPackageDirectives(source, line, index + 1, violations);
        _checkLegacyServices(source, line, index + 1, violations);
        _checkStaticServiceLocators(source, line, index + 1, violations);
        if (source.package.name.startsWith('feature_') && source.isLibrary) {
          _checkFeatureImplementations(source, line, index + 1, violations);
        }
      }
    }

    violations.sort((a, b) {
      final path = a.path.compareTo(b.path);
      if (path != 0) return path;
      final line = a.line.compareTo(b.line);
      if (line != 0) return line;
      return a.rule.compareTo(b.rule);
    });
    return violations;
  }

  void _checkPackageDirectives(
    _SourceFile source,
    String line,
    int lineNumber,
    List<ArchitectureViolation> violations,
  ) {
    final match = _packageDirective.firstMatch(line);
    if (match == null) return;

    final target = match.group(1)!;
    final targetPath = match.group(2)!;
    if (target != source.package.name && targetPath.startsWith('src/')) {
      violations.add(
        _violation(
          'cross-package-src',
          source,
          lineNumber,
          '禁止跨 Package 导入 package:$target/src/；请使用 Public API 或 Contract。',
        ),
      );
      return;
    }

    if (!source.package.name.startsWith('feature_') ||
        !target.startsWith('feature_') ||
        target == source.package.name ||
        allowlist.allowsFeatureDependency(source.package.name, target)) {
      return;
    }

    violations.add(
      _violation(
        'feature-to-feature',
        source,
        lineNumber,
        'Feature 不得直接依赖 $target；请通过 Core Contract/Capability，或提交架构评审后加入 Allowlist。',
      ),
    );
  }

  void _checkLegacyServices(
    _SourceFile source,
    String line,
    int lineNumber,
    List<ArchitectureViolation> violations,
  ) {
    final match = _legacyService.firstMatch(line);
    if (match == null) return;
    violations.add(
      _violation(
        'legacy-service',
        source,
        lineNumber,
        '禁止重新引入 ${match.group(0)}；请使用当前 Module/Repository 边界。',
      ),
    );
  }

  void _checkStaticServiceLocators(
    _SourceFile source,
    String line,
    int lineNumber,
    List<ArchitectureViolation> violations,
  ) {
    for (final match in _staticServiceLocator.allMatches(line)) {
      final value = match.group(0)!;
      if (allowlist.allowsStaticServiceLocator(value)) continue;
      violations.add(
        _violation(
          'static-service-locator',
          source,
          lineNumber,
          '禁止新增 $value；请通过生命周期 Owner 和依赖注入提供能力。',
        ),
      );
    }
  }

  void _checkFeatureImplementations(
    _SourceFile source,
    String line,
    int lineNumber,
    List<ArchitectureViolation> violations,
  ) {
    final match = _featureImplementation.firstMatch(line);
    if (match == null) return;
    violations.add(
      _violation(
        'feature-creates-core-impl',
        source,
        lineNumber,
        'Feature 不得创建 ${match.group(1)}；实现必须由 AppRuntime/Infrastructure Owner 注入。',
      ),
    );
  }

  ArchitectureViolation _violation(
    String rule,
    _SourceFile source,
    int line,
    String message,
  ) => ArchitectureViolation(
    rule: rule,
    path: _relativePath(source.file.path),
    line: line,
    message: message,
  );

  List<_PackageInfo> _discoverPackages() {
    final packages = <_PackageInfo>[];
    for (final relativeRoot in _scanRoots) {
      final root = Directory(_join(repositoryRoot.path, relativeRoot));
      if (!root.existsSync()) continue;
      for (final pubspec in _findPubspecs(root)) {
        final name = _readPackageName(pubspec);
        if (name == null) continue;
        packages.add(_PackageInfo(name: name, directory: pubspec.parent));
      }
    }
    packages.sort((a, b) => b.path.length.compareTo(a.path.length));
    return packages;
  }

  List<_SourceFile> _discoverSources(List<_PackageInfo> packages) {
    final sources = <_SourceFile>[];
    for (final package in packages) {
      for (final file in _findDartFiles(package.directory)) {
        final owner = packages.firstWhere(
          (candidate) => _isWithin(candidate.path, file.path),
          orElse: () => package,
        );
        if (owner.path != package.path) continue;
        sources.add(
          _SourceFile(
            file: file,
            package: package,
            isLibrary: _isWithin(_join(package.path, 'lib'), file.path),
          ),
        );
      }
    }
    sources.sort(
      (a, b) =>
          _relativePath(a.file.path).compareTo(_relativePath(b.file.path)),
    );
    return sources;
  }

  Iterable<File> _findPubspecs(Directory directory) sync* {
    for (final entity in directory.listSync(followLinks: false)) {
      if (entity is Directory) {
        if (_ignoredDirectory(entity)) continue;
        yield* _findPubspecs(entity);
      } else if (entity is File && _basename(entity.path) == 'pubspec.yaml') {
        yield entity;
      }
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

  String? _readPackageName(File pubspec) {
    final match = RegExp(
      r'^name:\s*([A-Za-z0-9_]+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec.readAsStringSync());
    return match?.group(1);
  }

  String _relativePath(String path) {
    final root = _normalise(repositoryRoot.absolute.path);
    final value = _normalise(path);
    return value.startsWith('$root/')
        ? value.substring(root.length + 1)
        : value;
  }
}

final class _PackageInfo {
  _PackageInfo({required this.name, required Directory directory})
    : directory = directory.absolute;

  final String name;
  final Directory directory;
  String get path => _normalise(directory.path);
}

final class _SourceFile {
  const _SourceFile({
    required this.file,
    required this.package,
    required this.isLibrary,
  });

  final File file;
  final _PackageInfo package;
  final bool isLibrary;
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
final _legacyService = RegExp(r'\b(?:StorageService|AppDatabase)\b');
final _staticServiceLocator = RegExp(
  r'\b(?:[A-Z][A-Za-z0-9_]*Service\.instance|Global\.[A-Za-z0-9_]+|GetIt\.I)\b',
);
final _featureImplementation = RegExp(
  r'\b(NetworkRuntimeImpl|SshSessionManagerImpl)\s*\(',
);

bool _ignoredDirectory(Directory directory) {
  final name = _basename(directory.path);
  return name.startsWith('.') ||
      name == 'build' ||
      name == 'coverage' ||
      name == 'node_modules';
}

bool _isGenerated(String path) =>
    path.endsWith('.g.dart') || path.endsWith('.freezed.dart');

bool _isWithin(String directory, String file) {
  final root = _normalise(directory);
  final value = _normalise(file);
  return value == root || value.startsWith('$root/');
}

String _join(String parent, String child) =>
    '$parent${Platform.pathSeparator}$child';

String _basename(String path) => path.split(RegExp(r'[\\/]')).last;

String _normalise(String path) => path.replaceAll('\\', '/').toLowerCase();

void main() {
  final violations = ArchitectureChecker(
    repositoryRoot: Directory.current,
  ).check();
  if (violations.isEmpty) {
    stdout.writeln('Architecture check passed.');
    return;
  }

  stderr.writeln(
    'Architecture check failed with ${violations.length} violation(s):',
  );
  for (final violation in violations) {
    stderr.writeln('  $violation');
  }
  exitCode = 1;
}
