import 'dart:io';

import '../../tool/check_telemetry_producers.dart';

/// Regression tests for the telemetry producer source boundary.
///
/// This is intentionally a dependency-free `dart run` script so the same
/// checker can run in the Bash and PowerShell contract gates.
void main() {
  final root = Directory.systemTemp.createTempSync('ssh_mobile_telem_ban_');
  try {
    _writeContractSources(root);
    _testCleanGeneratedSourceIsAllowed(root);
    _testMirrorAndLegacyApiAreRejected(root);
    _testRawContractLiteralsAreRejected(root);
    _testRawContractLiteralsInTemplatesAndConcatsAreRejected(root);
    _testRawContractLiteralsInLoggingAllowlistsAreRejected(root);
    _testFrontRootContractImportsAreRejected(root);
    stdout.writeln('Telemetry producer source-ban tests passed.');
  } finally {
    root.deleteSync(recursive: true);
  }
}

void _writeContractSources(Directory root) {
  final contracts = Directory('${root.path}/contracts/telemetry')
    ..createSync(recursive: true);
  File('${contracts.path}/events.yaml').writeAsStringSync('''
version: "1.0.0"
events:
  - name: "ssh.session.started"
    version: 1
    recordType: "analytics"
    feature: "ssh"
    severity: "info"
    operationGroup: "ssh.session"
    operationRole: "started"
    allowedProperties: []
''');
  File('${contracts.path}/error_codes.yaml').writeAsStringSync('''
version: "1.0.0"
errorCodes:
  - code: "SSH_CONNECT_FAILED"
    category: "ssh"
    terminalFailure: true
''');
}

void _testCleanGeneratedSourceIsAllowed(Directory root) {
  final generated = Directory('${root.path}/front/src/generated')
    ..createSync(recursive: true);
  File('${generated.path}/telemetry_contract.ts').writeAsStringSync('''
// GENERATED DO NOT EDIT
export const eventName = 'ssh.session.started';
''');
  _expect(
    scanForViolations(root).isEmpty,
    'generated contract output should be excluded from producer bans',
  );
}

void _testMirrorAndLegacyApiAreRejected(Directory root) {
  final source = Directory('${root.path}/apps/ssh_mobile_full/lib')
    ..createSync(recursive: true);
  File('${source.path}/legacy.dart').writeAsStringSync('''
import 'services/telemetry/app_telemetry_contract.dart';
void emit(client) {
  client.recordEvent('ssh.session.started');
}
''');
  final violations = scanForViolations(root);
  _expect(
    violations.any((violation) => violation.contains('app_telemetry_contract')),
    'legacy mirror references should be rejected',
  );
  _expect(
    violations.any((violation) => violation.contains('recordEvent')),
    'legacy recordEvent calls should be rejected',
  );
}

void _testRawContractLiteralsAreRejected(Directory root) {
  final source = Directory('${root.path}/relay/internal/telemetry')
    ..createSync(recursive: true);
  File('${source.path}/producer.go').writeAsStringSync('''
package telemetry
const event = "ssh.session.started"
const code = "SSH_CONNECT_FAILED"
''');
  final violations = scanForViolations(root);
  _expect(
    violations.any((violation) => violation.contains('ssh.session.started')),
    'raw event literals should be rejected',
  );
  _expect(
    violations.any((violation) => violation.contains('SSH_CONNECT_FAILED')),
    'raw error-code literals should be rejected',
  );
}

void _testRawContractLiteralsInTemplatesAndConcatsAreRejected(Directory root) {
  final goSource = Directory('${root.path}/relay/internal/telemetry')
    ..createSync(recursive: true);
  File('${goSource.path}/producer_raw.go').writeAsStringSync(r'''
package telemetry
const goEvent = `ssh.session.started`
const goCode = ("SSH_" + "CONNECT_" + "FAILED")
''');
  final tsSource = Directory('${root.path}/front/src/telemetry')
    ..createSync(recursive: true);
  File('${tsSource.path}/producer_raw.ts').writeAsStringSync(r'''
const tsEvent = `ssh.${('session.' + 'started')}`;
const tsCode = 'SSH_' + 'CONNECT_' + 'FAILED';
const escapedEvent = "\x73sh.session.started";
''');
  final jsSource = Directory('${root.path}/apps/ssh_mobile_full/lib')
    ..createSync(recursive: true);
  File('${jsSource.path}/producer_raw.js').writeAsStringSync(r'''
const jsEvent = `ssh.session.started`;
const jsCode = "SSH_" + "CONNECT_" + "FAILED";
''');
  final generated = Directory('${root.path}/front/src/generated')
    ..createSync(recursive: true);
  File('${generated.path}/producer_raw.ts').writeAsStringSync(r'''
const generatedEvent = `ssh.session.started`;
const generatedCode = 'SSH_' + 'CONNECT_FAILED';
''');
  final generatedSuffix = Directory('${root.path}/front/src/contracts')
    ..createSync(recursive: true);
  File(
    '${generatedSuffix.path}/telemetry_contract.generated.ts',
  ).writeAsStringSync(r'''
const generatedEvent = `ssh.session.started`;
const generatedCode = 'SSH_' + 'CONNECT_FAILED';
''');

  final violations = scanForViolations(root);
  _expect(
    violations.any(
      (violation) =>
          violation.contains('producer_raw.go') &&
          violation.contains('ssh.session.started'),
    ),
    'Go raw telemetry literals in backticks should be rejected',
  );
  _expect(
    violations.any(
      (violation) =>
          violation.contains('producer_raw.go') &&
          violation.contains('SSH_CONNECT_FAILED'),
    ),
    'Go concatenated telemetry literals should be rejected',
  );
  _expect(
    violations.any(
      (violation) =>
          violation.contains('producer_raw.ts') &&
          violation.contains('ssh.session.started'),
    ),
    'TypeScript template and escaped telemetry literals should be rejected',
  );
  _expect(
    violations.any(
      (violation) =>
          violation.contains('producer_raw.ts') &&
          violation.contains('SSH_CONNECT_FAILED'),
    ),
    'TypeScript concatenated telemetry literals should be rejected',
  );
  _expect(
    violations.any(
      (violation) =>
          violation.contains('producer_raw.js') &&
          violation.contains('ssh.session.started'),
    ),
    'JavaScript template telemetry literals should be rejected',
  );
  _expect(
    violations.every(
      (violation) => !violation.contains('front/src/generated/producer_raw.ts'),
    ),
    'generated producer artifacts should remain excluded',
  );
}

void _testRawContractLiteralsInLoggingAllowlistsAreRejected(Directory root) {
  final source = Directory(
    '${root.path}/packages/core/app_core/lib/src/logging',
  )..createSync(recursive: true);
  File('${source.path}/telemetry_log_sink.dart').writeAsStringSync('''
const allowlistedEvents = {'ssh.session.started'};
const allowlistedErrors = {'SSH_CONNECT_FAILED'};
''');
  final violations = scanForViolations(root);
  _expect(
    violations.any(
      (violation) =>
          violation.contains('ssh.session.started') &&
          violation.contains('telemetry_log_sink.dart'),
    ),
    'raw event literals in logging allowlists should be rejected',
  );
  _expect(
    violations.any(
      (violation) =>
          violation.contains('SSH_CONNECT_FAILED') &&
          violation.contains('telemetry_log_sink.dart'),
    ),
    'raw error-code literals in logging allowlists should be rejected',
  );
}

void _testFrontRootContractImportsAreRejected(Directory root) {
  final source = Directory('${root.path}/front/src/schemas')
    ..createSync(recursive: true);
  File('${source.path}/telemetry.ts').writeAsStringSync('''
import eventsJson from '../../../contracts/telemetry/events.json';
''');
  final violations = scanForViolations(root);
  _expect(
    violations.any((violation) => violation.contains('contracts/telemetry')),
    'Front should not import root JSON contracts directly',
  );
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError('FAILED: $message');
  }
}
