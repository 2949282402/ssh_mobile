import 'dart:convert';
import 'dart:io';

const maxDefaultAgentContextBytes = 40 * 1024;

const allowedMemoryDomains = <String>{'front', 'backend', 'client', 'sdk'};

const _canonicalSkill = '.agents/skills/ssh-mobile-maintenance/SKILL.md';
const _memoryMap =
    '.agents/skills/ssh-mobile-maintenance/references/memory-map.md';
const _workflow =
    '.agents/skills/ssh-mobile-maintenance/references/workflow.md';
const _validation =
    '.agents/skills/ssh-mobile-maintenance/references/validation.md';
const _maintenanceDocument = 'docs/agent/skill-memory-maintenance.md';
const _migrationAudit = 'docs/agent/skill-memory-refactor-audit.md';
const _memoryReadme = 'memory_docs/README.md';

const _requiredFiles = <String>{
  'AGENTS.md',
  'CLAUDE.md',
  _canonicalSkill,
  _memoryMap,
  _workflow,
  _validation,
  _maintenanceDocument,
  _migrationAudit,
  _memoryReadme,
  'memory_docs/client/overview.md',
  'memory_docs/client/architecture.md',
  'memory_docs/client/current-state.md',
  'memory_docs/client/lessons.md',
  'memory_docs/client/features/ai.md',
  'memory_docs/client/features/sftp.md',
  'memory_docs/client/features/lan-share.md',
  'memory_docs/client/features/mcp.md',
  'memory_docs/sdk/overview.md',
  'memory_docs/sdk/architecture.md',
  'memory_docs/sdk/current-state.md',
  'memory_docs/sdk/lessons.md',
  'memory_docs/sdk/features/transport-routing.md',
  'memory_docs/backend/overview.md',
  'memory_docs/backend/current-state.md',
  'memory_docs/front/overview.md',
};

const _retiredPhysicalPaths = <String>{
  'AGENT_MEMORY.md',
  '.workbuddy/memory',
  'docs/agent/Skill & Memory Maintenance.md',
};

const _historicalReferenceAllowlist = <String, Set<String>>{
  'docs/architecture/MODULAR_REFACTOR_PLAN.md': <String>{'legacy-agent-memory'},
  _migrationAudit: <String>{
    'legacy-agent-memory',
    'legacy-workbuddy-memory',
    'legacy-governance-name',
  },
};

const _defaultProfiles = <String, List<String>>{
  'Codex': <String>['AGENTS.md', _canonicalSkill, _memoryMap, _workflow],
  'Claude': <String>['CLAUDE.md', 'AGENTS.md', _memoryMap, _workflow],
};

const _requiredReferences = <_RequiredReference>[
  _RequiredReference('AGENTS.md', _canonicalSkill),
  _RequiredReference('AGENTS.md', _memoryMap),
  _RequiredReference('AGENTS.md', _maintenanceDocument),
  _RequiredReference('CLAUDE.md', 'AGENTS.md'),
  _RequiredReference(_canonicalSkill, _maintenanceDocument),
  _RequiredReference(_canonicalSkill, _memoryMap),
  _RequiredReference(_canonicalSkill, _workflow),
  _RequiredReference(_canonicalSkill, _validation),
  _RequiredReference(_memoryReadme, _maintenanceDocument),
  _RequiredReference(_memoryReadme, _memoryMap),
];

const _requiredMemoryMapTargets = <String>{
  'memory_docs/client/overview.md',
  'memory_docs/client/architecture.md',
  'memory_docs/client/current-state.md',
  'memory_docs/client/lessons.md',
  'memory_docs/client/features/ai.md',
  'memory_docs/client/features/sftp.md',
  'memory_docs/client/features/lan-share.md',
  'memory_docs/client/features/mcp.md',
  'memory_docs/sdk/overview.md',
  'memory_docs/sdk/architecture.md',
  'memory_docs/sdk/current-state.md',
  'memory_docs/sdk/lessons.md',
  'memory_docs/sdk/features/transport-routing.md',
  'memory_docs/backend/overview.md',
  'memory_docs/backend/current-state.md',
  'memory_docs/front/overview.md',
};

final class AgentDocViolation {
  const AgentDocViolation({
    required this.rule,
    required this.path,
    required this.line,
    required this.message,
  });

  final String rule;
  final String path;
  final int line;
  final String message;

  @override
  String toString() => '[$rule] $path:$line $message';
}

final class MarkdownReference {
  const MarkdownReference({required this.destination, required this.line});

  final String destination;
  final int line;
}

final class AgentDocProfileSize {
  const AgentDocProfileSize({required this.name, required this.bytesByPath});

  final String name;
  final Map<String, int> bytesByPath;

  int get totalBytes => bytesByPath.values.fold(0, (sum, value) => sum + value);
}

final class AgentDocReport {
  const AgentDocReport({
    required this.scannedMarkdownFiles,
    required this.defaultProfiles,
    required this.violations,
  });

  final int scannedMarkdownFiles;
  final List<AgentDocProfileSize> defaultProfiles;
  final List<AgentDocViolation> violations;

  bool get isValid => violations.isEmpty;
}

final class AgentDocAuditor {
  AgentDocAuditor({required this.repositoryRoot});

  final Directory repositoryRoot;

  late _RepositoryIndex _index;
  final Map<String, String?> _textCache = <String, String?>{};
  final Set<String> _reportedReadErrors = <String>{};

  AgentDocReport audit() {
    _textCache.clear();
    _reportedReadErrors.clear();
    _index = _buildRepositoryIndex(repositoryRoot.absolute);

    final violations = <AgentDocViolation>[];
    _checkRequiredAndRetiredPaths(violations);
    _checkMemoryTopology(violations);

    final markdownPaths =
        _index.files
            .where((path) => path.toLowerCase().endsWith('.md'))
            .toList(growable: false)
          ..sort();
    _checkMarkdownLinks(markdownPaths, violations);
    _checkRequiredReferenceEdges(violations);
    _checkMemoryMapTargets(violations);
    _checkDateMarkers(markdownPaths, violations);
    _checkRetiredReferences(markdownPaths, violations);
    final profiles = _checkDefaultProfileSizes(violations);

    violations.sort((left, right) {
      final path = left.path.compareTo(right.path);
      if (path != 0) return path;
      final line = left.line.compareTo(right.line);
      if (line != 0) return line;
      final rule = left.rule.compareTo(right.rule);
      if (rule != 0) return rule;
      return left.message.compareTo(right.message);
    });

    return AgentDocReport(
      scannedMarkdownFiles: markdownPaths.length,
      defaultProfiles: List<AgentDocProfileSize>.unmodifiable(profiles),
      violations: List<AgentDocViolation>.unmodifiable(violations),
    );
  }

  void _checkRequiredAndRetiredPaths(List<AgentDocViolation> violations) {
    for (final path in _requiredFiles) {
      if (!_index.files.contains(path)) {
        violations.add(
          AgentDocViolation(
            rule: 'required-file',
            path: path,
            line: 1,
            message: 'Required Agent documentation entry is missing.',
          ),
        );
      }
    }

    for (final path in _retiredPhysicalPaths) {
      if (_index.files.contains(path) || _index.directories.contains(path)) {
        violations.add(
          AgentDocViolation(
            rule: 'retired-file',
            path: path,
            line: 1,
            message: 'Retired Agent knowledge path must not be restored.',
          ),
        );
      }
    }
  }

  void _checkMemoryTopology(List<AgentDocViolation> violations) {
    for (final domain in allowedMemoryDomains) {
      final directory = 'memory_docs/$domain';
      if (!_index.directories.contains(directory)) {
        violations.add(
          AgentDocViolation(
            rule: 'memory-domain',
            path: directory,
            line: 1,
            message: 'Required Memory Domain directory is missing.',
          ),
        );
        continue;
      }
      final prefix = '$directory/';
      final markdownCount = _index.files.where((path) {
        return path.startsWith(prefix) && path.endsWith('.md');
      }).length;
      if (markdownCount == 0) {
        violations.add(
          AgentDocViolation(
            rule: 'memory-empty-domain',
            path: directory,
            line: 1,
            message: 'A Memory Domain must contain at least one real document.',
          ),
        );
      }
    }

    for (final directory in _index.directories) {
      if (!directory.startsWith('memory_docs/')) continue;
      final segments = directory.split('/');
      final valid =
          segments.length == 2 && allowedMemoryDomains.contains(segments[1]) ||
          segments.length == 3 &&
              allowedMemoryDomains.contains(segments[1]) &&
              segments[2] == 'features';
      if (!valid) {
        violations.add(
          AgentDocViolation(
            rule: 'memory-layout',
            path: directory,
            line: 1,
            message: 'Unexpected directory in the fixed Memory topology.',
          ),
        );
      }
    }

    for (final path in _index.files) {
      if (!path.startsWith('memory_docs/')) continue;
      if (path == _memoryReadme) continue;
      final segments = path.split('/');
      var valid = false;
      if (segments.length == 3 && allowedMemoryDomains.contains(segments[1])) {
        valid = const <String>{
          'overview.md',
          'architecture.md',
          'current-state.md',
          'lessons.md',
        }.contains(segments[2]);
      } else if (segments.length == 4 &&
          allowedMemoryDomains.contains(segments[1]) &&
          segments[2] == 'features') {
        valid = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*\.md$').hasMatch(segments[3]);
      }
      if (!valid) {
        violations.add(
          AgentDocViolation(
            rule: 'memory-layout',
            path: path,
            line: 1,
            message: 'Unexpected file in the fixed Memory topology.',
          ),
        );
      }
    }
  }

  void _checkMarkdownLinks(
    List<String> markdownPaths,
    List<AgentDocViolation> violations,
  ) {
    for (final source in markdownPaths) {
      final text = _readText(source, violations);
      if (text == null) continue;
      for (final reference in parseMarkdownReferences(text)) {
        final resolution = _resolveDestination(
          source: source,
          destination: reference.destination,
        );
        if (resolution.kind == _DestinationKind.invalid) {
          violations.add(
            AgentDocViolation(
              rule: resolution.rule!,
              path: source,
              line: reference.line,
              message: resolution.message!,
            ),
          );
        }
      }
    }
  }

  void _checkRequiredReferenceEdges(List<AgentDocViolation> violations) {
    for (final edge in _requiredReferences) {
      final text = _readText(edge.source, violations);
      if (text == null) continue;
      var found = false;
      for (final reference in parseMarkdownReferences(text)) {
        final resolution = _resolveDestination(
          source: edge.source,
          destination: reference.destination,
        );
        if (resolution.kind == _DestinationKind.local &&
            resolution.path == edge.target) {
          found = true;
          break;
        }
      }
      found = found || _containsPathToken(text, edge.target);
      if (!found) {
        violations.add(
          AgentDocViolation(
            rule: 'required-reference',
            path: edge.source,
            line: 1,
            message: 'Missing required reference to ${edge.target}.',
          ),
        );
      }
    }
  }

  void _checkMemoryMapTargets(List<AgentDocViolation> violations) {
    final text = _readText(_memoryMap, violations);
    if (text == null) return;
    final linkedTargets = <String>{};
    for (final reference in parseMarkdownReferences(text)) {
      final resolution = _resolveDestination(
        source: _memoryMap,
        destination: reference.destination,
      );
      if (resolution.kind == _DestinationKind.local &&
          resolution.path != null) {
        linkedTargets.add(resolution.path!);
      }
    }
    for (final target in _requiredMemoryMapTargets) {
      if (!linkedTargets.contains(target)) {
        violations.add(
          AgentDocViolation(
            rule: 'memory-map-reference',
            path: _memoryMap,
            line: 1,
            message: 'Memory Map must link to selected Memory: $target.',
          ),
        );
      }
    }
  }

  void _checkDateMarkers(
    List<String> markdownPaths,
    List<AgentDocViolation> violations,
  ) {
    for (final path in markdownPaths.where(_requiresDateMarker)) {
      final text = _readText(path, violations);
      if (text == null) continue;
      final lines = const LineSplitter().convert(text);
      var index = 0;
      if (lines.isNotEmpty && lines.first.trim() == '---') {
        index = 1;
        while (index < lines.length && lines[index].trim() != '---') {
          index++;
        }
        if (index == lines.length) {
          violations.add(
            AgentDocViolation(
              rule: 'document-date',
              path: path,
              line: 1,
              message: 'Unclosed YAML front matter precedes the date marker.',
            ),
          );
          continue;
        }
        index++;
      }
      while (index < lines.length && lines[index].trim().isEmpty) {
        index++;
      }
      final marker = index < lines.length ? lines[index].trim() : '';
      final prefix = path.startsWith('docs/agent/')
          ? '最新更新时间：'
          : 'Last updated:';
      final match = RegExp(
        '^(?:>\\s*)?${RegExp.escape(prefix)}\\s*'
        r'(\d{4})-(\d{2})-(\d{2})$',
      ).firstMatch(marker);
      if (match == null || !_isValidDate(match)) {
        violations.add(
          AgentDocViolation(
            rule: 'document-date',
            path: path,
            line: index + 1,
            message:
                'The first content after front matter must use $prefix with a valid date.',
          ),
        );
      }
    }
  }

  void _checkRetiredReferences(
    List<String> markdownPaths,
    List<AgentDocViolation> violations,
  ) {
    const patterns = <String, String>{
      'legacy-agent-memory': r'\bAGENT_MEMORY(?:\.md)?\b',
      'legacy-workbuddy-memory': r'\.workbuddy/memory/',
      'legacy-governance-name': r'docs/agent/Skill & Memory Maintenance\.md',
    };
    for (final path in markdownPaths) {
      final text = _readText(path, violations);
      if (text == null) continue;
      final allowed = _historicalReferenceAllowlist[path] ?? const <String>{};
      final lines = const LineSplitter().convert(text);
      for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
        for (final entry in patterns.entries) {
          if (allowed.contains(entry.key)) continue;
          if (RegExp(entry.value).hasMatch(lines[lineIndex])) {
            violations.add(
              AgentDocViolation(
                rule: 'retired-reference',
                path: path,
                line: lineIndex + 1,
                message: 'Retired reference is not allowed (${entry.key}).',
              ),
            );
          }
        }
      }
    }
  }

  List<AgentDocProfileSize> _checkDefaultProfileSizes(
    List<AgentDocViolation> violations,
  ) {
    final profiles = <AgentDocProfileSize>[];
    for (final entry in _defaultProfiles.entries) {
      final bytesByPath = <String, int>{};
      for (final path in entry.value) {
        final text = _readText(path, violations);
        if (text != null) {
          bytesByPath[path] = normalizedUtf8ByteLength(text);
        }
      }
      final profile = AgentDocProfileSize(
        name: entry.key,
        bytesByPath: Map<String, int>.unmodifiable(bytesByPath),
      );
      profiles.add(profile);
      if (profile.totalBytes > maxDefaultAgentContextBytes) {
        violations.add(
          AgentDocViolation(
            rule: 'default-context-size',
            path: entry.key,
            line: 1,
            message:
                '${entry.key} default profile is ${profile.totalBytes} bytes; limit is $maxDefaultAgentContextBytes.',
          ),
        );
      }
    }
    return profiles;
  }

  String? _readText(String relativePath, List<AgentDocViolation> violations) {
    if (_textCache.containsKey(relativePath)) return _textCache[relativePath];
    if (!_index.files.contains(relativePath)) {
      _textCache[relativePath] = null;
      return null;
    }
    try {
      final value = _file(relativePath).readAsStringSync();
      _textCache[relativePath] = value;
      return value;
    } on FileSystemException catch (error) {
      if (_reportedReadErrors.add(relativePath)) {
        violations.add(
          AgentDocViolation(
            rule: 'document-read',
            path: relativePath,
            line: 1,
            message: 'Cannot read UTF-8 document: ${error.message}',
          ),
        );
      }
      _textCache[relativePath] = null;
      return null;
    } on FormatException catch (error) {
      if (_reportedReadErrors.add(relativePath)) {
        violations.add(
          AgentDocViolation(
            rule: 'document-read',
            path: relativePath,
            line: 1,
            message: 'Document is not valid UTF-8: ${error.message}',
          ),
        );
      }
      _textCache[relativePath] = null;
      return null;
    }
  }

  File _file(String relativePath) => File(
    '${repositoryRoot.absolute.path}${Platform.pathSeparator}'
    '${relativePath.replaceAll('/', Platform.pathSeparator)}',
  );

  _DestinationResolution _resolveDestination({
    required String source,
    required String destination,
  }) {
    var value = destination.trim();
    if (value.isEmpty || value.startsWith('#') || value.startsWith('?')) {
      return const _DestinationResolution.skipped();
    }
    if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) || value.startsWith(r'\\')) {
      return const _DestinationResolution.invalid(
        rule: 'machine-local-link',
        message: 'Windows drive and UNC links are not repository-portable.',
      );
    }
    final scheme = RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*):').firstMatch(value);
    if (scheme != null) {
      if (scheme.group(1)!.toLowerCase() == 'file') {
        return const _DestinationResolution.invalid(
          rule: 'machine-local-link',
          message: 'file: links are machine-local and forbidden.',
        );
      }
      return const _DestinationResolution.external();
    }
    if (value.startsWith('/') || value.contains('\\')) {
      return const _DestinationResolution.invalid(
        rule: 'machine-local-link',
        message:
            'Local links must use repository-relative forward-slash paths.',
      );
    }

    final query = value.indexOf('?');
    final fragment = value.indexOf('#');
    var cut = value.length;
    if (query >= 0 && query < cut) cut = query;
    if (fragment >= 0 && fragment < cut) cut = fragment;
    value = value.substring(0, cut);
    if (value.isEmpty) return const _DestinationResolution.skipped();
    try {
      value = _decodePercentEscapes(value);
    } on FormatException {
      return const _DestinationResolution.invalid(
        rule: 'markdown-link',
        message: 'Link destination has invalid percent encoding.',
      );
    }
    if (value.contains('\u0000')) {
      return const _DestinationResolution.invalid(
        rule: 'markdown-link',
        message: 'Link destination contains a NUL character.',
      );
    }
    if (value.startsWith('/') ||
        value.contains('\\') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value)) {
      return const _DestinationResolution.invalid(
        rule: 'machine-local-link',
        message:
            'Decoded local link is not a portable repository-relative path.',
      );
    }

    final sourceSegments = source.split('/')..removeLast();
    for (final segment in value.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (sourceSegments.isEmpty) {
          return const _DestinationResolution.invalid(
            rule: 'link-outside-repository',
            message: 'Local link escapes the repository root.',
          );
        }
        sourceSegments.removeLast();
      } else {
        sourceSegments.add(segment);
      }
    }
    final target = sourceSegments.join('/');
    if (_index.files.contains(target) || _index.directories.contains(target)) {
      return _DestinationResolution.local(target);
    }
    final caseMatches = _index.caseInsensitive[target.toLowerCase()];
    if (caseMatches != null && caseMatches.isNotEmpty) {
      return _DestinationResolution.invalid(
        rule: 'markdown-link-case',
        message: 'Local link casing differs from ${caseMatches.first}.',
      );
    }
    return _DestinationResolution.invalid(
      rule: 'markdown-link',
      message: 'Local link target does not exist: $target.',
    );
  }
}

List<MarkdownReference> parseMarkdownReferences(String markdown) {
  final references = <MarkdownReference>[];
  final lines = const LineSplitter().convert(markdown);
  _Fence? fence;
  for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    final line = lines[lineIndex];
    final marker = _fenceMarker(line);
    if (fence != null) {
      if (marker != null &&
          marker.character == fence.character &&
          marker.length >= fence.length &&
          marker.trailing.trim().isEmpty) {
        fence = null;
      }
      continue;
    }
    if (marker != null) {
      fence = marker;
      continue;
    }

    final mask = _inlineCodeMask(line);
    final definition = RegExp(r'^ {0,3}\[[^\]]+\]:\s*').firstMatch(line);
    if (definition != null) {
      final parsed = _readDefinitionDestination(line, definition.end, mask);
      if (parsed != null && parsed.destination.isNotEmpty) {
        references.add(
          MarkdownReference(
            destination: parsed.destination,
            line: lineIndex + 1,
          ),
        );
      }
    }

    var bracketDepth = 0;
    var index = 0;
    while (index < line.length) {
      if (mask[index] || _isEscaped(line, index)) {
        index++;
        continue;
      }
      final character = line[index];
      if (character == '[') {
        bracketDepth++;
        index++;
        continue;
      }
      if (character != ']' || bracketDepth == 0) {
        index++;
        continue;
      }
      bracketDepth--;
      var opening = index + 1;
      while (opening < line.length &&
          (line[opening] == ' ' || line[opening] == '\t')) {
        opening++;
      }
      if (opening >= line.length || line[opening] != '(') {
        index++;
        continue;
      }
      final parsed = _readInlineDestination(line, opening + 1, mask);
      if (parsed != null) {
        references.add(
          MarkdownReference(
            destination: parsed.destination,
            line: lineIndex + 1,
          ),
        );
        index = parsed.endIndex + 1;
      } else {
        index++;
      }
    }
  }
  return List<MarkdownReference>.unmodifiable(references);
}

int normalizedUtf8ByteLength(String text) {
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return utf8.encode(normalized).length;
}

_ParsedDestination? _readDefinitionDestination(
  String line,
  int offset,
  List<bool> mask,
) {
  var index = offset;
  while (index < line.length && (line[index] == ' ' || line[index] == '\t')) {
    index++;
  }
  if (index >= line.length || mask[index]) return null;
  if (line[index] == '<') {
    final buffer = StringBuffer();
    index++;
    while (index < line.length) {
      if (!mask[index] && line[index] == '>' && !_isEscaped(line, index)) {
        return _ParsedDestination(
          _unescapeDestination(buffer.toString()),
          index,
        );
      }
      buffer.write(line[index]);
      index++;
    }
    return null;
  }
  final buffer = StringBuffer();
  while (index < line.length &&
      !mask[index] &&
      line[index] != ' ' &&
      line[index] != '\t') {
    buffer.write(line[index]);
    index++;
  }
  return _ParsedDestination(_unescapeDestination(buffer.toString()), index);
}

_ParsedDestination? _readInlineDestination(
  String line,
  int offset,
  List<bool> mask,
) {
  var index = offset;
  while (index < line.length && (line[index] == ' ' || line[index] == '\t')) {
    index++;
  }
  if (index >= line.length || mask[index]) return null;

  if (line[index] == '<') {
    final buffer = StringBuffer();
    index++;
    while (index < line.length) {
      if (!mask[index] && line[index] == '>' && !_isEscaped(line, index)) {
        final close = _readDestinationTail(line, index + 1, mask);
        return close == null
            ? null
            : _ParsedDestination(
                _unescapeDestination(buffer.toString()),
                close,
              );
      }
      buffer.write(line[index]);
      index++;
    }
    return null;
  }

  final buffer = StringBuffer();
  var parenthesisDepth = 0;
  while (index < line.length && !mask[index]) {
    final character = line[index];
    if (character == '\\' && index + 1 < line.length) {
      buffer
        ..write(character)
        ..write(line[index + 1]);
      index += 2;
      continue;
    }
    if (character == '(') {
      parenthesisDepth++;
      buffer.write(character);
      index++;
      continue;
    }
    if (character == ')') {
      if (parenthesisDepth == 0) {
        return _ParsedDestination(
          _unescapeDestination(buffer.toString()),
          index,
        );
      }
      parenthesisDepth--;
      buffer.write(character);
      index++;
      continue;
    }
    if ((character == ' ' || character == '\t') && parenthesisDepth == 0) {
      final close = _readDestinationTail(line, index, mask);
      return close == null
          ? null
          : _ParsedDestination(_unescapeDestination(buffer.toString()), close);
    }
    buffer.write(character);
    index++;
  }
  return null;
}

int? _readDestinationTail(String line, int offset, List<bool> mask) {
  var index = offset;
  while (index < line.length && (line[index] == ' ' || line[index] == '\t')) {
    index++;
  }
  if (index >= line.length || mask[index]) return null;
  if (line[index] == ')') return index;

  final opener = line[index];
  final closer = opener == '(' ? ')' : opener;
  if (opener != '(' && opener != '\'' && opener != '"') return null;
  var depth = opener == '(' ? 1 : 0;
  index++;
  while (index < line.length) {
    if (mask[index]) return null;
    if (_isEscaped(line, index)) {
      index++;
      continue;
    }
    if (opener == '(' && line[index] == '(') {
      depth++;
    } else if (line[index] == closer) {
      if (opener == '(') {
        depth--;
        if (depth == 0) {
          index++;
          break;
        }
      } else {
        index++;
        break;
      }
    }
    index++;
  }
  while (index < line.length && (line[index] == ' ' || line[index] == '\t')) {
    index++;
  }
  return index < line.length && line[index] == ')' ? index : null;
}

List<bool> _inlineCodeMask(String line) {
  final mask = List<bool>.filled(line.length, false);
  var index = 0;
  while (index < line.length) {
    if (line[index] != '`' || _isEscaped(line, index)) {
      index++;
      continue;
    }
    final start = index;
    while (index < line.length && line[index] == '`') {
      index++;
    }
    final runLength = index - start;
    var close = -1;
    var candidate = index;
    while (candidate < line.length) {
      if (line[candidate] != '`' || _isEscaped(line, candidate)) {
        candidate++;
        continue;
      }
      var end = candidate;
      while (end < line.length && line[end] == '`') {
        end++;
      }
      if (end - candidate == runLength) {
        close = end;
        break;
      }
      candidate = end;
    }
    final maskEnd = close == -1 ? line.length : close;
    for (var position = start; position < maskEnd; position++) {
      mask[position] = true;
    }
    index = maskEnd;
  }
  return mask;
}

_Fence? _fenceMarker(String line) {
  final match = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$').firstMatch(line);
  if (match == null) return null;
  final run = match.group(1)!;
  return _Fence(run[0], run.length, match.group(2)!);
}

bool _isEscaped(String text, int index) {
  var slashCount = 0;
  for (
    var position = index - 1;
    position >= 0 && text[position] == '\\';
    position--
  ) {
    slashCount++;
  }
  return slashCount.isOdd;
}

String _unescapeDestination(String value) {
  return value.replaceAllMapped(
    RegExp(r'''\\([!"#\$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~ \t])'''),
    (match) => match.group(1)!,
  );
}

String _decodePercentEscapes(String value) {
  if (!value.contains('%')) return value;
  final output = StringBuffer();
  var index = 0;
  while (index < value.length) {
    if (value.codeUnitAt(index) != 0x25) {
      output.writeCharCode(value.codeUnitAt(index));
      index++;
      continue;
    }
    final bytes = <int>[];
    while (index < value.length && value.codeUnitAt(index) == 0x25) {
      if (index + 2 >= value.length) {
        throw const FormatException('Incomplete percent escape.');
      }
      final high = _hexValue(value.codeUnitAt(index + 1));
      final low = _hexValue(value.codeUnitAt(index + 2));
      if (high < 0 || low < 0) {
        throw const FormatException('Invalid percent escape.');
      }
      bytes.add((high << 4) | low);
      index += 3;
    }
    output.write(utf8.decode(bytes, allowMalformed: false));
  }
  return output.toString();
}

int _hexValue(int codeUnit) {
  if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit - 0x30;
  if (codeUnit >= 0x41 && codeUnit <= 0x46) return codeUnit - 0x41 + 10;
  if (codeUnit >= 0x61 && codeUnit <= 0x66) return codeUnit - 0x61 + 10;
  return -1;
}

bool _containsPathToken(String text, String target) {
  var start = 0;
  while (true) {
    final index = text.indexOf(target, start);
    if (index < 0) return false;
    final before = index == 0 ? null : text[index - 1];
    final afterIndex = index + target.length;
    final after = afterIndex == text.length ? null : text[afterIndex];
    if (!_isPathTokenCharacter(before) && !_isPathTokenCharacter(after)) {
      return true;
    }
    start = index + target.length;
  }
}

bool _isPathTokenCharacter(String? value) {
  if (value == null) return false;
  return RegExp(r'[A-Za-z0-9_./-]').hasMatch(value);
}

bool _requiresDateMarker(String path) {
  return path == 'AGENTS.md' ||
      path == 'CLAUDE.md' ||
      path == _canonicalSkill ||
      path.startsWith('.agents/skills/ssh-mobile-maintenance/references/') ||
      path.startsWith('docs/agent/') ||
      path.startsWith('memory_docs/');
}

bool _isValidDate(RegExpMatch match) {
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final date = DateTime.utc(year, month, day);
  return date.year == year && date.month == month && date.day == day;
}

_RepositoryIndex _buildRepositoryIndex(Directory root) {
  final files = <String>{};
  final directories = <String>{''};

  void visit(Directory directory) {
    final entities = directory.listSync(followLinks: false)
      ..sort((left, right) => left.path.compareTo(right.path));
    for (final entity in entities) {
      final name = _basename(entity.path);
      if (entity is Directory) {
        if (_ignoredDirectoryNames.contains(name)) continue;
        final path = _relativePath(root.path, entity.path);
        directories.add(path);
        visit(entity);
      } else if (entity is File) {
        files.add(_relativePath(root.path, entity.path));
      }
    }
  }

  visit(root);
  final caseInsensitive = <String, List<String>>{};
  for (final path in <String>{...files, ...directories}) {
    caseInsensitive.putIfAbsent(path.toLowerCase(), () => <String>[]).add(path);
  }
  for (final values in caseInsensitive.values) {
    values.sort();
  }
  return _RepositoryIndex(
    Set<String>.unmodifiable(files),
    Set<String>.unmodifiable(directories),
    Map<String, List<String>>.unmodifiable(caseInsensitive),
  );
}

String _relativePath(String root, String path) {
  final rootValue = root.replaceAll('\\', '/').replaceFirst(RegExp(r'/$'), '');
  final pathValue = path.replaceAll('\\', '/');
  if (pathValue == rootValue) return '';
  if (pathValue.startsWith('$rootValue/')) {
    return pathValue.substring(rootValue.length + 1);
  }
  throw StateError('Path is outside repository root: $path');
}

String _basename(String path) => path.split(RegExp(r'[\\/]')).last;

const _ignoredDirectoryNames = <String>{
  '.git',
  '.dart_tool',
  '.gradle-user-home',
  '.gradle',
  '.idea',
  '.vscode',
  '.claude',
  'build',
  'coverage',
  'node_modules',
  'third_party',
};

final class _RequiredReference {
  const _RequiredReference(this.source, this.target);

  final String source;
  final String target;
}

final class _RepositoryIndex {
  const _RepositoryIndex(this.files, this.directories, this.caseInsensitive);

  final Set<String> files;
  final Set<String> directories;
  final Map<String, List<String>> caseInsensitive;
}

enum _DestinationKind { local, external, skipped, invalid }

final class _DestinationResolution {
  const _DestinationResolution.local(this.path)
    : kind = _DestinationKind.local,
      rule = null,
      message = null;

  const _DestinationResolution.external()
    : kind = _DestinationKind.external,
      path = null,
      rule = null,
      message = null;

  const _DestinationResolution.skipped()
    : kind = _DestinationKind.skipped,
      path = null,
      rule = null,
      message = null;

  const _DestinationResolution.invalid({
    required this.rule,
    required this.message,
  }) : kind = _DestinationKind.invalid,
       path = null;

  final _DestinationKind kind;
  final String? path;
  final String? rule;
  final String? message;
}

final class _ParsedDestination {
  const _ParsedDestination(this.destination, this.endIndex);

  final String destination;
  final int endIndex;
}

final class _Fence {
  const _Fence(this.character, this.length, this.trailing);

  final String character;
  final int length;
  final String trailing;
}

void main() {
  final report = AgentDocAuditor(repositoryRoot: Directory.current).audit();
  stdout.writeln(
    'Agent documentation audit: ${report.scannedMarkdownFiles} Markdown files.',
  );
  for (final profile in report.defaultProfiles) {
    stdout.writeln(
      '${profile.name} default profile: ${profile.totalBytes}/'
      '$maxDefaultAgentContextBytes bytes.',
    );
    for (final entry in profile.bytesByPath.entries) {
      stdout.writeln('  ${entry.key}: ${entry.value}');
    }
  }
  if (report.isValid) {
    stdout.writeln('Agent documentation audit passed.');
    return;
  }
  stderr.writeln(
    'Agent documentation audit failed with '
    '${report.violations.length} violation(s):',
  );
  for (final violation in report.violations) {
    stderr.writeln('  $violation');
  }
  exitCode = 1;
}
