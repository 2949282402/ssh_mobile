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

  _expect(workflow.contains("      - '**'"), 'CI 必须对所有分支 push 触发');
  _expect(
    !workflow.contains('pull_request:'),
    'CI 不应为同一提交重复注册 pull_request 流程',
  );
  _expect(
    !workflow.contains('package-quality:'),
    'CI 不应保留只服务于 pull_request 的 package-quality job',
  );
  _expect(
    !workflow.contains('needs: architecture-check'),
    '质量与构建 job 应与 architecture-check 并行执行',
  );

  final workspaceQuality = _jobSection(workflow, 'workspace-quality');
  for (final packageName in _isolatedPackageNames) {
    _expect(
      workspaceQuality.contains('--ignore=$packageName'),
      'workspace-quality 不应重复执行独立包：$packageName',
    );
  }
  _expect(
    !workspaceQuality.contains('flutter build apk'),
    'workspace-quality 不应重复构建 Full App Android',
  );

  final sdkDartQuality = _jobSection(workflow, 'sdk-dart-quality');
  for (final packageName in _sdkPackageNames) {
    _expect(
      sdkDartQuality.contains('--scope=$packageName'),
      'sdk-dart-quality 缺少独立 SDK 包：$packageName',
    );
  }

  final clientQuality = _jobSection(workflow, 'analyze-and-test');
  _expect(
    _countOccurrences(
          clientQuality,
          'flutter test --coverage --reporter expanded',
        ) ==
        1,
    'Full App coverage 测试必须只有一个权威入口',
  );
  _expect(
    !clientQuality.contains('Test native Dart package'),
    'Full App job 不应重复执行 Native Dart SDK 测试',
  );

  for (final jobName in _buildOnlyJobNames) {
    final job = _jobSection(workflow, jobName);
    _expect(
      !job.contains('flutter test'),
      '$jobName 只负责平台构建，不应运行完整 Flutter 测试',
    );
  }

  final expectedBuildCommands = <String>[
    'flutter build apk --debug --no-pub',
    'flutter build windows',
    'flutter build macos',
    'flutter build ios --release --no-codesign --no-pub',
    'flutter build windows --debug --no-pub',
  ];
  for (final command in expectedBuildCommands) {
    _expect(workflow.contains(command), 'CI 缺少平台构建命令：$command');
  }

  final workspaceMembers = RegExp(
    r'^\s+- ((?:apps|packages)/[^\s]+)$',
    multiLine: true,
  ).allMatches(pubspec).map((match) => match.group(1)!).toList();
  _expect(workspaceMembers.length == 21, 'Workspace Member 数量发生漂移');
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

String _jobSection(String workflow, String jobName) {
  final startMatch = RegExp(
    '^  ${RegExp.escape(jobName)}:\\s*\\n',
    multiLine: true,
  ).firstMatch(workflow);
  if (startMatch == null) {
    throw StateError('CI 缺少 job：$jobName');
  }

  final endMatches = RegExp(
    r'^  [A-Za-z0-9_-]+:\s*$',
    multiLine: true,
  ).allMatches(workflow, startMatch.end);
  final endMatch = endMatches.isEmpty ? null : endMatches.first;
  return workflow.substring(
    startMatch.start,
    endMatch?.start ?? workflow.length,
  );
}

int _countOccurrences(String value, String pattern) {
  var count = 0;
  var offset = 0;
  while (true) {
    final index = value.indexOf(pattern, offset);
    if (index == -1) return count;
    count++;
    offset = index + pattern.length;
  }
}

const _requiredWorkflowMarkers = <String>[
  'architecture-check:',
  'sdk-dart-quality:',
  'workspace-quality:',
  'terminal-smoke-build:',
  'android-build:',
  'windows-build:',
  'macos-build:',
  'ios-build:',
  'flutter analyze --no-fatal-infos',
  'flutter test --coverage --reporter expanded',
  'dart run tool/architecture_check.dart',
  'dart run tool/compatibility_check.dart',
  'dart run tool/duplicate_implementation_check.dart',
  'dart run melos run analyze',
  'dart run melos run test',
  'flutter build apk --debug --no-pub',
  'flutter build windows --debug --no-pub',
  'flutter build windows',
  'flutter build macos',
  'flutter build ios --release --no-codesign --no-pub',
  'apps/ssh_mobile_full',
  'apps/ssh_mobile_terminal',
];

const _isolatedPackageNames = <String>[
  'ssh_mobile',
  'network_sdk',
  'network_transport',
  'ssh_mobile_network_native',
];

const _sdkPackageNames = <String>[
  'network_sdk',
  'network_transport',
  'ssh_mobile_network_native',
];

const _buildOnlyJobNames = <String>[
  'android-build',
  'windows-build',
  'macos-build',
  'ios-build',
  'terminal-smoke-build',
];
