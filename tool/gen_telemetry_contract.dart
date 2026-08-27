/// Generates `contracts/telemetry/events.json`, `error_codes.json`, and the
/// Dart constant catalogs under
/// `packages/core/app_core/lib/src/telemetry/generated/` from the YAML source
/// of truth.
///
/// Usage:
///   dart run tool/gen_telemetry_contract.dart
///
/// Regenerates all four output files in place, writing only changed files.
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
    required this.description,
    required this.allowedProperties,
    required this.requiredProperties,
  });

  final String name;
  final int version;
  final String recordType;
  final String feature;
  final String severity;
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
];

/// Loads both YAML sources of truth. Throws [FormatException] on malformed or
/// missing input.
LoadedContract loadContract(Directory repoRoot) {
  final eventsDoc = _loadYamlFile(File('${repoRoot.path}/$_eventsYamlPath'));
  final errorCodesDoc =
      _loadYamlFile(File('${repoRoot.path}/$_errorCodesYamlPath'));
  return LoadedContract(
    eventsVersion: _scalarVersion(eventsDoc, _eventsYamlPath),
    errorCodesVersion: _scalarVersion(errorCodesDoc, _errorCodesYamlPath),
    events: _parseEvents(eventsDoc),
    errorCodes: _parseErrorCodes(errorCodesDoc),
  );
}

/// Renders the four generated artifacts for [contract].
Map<String, String> renderAll(LoadedContract contract) {
  return <String, String>{
    _eventsJsonPath: _renderEventsJson(contract),
    _errorCodesJsonPath: _renderErrorCodesJson(contract),
    _dartEventsPath: _renderEventsDart(contract.events),
    _dartErrorCodesPath: _renderErrorCodesDart(contract.errorCodes),
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
      stderr.writeln('Could not locate repo root from ${Directory.current.path}');
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
  return rawEvents.map((raw) {
    final ev = raw as Map;
    final allowedProperties = ev['allowedProperties'] as YamlList? ?? const [];
    final requiredPropertyNames = allowedProperties
        .whereType<Map>()
        .where((p) => p['required'] == true)
        .map((p) => p['name'] as String)
        .toList();
    return EventDef(
      name: ev['name'] as String,
      version: ev['version'] as int,
      recordType: ev['recordType'] as String,
      feature: ev['feature'] as String,
      severity: ev['severity'] as String,
      description: ev['description'] as String? ?? '',
      allowedProperties: allowedProperties
          .map((p) => Map<String, dynamic>.from(p as Map))
          .toList(),
      requiredProperties: requiredPropertyNames,
    );
  }).toList();
}

List<ErrorCodeDef> _parseErrorCodes(dynamic doc) {
  final rawCodes = (doc as Map)['errorCodes'];
  if (rawCodes is! YamlList) {
    throw const FormatException('error_codes.yaml must declare a `errorCodes` list');
  }
  return rawCodes.map((raw) {
    final ec = raw as Map;
    return ErrorCodeDef(
      code: ec['code'] as String,
      category: ec['category'] as String,
      terminalFailure: ec['terminalFailure'] == true,
      description: ec['description'] as String? ?? '',
    );
  }).toList();
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
      ..write('    allowedProperties: $propertySetLiteral,\n')
      ..write('    requiredProperties: $requiredSetLiteral,\n')
      ..write('  );\n')
      ..writeln();
  }
  buf.write('}\n');
  return buf.toString();
}

String _renderErrorCodesDart(List<ErrorCodeDef> errorCodes) {
  final buf = StringBuffer()
    ..writeln('$generatedHeader')
    ..writeln('$generatedIgnoreFile')
    ..writeln('//')
    ..writeln('/// Compile-time error-code catalog constants generated from')
    ..writeln('/// `contracts/telemetry/error_codes.yaml`. Pure data, no logic.')
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
      ..write('  );\n')
      ..writeln();
  }
  buf.write('}\n');
  return buf.toString();
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