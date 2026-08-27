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
