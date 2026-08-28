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

part 'gen_telemetry_contract_renderers.dart';

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
    required this.businessOperation,
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
  final bool businessOperation;
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
      businessOperation: _requiredBool(raw, 'businessOperation', 'event'),
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

bool _requiredBool(Map raw, String key, String kind) {
  final value = raw[key];
  if (value is! bool) {
    throw FormatException('$kind must declare boolean `$key`');
  }
  return value;
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
