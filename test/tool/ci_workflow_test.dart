import 'dart:io';

/// 验证模块级 CI 合同，避免 Workspace、Melos 脚本和 GitHub Actions 漂移。
///
/// 这个测试只读取文本，不执行 CI 命令；它把 CI 的关键入口固定为可审计的
/// 字符串，避免为了检查 YAML 再引入一个与 Flutter 工作区冲突的解析依赖。
void main() {
  final root = _findRepositoryRoot();
  final pubspec = File('${root.path}/pubspec.yaml').readAsStringSync();
  final workflow = File(
    '${root.path}/.github/workflows/flutter.yml',
  ).readAsStringSync();

  _expect(pubspec.contains('\nmelos:\n'), '根 pubspec 必须声明 Melos 配置');
  _expect(pubspec.contains('    format:'), 'Melos 必须提供 format 脚本');
  _expect(pubspec.contains('    analyze:'), 'Melos 必须提供 analyze 脚本');
  _expect(pubspec.contains('    test:'), 'Melos 必须提供 test 脚本');
  _expect(
    !File('${root.path}/melos.yaml').existsSync(),
    'Melos 8 配置迁移到根 pubspec 后不得保留第二份配置源',
  );

  for (final marker in _requiredWorkflowMarkers) {
    _expect(workflow.contains(marker), 'CI 缺少必要入口：$marker');
  }

  final workspaceMembers = RegExp(
    r'^\s+- ((?:apps|packages)/[^\s]+)$',
    multiLine: true,
  ).allMatches(pubspec).map((match) => match.group(1)!).toList();
  _expect(workspaceMembers.length == 20, 'Workspace Member 数量发生漂移');
  for (final member in workspaceMembers) {
    _expect(
      Directory('${root.path}/$member').existsSync(),
      'Workspace 路径不存在：$member',
    );
  }

  stdout.writeln('CI workflow contract tests passed.');
}

/// 查找仓库根目录，支持从测试文件目录或仓库根目录启动。
Directory _findRepositoryRoot() {
  var current = Directory.current;
  while (true) {
    if (File('${current.path}/pubspec.yaml').existsSync() &&
        File('${current.path}/.github/workflows/flutter.yml').existsSync()) {
      return current;
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('无法找到 SSH Mobile Workspace 根目录');
    }
    current = parent;
  }
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}

const _requiredWorkflowMarkers = <String>[
  'package-quality:',
  'fetch-depth: 0',
  'architecture-check:',
  'workspace-quality:',
  'terminal-smoke-build:',
  '--diff=',
  '--include-dependents',
  'dart format --output=none --set-exit-if-changed lib test',
  'flutter analyze --no-pub',
  'flutter test --no-pub',
  'dart run tool/architecture_check.dart',
  'dart run melos run analyze',
  'dart run melos run test',
  'flutter build apk --debug --no-pub',
  'flutter build windows --debug --no-pub',
  'apps/ssh_mobile_full',
  'apps/ssh_mobile_terminal',
];
