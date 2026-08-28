// CI workflow contract checks shared by test/tool/ci_workflow_test.dart.

part of 'ci_workflow_test.dart';

void _verifyScriptTrees(Directory root) {
  final bashRoot = Directory('${root.path}/scripts/bash');
  final powerShellRoot = Directory('${root.path}/scripts/powershell');
  final bashDirectories = bashRoot
      .listSync(recursive: true)
      .whereType<Directory>()
      .map((directory) => directory.path.substring(bashRoot.path.length + 1))
      .toSet();
  final powerShellDirectories = powerShellRoot
      .listSync(recursive: true)
      .whereType<Directory>()
      .map(
        (directory) => directory.path.substring(powerShellRoot.path.length + 1),
      )
      .toSet();
  _expect(
    bashDirectories.length == powerShellDirectories.length &&
        bashDirectories.containsAll(powerShellDirectories),
    'Bash 与 PowerShell 的功能子目录结构必须一致',
  );
  for (final shellScript
      in bashRoot
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.sh'))) {
    final relative = shellScript.path.substring(bashRoot.path.length + 1);
    final pair =
        '${powerShellRoot.path}/${relative.replaceFirst(RegExp(r'\.sh$'), '.ps1')}';
    _expect(File(pair).existsSync(), 'Shell 脚本缺少 PowerShell 配对：$relative');
  }
  const powerShellOnly = <String>{
    'common/powershell_common.ps1',
    'platform/build_windows_msi.ps1',
    'platform/configure_windows_toolchain.ps1',
  };
  for (final script
      in powerShellRoot
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.ps1'))) {
    final relative = script.path.substring(powerShellRoot.path.length + 1);
    if (powerShellOnly.contains(relative)) continue;
    final pair =
        '${bashRoot.path}/${relative.replaceFirst(RegExp(r'\.ps1$'), '.sh')}';
    _expect(File(pair).existsSync(), 'PowerShell 脚本缺少 Shell 配对：$relative');
  }
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

String _stepSection(String jobSection, String stepName) {
  final startMatch = RegExp(
    r'^\s*-\s+name:\s+' + RegExp.escape(stepName) + r'\s*$',
    multiLine: true,
  ).firstMatch(jobSection);
  if (startMatch == null) {
    throw StateError('Job 缺少 step：$stepName');
  }

  final nextStepMatches = RegExp(
    r'^\s*-\s+(?:name|uses):\s+',
    multiLine: true,
  ).allMatches(jobSection, startMatch.end);
  final nextStepMatch = nextStepMatches.isEmpty ? null : nextStepMatches.first;
  return jobSection.substring(
    startMatch.start,
    nextStepMatch?.start ?? jobSection.length,
  );
}

void _verifyProtocolV2Workflow(String workflow) {
  final protocolV2Contract = _jobSection(workflow, 'protocol-v2-contract');
  _expect(
    protocolV2Contract.contains('subosito/flutter-action@v2'),
    'protocol-v2-contract 必须安装 Flutter 后运行 Dart owner tests',
  );
  _expect(
    protocolV2Contract.contains('run: dart pub get'),
    'protocol-v2-contract 必须安装 workspace dependencies',
  );
  _expect(
    protocolV2Contract.contains(
          'working-directory: packages/infrastructure/ssh_mobile_network_native',
        ) &&
        protocolV2Contract.contains('run: flutter pub get'),
    'protocol-v2-contract 必须安装 native Dart package dependencies',
  );

  final paritySelfTest = _stepSection(
    protocolV2Contract,
    'Test Network V2 parity checker',
  );
  _expect(
    paritySelfTest.contains(
      'dart run scripts/bash/contracts/check_network_v2_contract.dart --test',
    ),
    'Test Network V2 parity checker 必须运行在 --test 自测模式',
  );

  final parityCheck = _stepSection(
    protocolV2Contract,
    'Check Network V2 schema parity',
  );
  _expect(
    parityCheck.contains(
      'dart run scripts/bash/contracts/check_network_v2_contract.dart',
    ),
    'Check Network V2 schema parity 必须运行正式 parity check',
  );
  _expect(
    !parityCheck.contains('--test'),
    'Check Network V2 schema parity 严禁使用 --test 模式',
  );
}

void _testProtocolV2WorkflowChecker() {
  const validSnippet = '''
  protocol-v2-contract:
    steps:
      - uses: subosito/flutter-action@v2
      - run: dart pub get
      - working-directory: packages/infrastructure/ssh_mobile_network_native
        run: flutter pub get
      - name: Test Network V2 parity checker
        run: dart run scripts/bash/contracts/check_network_v2_contract.dart --test
      - name: Check Network V2 schema parity
        run: dart run scripts/bash/contracts/check_network_v2_contract.dart
''';

  _verifyProtocolV2Workflow(validSnippet);

  const missingFormalStep = '''
  protocol-v2-contract:
    steps:
      - uses: subosito/flutter-action@v2
      - run: dart pub get
      - working-directory: packages/infrastructure/ssh_mobile_network_native
        run: flutter pub get
      - name: Test Network V2 parity checker
        run: dart run scripts/bash/contracts/check_network_v2_contract.dart --test
''';
  var failedMissing = false;
  try {
    _verifyProtocolV2Workflow(missingFormalStep);
  } catch (_) {
    failedMissing = true;
  }
  _expect(
    failedMissing,
    'CI contract checker must fail when formal parity step is missing',
  );

  const formalCheckWithTestFlag = '''
  protocol-v2-contract:
    steps:
      - uses: subosito/flutter-action@v2
      - run: dart pub get
      - working-directory: packages/infrastructure/ssh_mobile_network_native
        run: flutter pub get
      - name: Test Network V2 parity checker
        run: dart run scripts/bash/contracts/check_network_v2_contract.dart --test
      - name: Check Network V2 schema parity
        run: dart run scripts/bash/contracts/check_network_v2_contract.dart --test
''';
  var failedWithTestFlag = false;
  try {
    _verifyProtocolV2Workflow(formalCheckWithTestFlag);
  } catch (_) {
    failedWithTestFlag = true;
  }
  _expect(
    failedWithTestFlag,
    'CI contract checker must fail when formal parity step contains --test',
  );
}

void _verifyFullTestScripts(Directory root) {
  final bashFullTest = File(
    '${root.path}/scripts/bash/ci/full_test.sh',
  ).readAsStringSync();
  final bashJobs = File(
    '${root.path}/scripts/bash/ci/full_test_jobs.sh',
  ).readAsStringSync();
  final powerShellFullTest = File(
    '${root.path}/scripts/powershell/ci/full_test.ps1',
  ).readAsStringSync();
  final powerShellJobs = File(
    '${root.path}/scripts/powershell/ci/full_test_jobs.ps1',
  ).readAsStringSync();

  _expect(
    bashJobs.contains(
      "step 'Test Network V2 schema parity checker' dart run scripts/bash/contracts/check_network_v2_contract.dart --test",
    ),
    'full_test_jobs.sh 缺少 Network V2 schema parity checker self-test step',
  );
  _expect(
    bashJobs.contains(
      "step 'Run Network V2 schema parity check' dart run scripts/bash/contracts/check_network_v2_contract.dart",
    ),
    'full_test_jobs.sh 缺少 Network V2 schema parity check step',
  );
  _expect(
    bashJobs.contains(
      "step 'Check Telemetry data contract across Go, Front, and Dart' bash \"\$ROOT_DIR/scripts/bash/contracts/telemetry_contract.sh\"",
    ),
    'full_test_jobs.sh 缺少 Telemetry contract check step',
  );
  _expect(
    bashFullTest.contains('source "\$SCRIPT_DIR/full_test_jobs.sh"'),
    'full_test.sh 必须加载 workspace/service CI helper',
  );

  _expect(
    powerShellJobs.contains(
      "Cmd dart @('run','scripts/bash/contracts/check_network_v2_contract.dart','--test')",
    ),
    'full_test_jobs.ps1 缺少 Network V2 schema parity checker self-test',
  );
  _expect(
    powerShellJobs.contains(
      "Cmd dart @('run','scripts/bash/contracts/check_network_v2_contract.dart')",
    ),
    'full_test_jobs.ps1 缺少 Network V2 schema parity check',
  );
  _expect(
    powerShellJobs.contains(
      "Script (Join-Path \$PSScriptRoot '..\\contracts\\telemetry_contract.ps1')",
    ),
    'full_test_jobs.ps1 缺少 Telemetry contract check',
  );
  _expect(
    powerShellFullTest.contains("full_test_jobs.ps1"),
    'full_test.ps1 必须加载 workspace/service CI helper',
  );
}
