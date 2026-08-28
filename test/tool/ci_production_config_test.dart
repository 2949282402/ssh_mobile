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
