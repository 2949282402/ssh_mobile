/// Generates the cross-language telemetry contract catalogs from the YAML
/// sources of truth. JSON remains a generated interchange artifact; Dart,
/// Go, and TypeScript receive complete typed definitions for their owners.
///
/// Usage:
///   dart run tool/gen_telemetry_contract.dart
///
/// Regenerates all six output files in place, writing only changed files.
///
/// Public API shared with `tool/check_telemetry_contract_generated.dart`:
/// [loadedContract], [renderAll], and [expectedFiles]. The checker reuses the
/// exact same parse + render pipeline so the staleness comparison can never
/// disagree with fresh generation.
library;

import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

const String _eventsYamlPath = 'contracts/telemetry/events.yaml';
const String _errorCodesYamlPath = 'contracts/telemetry/error_codes.yaml';
const String _eventsJsonPath = 'contracts/telemetry/events.json';
const String _errorCodesJsonPath = 'contracts/telemetry/error_codes.json';
const String _dartEventsPath =
    'packages/core/app_core/lib/src/telemetry/generated/telemetry_events.dart';
const String _dartErrorCodesPath =
    'packages/core/app_core/lib/src/telemetry/generated/error_codes.dart';
const String _goContractPath =
    'relay/internal/telemetry/generated/telemetry_contract.go';
const String _tsContractPath = 'front/src/generated/telemetry_contract.ts';

/// Header printed at the top of every generated file.
const String generatedHeader =
    '// GENERATED DO NOT EDIT, regenerate via dart run tool/gen_telemetry_contract.dart';

/// Suppresses lints that are expected in generated, data-only constant files
/// (e.g. PascalCase-derived const names, unnecessary `const` in const
/// contexts, dangling doc comments). Mirrors the established convention used
/// by other generated files in this repo (`// ignore_for_file: type=lint`).
const String generatedIgnoreFile = '// ignore_for_file: type=lint';

/// Parsed telemetry contract source of truth.
class LoadedContract {
  LoadedContract({
    required this.eventsVersion,
    required this.errorCodesVersion,
    required this.events,
    required this.errorCodes,
  });

  final String eventsVersion;
  final String errorCodesVersion;
  final List<EventDef> events;
  final List<ErrorCodeDef> errorCodes;
}

/// Parsed event definition from YAML.
class EventDef {
  EventDef({
    required this.name,
    required this.version,
    required this.recordType,
    required this.feature,
    required this.severity,
    required this.operationGroup,
    required this.operationRole,
    required this.description,
    required this.allowedProperties,
    required this.requiredProperties,
  });

  final String name;
  final int version;
  final String recordType;
  final String feature;
  final String severity;
  final String operationGroup;
  final String operationRole;
  final String description;
  final List<Map<String, dynamic>> allowedProperties;
  final List<String> requiredProperties;
}

/// Parsed error-code definition from YAML.
class ErrorCodeDef {
  ErrorCodeDef({
    required this.code,
    required this.category,
    required this.terminalFailure,
    required this.description,
  });

  final String code;
  final String category;
  final bool terminalFailure;
  final String description;
}

/// Repo-root-relative path of every generated artifact keyed to its absolute
/// output location convention used by the generator.
const List<String> generatedArtifacts = <String>[
  _eventsJsonPath,
  _errorCodesJsonPath,
  _dartEventsPath,
  _dartErrorCodesPath,
  _goContractPath,
  _tsContractPath,
];

/// Loads both YAML sources of truth. Throws [FormatException] on malformed or
/// missing input.
LoadedContract loadContract(Directory repoRoot) {
  final eventsDoc = _loadYamlFile(File('${repoRoot.path}/$_eventsYamlPath'));
  final errorCodesDoc = _loadYamlFile(
    File('${repoRoot.path}/$_errorCodesYamlPath'),
  );
  return LoadedContract(
    eventsVersion: _scalarVersion(eventsDoc, _eventsYamlPath),
    errorCodesVersion: _scalarVersion(errorCodesDoc, _errorCodesYamlPath),
    events: _parseEvents(eventsDoc),
    errorCodes: _parseErrorCodes(errorCodesDoc),
  );
}

/// Renders all generated artifacts for [contract].
Map<String, String> renderAll(LoadedContract contract) {
  return <String, String>{
    _eventsJsonPath: _renderEventsJson(contract),
    _errorCodesJsonPath: _renderErrorCodesJson(contract),
    _dartEventsPath: _renderEventsDart(contract.events),
    _dartErrorCodesPath: _renderErrorCodesDart(contract.errorCodes),
    _goContractPath: _renderContractGo(contract),
    _tsContractPath: _renderContractTypeScript(contract),
  };
}

/// Maps each generated artifact's repo-relative path to its expected content
/// for the current YAML sources of truth under [repoRoot].
Map<String, String> expectedFiles(Directory repoRoot) {
  return renderAll(loadContract(repoRoot));
}

/// Runs the generator: writes any drifted or missing generated artifact and
/// reports per-file status. Returns `true` when every artifact was already
/// current.
Future<bool> runGenerator() async {
  final rootDir = _repoRoot();
  final expected = expectedFiles(rootDir);
  var allCurrent = true;
  for (final entry in expected.entries) {
    final file = File('${rootDir.path}/${entry.key}');
    final updated = await _syncFile(file, entry.value);
    if (updated) {
      stdout.writeln('[updated] ${entry.key}');
      allCurrent = false;
    } else {
      stdout.writeln('[current] ${entry.key}');
    }
  }
  return allCurrent;
}

dynamic _loadYamlFile(File file) {
  if (!file.existsSync()) {
    stderr.writeln('Missing contract source of truth: ${file.path}');
    throw const FormatException('contract yaml missing');
  }
  final doc = loadYaml(file.readAsStringSync());
  if (doc is! Map) {
    throw const FormatException('contract yaml must be a map');
  }
  return doc;
}

/// Resolves the repo root by walking up from the current directory until a
/// `pubspec.yaml` is found.
Directory _repoRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      stderr.writeln(
        'Could not locate repo root from ${Directory.current.path}',
      );
      throw const FormatException('repo root not found');
    }
    dir = parent;
  }
  return dir;
}

/// Reads the scalar `version` field required by both contract YAML sources.
String _scalarVersion(dynamic doc, String path) {
  final version = (doc as Map)['version'];
  if (version is! String || version.isEmpty) {
    throw FormatException('$path must declare a non-empty `version` string');
  }
  return version;
}

List<EventDef> _parseEvents(dynamic doc) {
  final rawEvents = (doc as Map)['events'];
  if (rawEvents is! YamlList) {
    throw const FormatException('events.yaml must declare a `events` list');
  }
  final names = <String>{};
  final identifiers = <String>{};
  return rawEvents.map((raw) {
    if (raw is! Map) {
      throw const FormatException('each telemetry event must be a map');
    }
    final name = _requiredString(raw, 'name', 'event');
    if (!names.add(name)) {
      throw FormatException('duplicate telemetry event name: $name');
    }
    final constantName = _eventConstantName(name);
    if (!identifiers.add(constantName)) {
      throw FormatException(
        'event names collide on generated identifier: $constantName',
      );
    }

    final rawProperties = raw['allowedProperties'];
    if (rawProperties != null && rawProperties is! YamlList) {
      throw FormatException('allowedProperties must be a list for event $name');
    }
    final properties = <Map<String, dynamic>>[];
    final propertyNames = <String>{};
    for (final rawProperty in (rawProperties as YamlList? ?? const [])) {
      if (rawProperty is! Map) {
        throw FormatException('event $name has an invalid property definition');
      }
      final propertyName = _requiredString(rawProperty, 'name', 'property');
      if (!propertyNames.add(propertyName)) {
        throw FormatException(
          'event $name declares duplicate property: $propertyName',
        );
      }
      final propertyType = _requiredString(rawProperty, 'type', 'property');
      final required = rawProperty['required'];
      if (required is! bool) {
        throw FormatException(
          'event $name property $propertyName must declare boolean required',
        );
      }
      properties.add(<String, dynamic>{
        'name': propertyName,
        'type': propertyType,
        'required': required,
      });
    }

    final requiredPropertyNames = properties
        .where((p) => p['required'] == true)
        .map((p) => p['name'] as String)
        .toList();
    return EventDef(
      name: name,
      version: _requiredInt(raw, 'version', 'event'),
      recordType: _requiredString(raw, 'recordType', 'event'),
      feature: _requiredString(raw, 'feature', 'event'),
      severity: _requiredString(raw, 'severity', 'event'),
      operationGroup: _requiredString(raw, 'operationGroup', 'event'),
      operationRole: _requiredString(raw, 'operationRole', 'event'),
      description: raw['description'] as String? ?? '',
      allowedProperties: properties,
      requiredProperties: requiredPropertyNames,
    );
  }).toList();
}

List<ErrorCodeDef> _parseErrorCodes(dynamic doc) {
  final rawCodes = (doc as Map)['errorCodes'];
  if (rawCodes is! YamlList) {
    throw const FormatException(
      'error_codes.yaml must declare a `errorCodes` list',
    );
  }
  final codes = <String>{};
  final identifiers = <String>{};
  return rawCodes.map((raw) {
    if (raw is! Map) {
      throw const FormatException('each telemetry error code must be a map');
    }
    final code = _requiredString(raw, 'code', 'error code');
    if (!codes.add(code)) {
      throw FormatException('duplicate telemetry error code: $code');
    }
    final constantName = _errorCodeConstantName(code);
    if (!identifiers.add(constantName)) {
      throw FormatException(
        'error codes collide on generated identifier: $constantName',
      );
    }
    final terminalFailure = raw['terminalFailure'];
    if (terminalFailure is! bool) {
      throw FormatException(
        'error code $code must declare boolean terminalFailure',
      );
    }
    return ErrorCodeDef(
      code: code,
      category: _requiredString(raw, 'category', 'error code'),
      terminalFailure: terminalFailure,
      description: raw['description'] as String? ?? '',
    );
  }).toList();
}

String _requiredString(Map raw, String key, String kind) {
  final value = raw[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$kind must declare a non-empty `$key` string');
  }
  return value;
}

int _requiredInt(Map raw, String key, String kind) {
  final value = raw[key];
  if (value is! int) {
    throw FormatException('$kind must declare integer `$key`');
  }
  return value;
}

String _renderEventsJson(LoadedContract contract) {
  final doc = <String, dynamic>{
    'version': contract.eventsVersion,
    'events': [
      for (final ev in contract.events)
        <String, dynamic>{
          'name': ev.name,
          'version': ev.version,
          'recordType': ev.recordType,
          'feature': ev.feature,
          'severity': ev.severity,
          'operationGroup': ev.operationGroup,
          'operationRole': ev.operationRole,
          'description': ev.description,
          'allowedProperties': ev.allowedProperties,
        },
    ],
  };
  return '${const JsonEncoder.withIndent('  ').convert(doc)}\n';
}

String _renderErrorCodesJson(LoadedContract contract) {
  final doc = <String, dynamic>{
    'version': contract.errorCodesVersion,
    'errorCodes': [
      for (final ec in contract.errorCodes)
        <String, dynamic>{
          'code': ec.code,
          'category': ec.category,
          'terminalFailure': ec.terminalFailure,
          'description': ec.description,
        },
    ],
  };
  return '${const JsonEncoder.withIndent('  ').convert(doc)}\n';
}

String _renderEventsDart(List<EventDef> events) {
  final buf = StringBuffer()
    ..writeln('$generatedHeader')
    ..writeln('$generatedIgnoreFile')
    ..writeln('//')
    ..writeln('/// Compile-time event catalog constants generated from')
    ..writeln('/// `contracts/telemetry/events.yaml`. Pure data, no logic.')
    ..writeln('///')
    ..writeln("import '../telemetry_model.dart';")
    ..writeln("import '../telemetry_catalog.dart';")
    ..writeln()
    ..writeln('class TelemetryEvents {')
    ..writeln('  const TelemetryEvents._();')
    ..writeln();
  for (final ev in events) {
    final propertyNames =
        ev.allowedProperties.map((p) => p['name'] as String).toList()..sort();
    final requiredNames = (ev.requiredProperties.toList()..sort()).toSet();
    final propertySetLiteral = _setLiteral(propertyNames);
    final requiredSetLiteral = requiredNames.isEmpty
        ? '{}'
        : _setLiteral(requiredNames.toList());
    final constantName = _eventConstantName(ev.name);
    buf
      ..write('  static const $constantName = TelemetryEventDefinition(\n')
      ..write('    name: ${_quote(ev.name)},\n')
      ..write('    version: ${ev.version},\n')
      ..write('    recordType: TelemetryRecordType.${ev.recordType},\n')
      ..write('    feature: ${_quote(ev.feature)},\n')
      ..write('    severity: TelemetrySeverity.${ev.severity},\n')
      ..write('    operationGroup: ${_quote(ev.operationGroup)},\n')
      ..write('    operationRole: ${_quote(ev.operationRole)},\n')
      ..write('    description: ${_quote(ev.description)},\n')
      ..write('    allowedProperties: $propertySetLiteral,\n')
      ..write('    requiredProperties: $requiredSetLiteral,\n')
      ..write(
        '    propertyTypes: ${_propertyTypesLiteral(ev.allowedProperties)},\n',
      )
      ..write('  );\n')
      ..writeln();
  }
  buf
    ..writeln('  static const List<TelemetryEventDefinition> all =')
    ..writeln('      <TelemetryEventDefinition>[');
  for (final ev in events) {
    buf.writeln('    ${_eventConstantName(ev.name)},');
  }
  buf
    ..writeln('  ];')
    ..writeln();
  buf.write('}\n');
  return _formatDart(buf.toString());
}

String _renderErrorCodesDart(List<ErrorCodeDef> errorCodes) {
  final buf = StringBuffer()
    ..writeln('$generatedHeader')
    ..writeln('$generatedIgnoreFile')
    ..writeln('//')
    ..writeln('/// Compile-time error-code catalog constants generated from')
    ..writeln(
      '/// `contracts/telemetry/error_codes.yaml`. Pure data, no logic.',
    )
    ..writeln('///')
    ..writeln("import '../telemetry_catalog.dart';")
    ..writeln()
    ..writeln('class TelemetryErrorCodes {')
    ..writeln('  const TelemetryErrorCodes._();')
    ..writeln();
  for (final ec in errorCodes) {
    final constantName = _errorCodeConstantName(ec.code);
    buf
      ..write('  static const $constantName = TelemetryErrorCodeDefinition(\n')
      ..write('    code: ${_quote(ec.code)},\n')
      ..write('    category: ${_quote(ec.category)},\n')
      ..write('    terminalFailure: ${ec.terminalFailure},\n')
      ..write('    description: ${_quote(ec.description)},\n')
      ..write('  );\n')
      ..writeln();
  }
  buf
    ..writeln('  static const List<TelemetryErrorCodeDefinition> all =')
    ..writeln('      <TelemetryErrorCodeDefinition>[');
  for (final ec in errorCodes) {
    buf.writeln('    ${_errorCodeConstantName(ec.code)},');
  }
  buf
    ..writeln('  ];')
    ..writeln();
  buf.write('}\n');
  return _formatDart(buf.toString());
}

String _propertyTypesLiteral(List<Map<String, dynamic>> properties) {
  if (properties.isEmpty) return '{}';
  final sorted = [...properties]
    ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
  return '{${sorted.map((p) => '${_quote(p['name'] as String)}: ${_quote(p['type'] as String)}').join(', ')}}';
}

String _renderContractGo(LoadedContract contract) {
  final buf = StringBuffer()
    ..writeln(
      '// GENERATED DO NOT EDIT, regenerate via dart run tool/gen_telemetry_contract.dart',
    )
    ..writeln('// Code generated from contracts/telemetry/*.yaml; DO NOT EDIT.')
    ..writeln()
    ..writeln('package generated')
    ..writeln()
    ..writeln('type AllowedProperty struct {')
    ..writeln('\tName     string `json:"name"`')
    ..writeln('\tType     string `json:"type"`')
    ..writeln('\tRequired bool   `json:"required"`')
    ..writeln('}')
    ..writeln()
    ..writeln('type EventDefinition struct {')
    ..writeln('\tName              string            `json:"name"`')
    ..writeln('\tVersion           int               `json:"version"`')
    ..writeln('\tRecordType        string            `json:"recordType"`')
    ..writeln('\tFeature           string            `json:"feature"`')
    ..writeln('\tSeverity          string            `json:"severity"`')
    ..writeln('\tOperationGroup    string            `json:"operationGroup"`')
    ..writeln('\tOperationRole     string            `json:"operationRole"`')
    ..writeln('\tDescription       string            `json:"description"`')
    ..writeln(
      '\tAllowedProperties []AllowedProperty `json:"allowedProperties"`',
    )
    ..writeln('}')
    ..writeln()
    ..writeln('type ErrorCodeDefinition struct {')
    ..writeln('\tCode            string `json:"code"`')
    ..writeln('\tCategory        string `json:"category"`')
    ..writeln('\tTerminalFailure bool   `json:"terminalFailure"`')
    ..writeln('\tDescription     string `json:"description"`')
    ..writeln('}')
    ..writeln()
    ..writeln('var TelemetryEvents = []EventDefinition{');

  for (final ev in contract.events) {
    buf
      ..writeln('\t{')
      ..writeln('\t\tName:           ${_jsonQuote(ev.name)},')
      ..writeln('\t\tVersion:        ${ev.version},')
      ..writeln('\t\tRecordType:     ${_jsonQuote(ev.recordType)},')
      ..writeln('\t\tFeature:        ${_jsonQuote(ev.feature)},')
      ..writeln('\t\tSeverity:       ${_jsonQuote(ev.severity)},')
      ..writeln('\t\tOperationGroup: ${_jsonQuote(ev.operationGroup)},')
      ..writeln('\t\tOperationRole:  ${_jsonQuote(ev.operationRole)},')
      ..writeln('\t\tDescription:    ${_jsonQuote(ev.description)},')
      ..writeln('\t\tAllowedProperties: []AllowedProperty{');
    for (final property in ev.allowedProperties) {
      buf
        ..writeln('\t\t\t{')
        ..writeln(
          '\t\t\t\tName:     ${_jsonQuote(property['name'] as String)},',
        )
        ..writeln(
          '\t\t\t\tType:     ${_jsonQuote(property['type'] as String)},',
        )
        ..writeln('\t\t\t\tRequired: ${property['required'] == true},')
        ..writeln('\t\t\t},');
    }
    buf
      ..writeln('\t\t},')
      ..writeln('\t},');
  }
  buf
    ..writeln('}')
    ..writeln()
    ..writeln('var TelemetryErrorCodes = []ErrorCodeDefinition{');
  for (final ec in contract.errorCodes) {
    buf
      ..writeln('\t{')
      ..writeln('\t\tCode:            ${_jsonQuote(ec.code)},')
      ..writeln('\t\tCategory:        ${_jsonQuote(ec.category)},')
      ..writeln('\t\tTerminalFailure: ${ec.terminalFailure},')
      ..writeln('\t\tDescription:     ${_jsonQuote(ec.description)},')
      ..writeln('\t},');
  }
  buf..writeln('}');
  return buf.toString();
}

String _renderContractTypeScript(LoadedContract contract) {
  final buf = StringBuffer()
    ..writeln(
      '// GENERATED DO NOT EDIT, regenerate via dart run tool/gen_telemetry_contract.dart',
    )
    ..writeln('// Code generated from contracts/telemetry/*.yaml; DO NOT EDIT.')
    ..writeln()
    ..writeln("export type TelemetryRecordType = 'analytics' | 'diagnostic';")
    ..writeln(
      "export type TelemetrySeverity = 'info' | 'warn' | 'error' | 'critical';",
    )
    ..writeln()
    ..writeln('export interface TelemetryPropertyDefinition {')
    ..writeln('  readonly name: string;')
    ..writeln('  readonly type: string;')
    ..writeln('  readonly required: boolean;')
    ..writeln('}')
    ..writeln()
    ..writeln('export interface TelemetryEventDefinition {')
    ..writeln('  readonly name: string;')
    ..writeln('  readonly version: number;')
    ..writeln('  readonly recordType: TelemetryRecordType;')
    ..writeln('  readonly feature: string;')
    ..writeln('  readonly severity: TelemetrySeverity;')
    ..writeln('  readonly operationGroup: string;')
    ..writeln('  readonly operationRole: string;')
    ..writeln('  readonly description: string;')
    ..writeln(
      '  readonly allowedProperties: readonly TelemetryPropertyDefinition[];',
    )
    ..writeln('  readonly requiredProperties: readonly string[];')
    ..writeln('}')
    ..writeln()
    ..writeln('export interface TelemetryErrorCodeDefinition {')
    ..writeln('  readonly code: string;')
    ..writeln('  readonly category: string;')
    ..writeln('  readonly terminalFailure: boolean;')
    ..writeln('  readonly description: string;')
    ..writeln('}')
    ..writeln()
    ..writeln('export class TelemetryEvents {');

  for (final ev in contract.events) {
    final constantName = _eventConstantName(ev.name);
    buf
      ..writeln('  static readonly $constantName: TelemetryEventDefinition = {')
      ..writeln('    name: ${_jsonQuote(ev.name)},')
      ..writeln('    version: ${ev.version},')
      ..writeln('    recordType: ${_jsonQuote(ev.recordType)},')
      ..writeln('    feature: ${_jsonQuote(ev.feature)},')
      ..writeln('    severity: ${_jsonQuote(ev.severity)},')
      ..writeln('    operationGroup: ${_jsonQuote(ev.operationGroup)},')
      ..writeln('    operationRole: ${_jsonQuote(ev.operationRole)},')
      ..writeln('    description: ${_jsonQuote(ev.description)},')
      ..writeln('    allowedProperties: [');
    for (final property in ev.allowedProperties) {
      buf
        ..writeln('      {')
        ..writeln('        name: ${_jsonQuote(property['name'] as String)},')
        ..writeln('        type: ${_jsonQuote(property['type'] as String)},')
        ..writeln('        required: ${property['required'] == true},')
        ..writeln('      },');
    }
    buf
      ..writeln('    ],')
      ..writeln(
        '    requiredProperties: ${_tsStringList(ev.requiredProperties)},',
      )
      ..writeln('  };')
      ..writeln();
  }
  buf
    ..writeln('  static readonly all: readonly TelemetryEventDefinition[] = [');
  for (final ev in contract.events) {
    buf.writeln('    TelemetryEvents.${_eventConstantName(ev.name)},');
  }
  buf
    ..writeln('  ];')
    ..writeln()
    ..writeln('  private constructor() {}')
    ..writeln('}')
    ..writeln()
    ..writeln('export class TelemetryErrorCodes {');
  for (final ec in contract.errorCodes) {
    final constantName = _errorCodeConstantName(ec.code);
    buf
      ..writeln(
        '  static readonly $constantName: TelemetryErrorCodeDefinition = {',
      )
      ..writeln('    code: ${_jsonQuote(ec.code)},')
      ..writeln('    category: ${_jsonQuote(ec.category)},')
      ..writeln('    terminalFailure: ${ec.terminalFailure},')
      ..writeln('    description: ${_jsonQuote(ec.description)},')
      ..writeln('  };')
      ..writeln();
  }
  buf..writeln(
    '  static readonly all: readonly TelemetryErrorCodeDefinition[] = [',
  );
  for (final ec in contract.errorCodes) {
    buf.writeln('    TelemetryErrorCodes.${_errorCodeConstantName(ec.code)},');
  }
  buf
    ..writeln('  ];')
    ..writeln()
    ..writeln('  private constructor() {}')
    ..writeln('}');
  return buf.toString();
}

String _jsonQuote(String value) => jsonEncode(value) as String;

String _tsStringList(List<String> values) {
  if (values.isEmpty) return '[]';
  return '[${values.map(_jsonQuote).join(', ')}]';
}

/// Applies the repository Dart formatter to generated Dart artifacts so the
/// staleness checker and the normal formatting gate agree byte-for-byte.
String _formatDart(String source) {
  // Keep the scratch file under the repository so the formatter discovers the
  // same package/language configuration as the committed generated outputs.
  final tempDir = Directory.current.createTempSync(
    'ssh_mobile_telemetry_codegen_',
  );
  final tempFile = File('${tempDir.path}/generated.dart')
    ..writeAsStringSync(source);
  try {
    final result = Process.runSync(Platform.resolvedExecutable, <String>[
      'format',
      '--output=json',
      tempFile.path,
    ]);
    if (result.exitCode != 0) {
      throw FormatException(
        'dart format failed for generated telemetry output: ${result.stderr}',
      );
    }
    final payload = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    return payload['source'] as String;
  } finally {
    tempDir.deleteSync(recursive: true);
  }
}

/// Renders a Dart const set literal for the given string members.
String _setLiteral(List<String> members) {
  final sorted = [...members]..sort();
  if (sorted.isEmpty) return '{}';
  return '{${sorted.map(_quote).join(', ')}}';
}

/// Derives a Dart lowerCamelCase const identifier for an event name like
/// `ssh.session.started` -> `sshSessionStarted`.
String _eventConstantName(String eventName) {
  final segments = eventName.split(RegExp(r'[._]')).where((s) => s.isNotEmpty);
  return _segmentsToCamel(segments.toList());
}

/// Derives a Dart lowerCamelCase const identifier for an error code like
/// `NET_QUIC_CONN_REFUSED` -> `netQuicConnRefused`.
String _errorCodeConstantName(String code) {
  final segments = code.split('_').where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return 'eCode';
  return _segmentsToCamel(segments);
}

/// Joins identifier segments as lowerCamelCase: the first segment is
/// lowercased, subsequent segments are capitalized. Prefixes `e` when the
/// result would otherwise start with a digit or underscore.
String _segmentsToCamel(List<String> segments) {
  var result = segments.first.toLowerCase();
  for (final seg in segments.skip(1)) {
    final lower = seg.toLowerCase();
    result += _capitalize(lower);
  }
  if (result.isNotEmpty && '_0123456789'.contains(result[0])) {
    result = 'e$result';
  }
  return result;
}

String _capitalize(String value) {
  if (value.isEmpty) return value;
  return value[0].toUpperCase() + value.substring(1);
}

String _quote(String value) => "'$value'";

/// Writes [content] to [file] only when it differs. Creates parent
/// directories as needed. Returns whether the file changed.
Future<bool> _syncFile(File file, String content) async {
  if (file.existsSync() && file.readAsStringSync() == content) {
    return false;
  }
  await file.create(recursive: true);
  await file.writeAsString(content, flush: true);
  return true;
}

Future<void> main() async {
  final allCurrent = await runGenerator();
  if (allCurrent) {
    stdout.writeln('All generated telemetry contract artifacts are current.');
  }
}
