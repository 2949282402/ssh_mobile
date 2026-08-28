// Telemetry contract artifact renderers.
//
// This part keeps the source-of-truth parser and CLI entrypoint small while
// retaining one shared render pipeline for the generator and drift checker.

part of 'gen_telemetry_contract.dart';

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
          'businessOperation': ev.businessOperation,
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
      ..write('    businessOperation: ${ev.businessOperation},\n')
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
    ..writeln(
      '\tBusinessOperation bool              `json:"businessOperation"`',
    )
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
      ..writeln('\t\tName:              ${_jsonQuote(ev.name)},')
      ..writeln('\t\tVersion:           ${ev.version},')
      ..writeln('\t\tRecordType:        ${_jsonQuote(ev.recordType)},')
      ..writeln('\t\tFeature:           ${_jsonQuote(ev.feature)},')
      ..writeln('\t\tSeverity:          ${_jsonQuote(ev.severity)},')
      ..writeln('\t\tOperationGroup:    ${_jsonQuote(ev.operationGroup)},')
      ..writeln('\t\tOperationRole:     ${_jsonQuote(ev.operationRole)},')
      ..writeln('\t\tBusinessOperation: ${ev.businessOperation},')
      ..writeln('\t\tDescription:       ${_jsonQuote(ev.description)},')
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
    ..writeln('  readonly businessOperation: boolean;')
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
      ..writeln('    businessOperation: ${ev.businessOperation},')
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
