import 'dart:io';

/// Guards the CI/production boundaries that are easy to regress when the
/// aggregate scripts or Docker contexts are edited.
void main() {
  final root = _findRepositoryRoot();
  final compose = File('${root.path}/compose.yaml').readAsStringSync();
  final dockerfile = File('${root.path}/front/Dockerfile').readAsStringSync();
  final tsconfig = File(
    '${root.path}/front/tsconfig.app.json',
  ).readAsStringSync();
  final testTsconfig = File('${root.path}/front/tsconfig.tests.json');
  final packageJson = File(
    '${root.path}/front/package.json',
  ).readAsStringSync();
  final workflow = File(
    '${root.path}/.github/workflows/flutter.yml',
  ).readAsStringSync();
  final backendCoverage = File(
    '${root.path}/scripts/bash/coverage/backend_coverage.sh',
  ).readAsStringSync();
  final backendCoveragePowerShell = File(
    '${root.path}/scripts/powershell/coverage/backend_coverage.ps1',
  ).readAsStringSync();
  final bashApp = File(
    '${root.path}/scripts/bash/ci/full_test_app.sh',
  ).readAsStringSync();
  final powerShellApp = File(
    '${root.path}/scripts/powershell/ci/full_test_app.ps1',
  ).readAsStringSync();
  final bashE2e = File(
    '${root.path}/scripts/bash/e2e/client_backend_e2e.sh',
  ).readAsStringSync();
  final bashTelemetryE2e = File(
    '${root.path}/scripts/bash/e2e/client_backend_telemetry.sh',
  ).readAsStringSync();
  final powerShellE2e = File(
    '${root.path}/scripts/powershell/e2e/client_backend_e2e.ps1',
  ).readAsStringSync();
  final powerShellTelemetryE2e = File(
    '${root.path}/scripts/powershell/e2e/client_backend_telemetry.ps1',
  ).readAsStringSync();
  final powerShellRunner = File(
    '${root.path}/scripts/powershell/ci/full_test_runner.ps1',
  ).readAsStringSync();

  for (final variable in const [
    'TELEMETRY_MYSQL_DSN',
    'TELEMETRY_REDIS_URL',
    'TELEMETRY_AUTH_SECRET',
    'ANALYTICS_MYSQL_PASSWORD',
    'ANALYTICS_MYSQL_ROOT_PASSWORD',
    'ANALYTICS_REDIS_PASSWORD',
  ]) {
    _expect(
      compose.contains('\${$variable:?'),
      'Compose must require $variable instead of supplying a default.',
    );
  }
  for (final forbidden in const [
    'telemetry_secret_pass',
    'telemetry_root_pass',
    'analytics_redis_secret_pass',
  ]) {
    _expect(
      !compose.contains(forbidden),
      'Compose contains a predictable analytics secret: $forbidden',
    );
  }
  for (final service in const ['analytics-mysql', 'analytics-redis']) {
    _expect(
      compose.contains('$service:') && compose.contains('service_healthy'),
      'Admin Compose startup must wait for healthy $service.',
    );
    _expect(
      compose.contains('$service:') && compose.contains('healthcheck:'),
      'Analytics service $service must define a readiness healthcheck.',
    );
  }
  _expect(
    compose.contains('profiles: ["storage"]') &&
        compose.contains('required: true'),
    'Analytics storage must remain an explicit, required production profile dependency.',
  );

  for (final example in [
    File('${root.path}/.env.example'),
    File('${root.path}/relay/.env.example'),
  ]) {
    final text = example.readAsStringSync();
    for (final variable in const [
      'TELEMETRY_MYSQL_DSN',
      'TELEMETRY_REDIS_URL',
      'TELEMETRY_AUTH_SECRET',
      'ANALYTICS_MYSQL_PASSWORD',
      'ANALYTICS_MYSQL_ROOT_PASSWORD',
      'ANALYTICS_REDIS_PASSWORD',
    ]) {
      _expect(
        text.contains('$variable='),
        '${example.path} must document $variable.',
      );
    }
    _expect(
      !text.contains('telemetry_secret_pass') &&
          !text.contains('analytics_redis_secret_pass'),
      '${example.path} must not contain a real or predictable secret.',
    );
  }

  _expect(
    dockerfile.contains('src/generated/telemetry_contract.ts'),
    'Front Docker must verify the committed generated telemetry catalog.',
  );
  _expect(
    !dockerfile.contains('COPY ../') && !dockerfile.contains('COPY contracts/'),
    'Front Docker must not reach outside its self-contained build context.',
  );
  _expect(
    !dockerfile.contains('policy.schema.json') &&
        !dockerfile.contains('contracts/telemetry'),
    'Front Docker must not consume the repository telemetry JSON contract.',
  );
  _expect(
    !tsconfig.contains('"tests"'),
    'The production Front TypeScript project must not compile root-contract tests.',
  );
  _expect(
    testTsconfig.existsSync(),
    'Front tests need a dedicated TypeScript project.',
  );
  _expect(
    testTsconfig.readAsStringSync().contains('"tests"'),
    'The Front test TypeScript project must include front/tests.',
  );
  _expect(
    packageJson.contains('"typecheck:tests"'),
    'Front package scripts must expose the test TypeScript gate.',
  );
  _expect(
    workflow.contains('npm run typecheck:tests'),
    'front-quality must run the Front test TypeScript gate.',
  );
  for (final marker in const [
    'analytics-mysql:',
    'analytics-redis:',
    'TELEMETRY_TEST_MYSQL_DSN:',
    'TELEMETRY_TEST_REDIS_URL:',
    'TELEMETRY_MYSQL_DSN:',
    'TELEMETRY_REDIS_URL:',
  ]) {
    _expect(
      workflow.contains(marker),
      'relay-quality must provision Analytics dependencies and test URLs: $marker',
    );
  }

  for (final coverage in [backendCoverage, backendCoveragePowerShell]) {
    _expect(
      coverage.contains('coverpkg') &&
          coverage.contains('go list') &&
          coverage.contains('./internal/...') &&
          coverage.contains('./cmd/...') &&
          coverage.contains('TELEMETRY_TEST_MYSQL_DSN') &&
          coverage.contains('TELEMETRY_TEST_REDIS_URL'),
      'Backend coverage must instrument production packages and run telemetry integration tests.',
    );
    _expect(
      coverage.contains('internal/telemetry') &&
          coverage.contains('TELEMETRY_COVERAGE_MINIMUM'),
      'Backend coverage must enforce a real telemetry-specific threshold.',
    );
  }
  _expect(
    bashApp.contains('partition_app_tests') &&
        bashApp.contains('Security regression grep') &&
        bashApp.contains('retrying once'),
    'Bash App CI must keep balanced sharding, security grep, and retries.',
  );
  _expect(
    powerShellApp.contains('Partition-AppFiles') &&
        powerShellApp.contains('SshIdentityCache') &&
        powerShellApp.contains('Retrying App shard') &&
        powerShellApp.contains('Assert-AppSecurityIdentifiers'),
    'PowerShell App CI must match Bash sharding, security grep, and retries.',
  );
  _expect(
    bashTelemetryE2e.contains('TELEMETRY_INGESTION_PASS') &&
        bashTelemetryE2e.contains('telemetry_ingest') &&
        bashE2e.contains('assert_storage_after_restart'),
    'Bash E2E must assert telemetry ingestion and persistence behavior.',
  );
  _expect(
    powerShellTelemetryE2e.contains('TELEMETRY_INGESTION_PASS') &&
        powerShellE2e.contains('TelemetryIngestion') &&
        powerShellE2e.contains('AssertStorageAfterRestart'),
    'PowerShell E2E must match Bash telemetry and persistence assertions.',
  );
  _expect(
    bashE2e.contains('COMPOSE_PROFILE_ARGS=(--profile storage)') &&
        powerShellE2e.contains("'--profile','storage'"),
    'Both E2E launchers must activate the required Analytics storage profile.',
  );
  _expect(
    powerShellRunner.contains('RecordSkip') &&
        powerShellRunner.contains('Flutter coverage was not enabled') &&
        powerShellRunner.contains('Full App coverage depends'),
    'PowerShell CI must preserve Bash app-coverage skip semantics.',
  );

  final bashCi = Directory('${root.path}/scripts/bash/ci');
  final powershellCi = Directory('${root.path}/scripts/powershell/ci');
  final bashNames = bashCi
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.sh'))
      .map((file) => _basename(file.path, '.sh'))
      .toSet();
  final powerShellNames = powershellCi
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.ps1'))
      .map((file) => _basename(file.path, '.ps1'))
      .toSet();
  _expect(
    bashNames.difference(powerShellNames).isEmpty &&
        powerShellNames.difference(bashNames).isEmpty,
    'CI helper modules must have same-relative Bash and PowerShell pairs.',
  );
  for (final file in [
    ...bashCi.listSync().whereType<File>(),
    ...powershellCi.listSync().whereType<File>(),
  ]) {
    _expect(
      file.readAsLinesSync().length <= 500,
      'CI script exceeds the 500-line review limit: ${file.path}',
    );
  }

  stdout.writeln('CI production configuration tests passed.');
}

String _basename(String path, String suffix) {
  final name = path.split(RegExp(r'[\\/]')).last;
  return name.substring(0, name.length - suffix.length);
}

Directory _findRepositoryRoot() {
  var current = Directory.current;
  while (true) {
    if (File('${current.path}/pubspec.yaml').existsSync() &&
        File('${current.path}/compose.yaml').existsSync()) {
      return current;
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Unable to find SSH Mobile repository root.');
    }
    current = parent;
  }
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}
