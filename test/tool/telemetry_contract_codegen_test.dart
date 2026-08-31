import 'dart:convert';
import 'dart:io';

import '../../tool/check_telemetry_contract_generated.dart';
import '../../tool/gen_telemetry_contract.dart';

/// Regression tests for the telemetry contract generator and its staleness
/// checker. Exercises:
///  - generation against the real repo YAML sources, asserting the shape of
///    the emitted JSON and Dart constants;
///  - byte-for-byte freshness checking (no spurious writes, no false drift);
///  - drift and missing-file detection by the checker;
///  - deterministic const identifier derivation used for generated Dart.
///
/// These are intentionally dependency-free `dart run` scripts following the
/// existing `test/tool/*_test.dart` convention in this repo.
void main() {
  try {
    _testExpectedFilesMatchDisk();
    _testJsonMatchesYamlSources();
    _testGeneratedDartShape();
    _testGeneratedCrossLanguageShape();
    _testOperationMetadataAndLists();
    _testCheckerAcceptsFreshFiles();
    _testCheckerDetectsDrift();
    _testCheckerDetectsMissingFile();
    _testIdentifierDerivation();
    _testDuplicateContractEntriesRejected();
    _testMalformedYamlRejected();
    _testUnsupportedPropertyTypeRejected();
    stdout.writeln('Telemetry contract codegen tests passed.');
  } finally {
    _cleanupTempDirs();
  }
}

void _testExpectedFilesMatchDisk() {
  final root = _repoRoot();
  final expected = expectedFiles(root);
  for (final entry in expected.entries) {
    final file = File('${root.path}/${entry.key}');
    _expect(file.existsSync(), 'generated artifact should exist: ${entry.key}');
    _expect(
      file.readAsStringSync() == entry.value,
      'generated artifact should match current YAML sources: ${entry.key}',
    );
  }
}

void _testJsonMatchesYamlSources() {
  final root = _repoRoot();
  final contract = loadContract(root);

  final eventsJson =
      jsonDecode(
            File(
              '${root.path}/contracts/telemetry/events.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final errorJson =
      jsonDecode(
            File(
              '${root.path}/contracts/telemetry/error_codes.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;

  _expect(
    eventsJson['version'] == contract.eventsVersion,
    'events.json version should match the YAML version',
  );
  _expect(
    errorJson['version'] == contract.errorCodesVersion,
    'error_codes.json version should match the YAML version',
  );

  final events = eventsJson['events'] as List<dynamic>;
  _expect(events.length == contract.events.length, 'events count mismatch');
  final first = events.first as Map<String, dynamic>;
  _expect(
    first['name'] == contract.events.first.name &&
        first['recordType'] == 'analytics' &&
        first['severity'] == 'info' &&
        first['version'] == 1,
    'events[0] should match YAML definition shape',
  );
  final allowedProps = first['allowedProperties'] as List<dynamic>;
  _expect(
    allowedProps.length == 2,
    'events[0] should carry two allowed properties',
  );

  final codes = errorJson['errorCodes'] as List<dynamic>;
  _expect(
    codes.length == contract.errorCodes.length,
    'error codes count mismatch',
  );
  final firstCode = codes.first as Map<String, dynamic>;
  _expect(
    firstCode['code'] == 'NET_QUIC_CONN_REFUSED' &&
        firstCode['category'] == 'network' &&
        firstCode['terminalFailure'] == false,
    'first error code should carry code/category/terminalFailure',
  );
}

void _testGeneratedDartShape() {
  final root = _repoRoot();
  final eventsDart = File(
    '${root.path}/packages/core/app_core/lib/src/telemetry/generated/telemetry_events.dart',
  ).readAsStringSync();
  final errorDart = File(
    '${root.path}/packages/core/app_core/lib/src/telemetry/generated/error_codes.dart',
  ).readAsStringSync();

  _expect(
    eventsDart.contains(
      'GENERATED DO NOT EDIT, regenerate via dart run tool/gen_telemetry_contract.dart',
    ),
    'events Dart should carry the generated header',
  );
  _expect(
    eventsDart.contains('class TelemetryEvents {') &&
        eventsDart.contains(
          'static const sshSessionStarted = TelemetryEventDefinition(',
        ),
    'events Dart should expose lowerCamelCase const per event',
  );
  _expect(
    eventsDart.contains("name: 'ssh.session.started'") &&
        eventsDart.contains('recordType: TelemetryRecordType.analytics') &&
        eventsDart.contains(
          "allowedProperties: {'auth_method', 'session_type'}",
        ) &&
        eventsDart.contains('requiredProperties: {'),
    'events Dart constant should carry name/version/recordType/allowed properties',
  );

  _expect(
    errorDart.contains('class TelemetryErrorCodes {') &&
        errorDart.contains(
          'static const sshAuthFailed = TelemetryErrorCodeDefinition(',
        ),
    'error Dart should expose lowerCamelCase const per code',
  );
  _expect(
    errorDart.contains("code: 'SSH_AUTH_FAILED'") &&
        errorDart.contains('terminalFailure: true'),
    'error Dart constant should carry code/category/terminalFailure',
  );
}

void _testGeneratedCrossLanguageShape() {
  final root = _repoRoot();
  final go = File(
    '${root.path}/relay/internal/telemetry/generated/telemetry_contract.go',
  ).readAsStringSync();
  final ts = File(
    '${root.path}/front/src/generated/telemetry_contract.ts',
  ).readAsStringSync();

  _expect(
    go.contains('var TelemetryEvents = []EventDefinition{') &&
        go.contains('var TelemetryErrorCodes = []ErrorCodeDefinition{') &&
        go.contains('network.relay.failed'),
    'Go should expose complete generated event and error catalogs',
  );
  _expect(
    ts.contains('export class TelemetryEvents') &&
        ts.contains('static readonly all') &&
        ts.contains('export class TelemetryErrorCodes') &&
        ts.contains('APP_FATAL_ERROR') &&
        ts.contains(
          "export type TelemetryPropertyType = 'string' | 'integer' | 'boolean';",
        ) &&
        ts.contains('readonly type: TelemetryPropertyType;'),
    'TypeScript should expose complete generated catalogs and all lists',
  );
}

void _testOperationMetadataAndLists() {
  final root = _repoRoot();
  final contract = loadContract(root);
  final eventsJson =
      jsonDecode(
            File(
              '${root.path}/contracts/telemetry/events.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final relayFailed = (eventsJson['events'] as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .singleWhere((event) => event['name'] == 'network.relay.failed');
  _expect(
    relayFailed['operationGroup'] == 'network.relay' &&
        relayFailed['operationRole'] == 'failure' &&
        relayFailed['businessOperation'] == true,
    'network.relay.failed should carry explicit business operation metadata',
  );
  _expect(
    contract.events.length >= 23 && contract.errorCodes.length >= 21,
    'expanded contract should include connection/crash/precise failure semantics',
  );

  final eventsDart = File(
    '${root.path}/packages/core/app_core/lib/src/telemetry/generated/telemetry_events.dart',
  ).readAsStringSync();
  final errorsDart = File(
    '${root.path}/packages/core/app_core/lib/src/telemetry/generated/error_codes.dart',
  ).readAsStringSync();
  _expect(
    eventsDart.contains('static const List<TelemetryEventDefinition> all =') &&
        errorsDart.contains(
          'static const List<TelemetryErrorCodeDefinition> all =',
        ),
    'Dart should expose all lists',
  );
}

void _testDuplicateContractEntriesRejected() {
  final root = Directory.systemTemp.createTempSync('ssh_mobile_telem_dup_');
  _tempRoot = root;
  _writeSkeleton(root);
  final events = File('${root.path}/contracts/telemetry/events.yaml');
  events.writeAsStringSync(
    '${events.readAsStringSync()}'
    '  - name: "app.lifecycle.started"\n'
    '    version: 1\n'
    '    recordType: "analytics"\n'
    '    feature: "app"\n'
    '    severity: "info"\n'
    '    description: "duplicate"\n',
  );
  var threw = false;
  try {
    loadContract(root);
  } on FormatException {
    threw = true;
  }
  _expect(threw, 'duplicate event names should throw FormatException');
}

void _testCheckerAcceptsFreshFiles() {
  final root = _repoRoot();
  _expect(checkGenerated(root), 'fresh artifacts should pass the checker');
}

void _testCheckerDetectsDrift() {
  final root = _repoRoot();
  final eventsDart = File(
    '${root.path}/packages/core/app_core/lib/src/telemetry/generated/telemetry_events.dart',
  );
  final backup = eventsDart.readAsStringSync();
  try {
    eventsDart.writeAsStringSync('$backup\n// drift');
    _expect(!checkGenerated(root), 'drifted artifact should fail the checker');
  } finally {
    eventsDart.writeAsStringSync(backup);
  }
}

void _testCheckerDetectsMissingFile() {
  final root = _repoRoot();
  final eventsDart = File(
    '${root.path}/packages/core/app_core/lib/src/telemetry/generated/telemetry_events.dart',
  );
  final backup = eventsDart.readAsStringSync();
  try {
    eventsDart.deleteSync();
    _expect(
      checkGenerated(root) == false,
      'missing artifact should fail the checker',
    );
  } finally {
    eventsDart.writeAsStringSync(backup);
  }
}

void _testIdentifierDerivation() {
  _expect(
    _eventConstantNameForTest('ssh.session.started') == 'sshSessionStarted',
    'event name should map to lowerCamelCase constant',
  );
  _expect(
    _errorCodeConstantNameForTest('NET_QUIC_CONN_REFUSED') ==
        'netQuicConnRefused',
    'error code should map to lowerCamelCase constant',
  );
  _expect(
    _eventConstantNameForTest('lan.discovery.peer_found') ==
        'lanDiscoveryPeerFound',
    'underscore segments should be camelized',
  );
  _expect(
    _eventConstantNameForTest('2fa.challenge') == 'e2faChallenge',
    'leading digit should be prefixed with e',
  );
}

void _testMalformedYamlRejected() {
  final root = Directory.systemTemp.createTempSync('ssh_mobile_telem_');
  _tempRoot = root;
  _writeSkeleton(root);
  // Missing version field.
  File(
    '${root.path}/contracts/telemetry/events.yaml',
  ).writeAsStringSync('events: []\n');
  var threw = false;
  try {
    loadContract(root);
  } on FormatException {
    threw = true;
  }
  _expect(threw, 'missing version should throw FormatException');

  // Missing errorCodes list.
  File(
    '${root.path}/contracts/telemetry/error_codes.yaml',
  ).writeAsStringSync('version: "1.0.0"\n');
  threw = false;
  try {
    loadContract(root);
  } on FormatException {
    threw = true;
  }
  _expect(threw, 'malformed errorCodes should throw FormatException');
  // Deletion is handled by [_cleanupTempDirs] after main completes.
}

void _testUnsupportedPropertyTypeRejected() {
  final root = Directory.systemTemp.createTempSync('ssh_mobile_telem_type_');
  _tempRoot = root;
  _writeSkeleton(root);
  final events = File('${root.path}/contracts/telemetry/events.yaml');
  events.writeAsStringSync(
    events.readAsStringSync().replaceFirst('type: "string"', 'type: "object"'),
  );
  var threw = false;
  try {
    loadContract(root);
  } on FormatException {
    threw = true;
  }
  _expect(threw, 'unsupported property type should throw FormatException');
}

// Helpers mirror private generator functions for shape verification.
String _eventConstantNameForTest(String name) {
  final segments = name
      .split(RegExp(r'[._]'))
      .where((s) => s.isNotEmpty)
      .toList();
  var result = segments.first.toLowerCase();
  for (final seg in segments.skip(1)) {
    result += seg.isEmpty
        ? ''
        : seg[0].toUpperCase() + seg.substring(1).toLowerCase();
  }
  if (result.isNotEmpty && '_0123456789'.contains(result[0])) {
    result = 'e$result';
  }
  return result;
}

String _errorCodeConstantNameForTest(String code) {
  final segments = code.split('_').where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return 'eCode';
  var result = segments.first.toLowerCase();
  for (final seg in segments.skip(1)) {
    result += seg.isEmpty
        ? ''
        : seg[0].toUpperCase() + seg.substring(1).toLowerCase();
  }
  if (result.isNotEmpty && '_0123456789'.contains(result[0])) {
    result = 'e$result';
  }
  return result;
}

Directory? _tempRoot;

Directory _repoRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    _expect(parent.path != dir.path, 'repo root should be found');
    dir = parent;
  }
  return dir;
}

void _writeSkeleton(Directory root) {
  final eventsFile = File('${root.path}/contracts/telemetry/events.yaml');
  eventsFile.createSync(recursive: true);
  eventsFile.writeAsStringSync(
    'version: "1.0.0"\nevents:\n'
    '  - name: "app.lifecycle.started"\n'
    '    version: 1\n'
    '    recordType: "analytics"\n'
    '    feature: "app"\n'
    '    severity: "info"\n'
    '    operationGroup: "app.lifecycle"\n'
    '    operationRole: "started"\n'
    '    businessOperation: false\n'
    '    description: "d"\n'
    '    allowedProperties:\n'
    '      - name: "start_type"\n'
    '        type: "string"\n'
    '        required: false\n',
  );
  final errorFile = File('${root.path}/contracts/telemetry/error_codes.yaml');
  errorFile.createSync(recursive: true);
  errorFile.writeAsStringSync(
    'version: "1.0.0"\nerrorCodes:\n'
    '  - code: "NET_QUIC_CONN_REFUSED"\n'
    '    category: "network"\n'
    '    terminalFailure: false\n'
    '    description: "d"\n',
  );
}

void _cleanupTempDirs() {
  final root = _tempRoot;
  _tempRoot = null;
  if (root != null && root.existsSync()) {
    root.deleteSync(recursive: true);
  }
}

void _expect(bool? condition, String message) {
  if (condition != true) throw StateError(message);
}
