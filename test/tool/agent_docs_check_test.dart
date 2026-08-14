import 'dart:io';

import '../../tool/check_agent_docs.dart';

void main() {
  _testMarkdownParserBoundaries();
  _testValidFixturePasses();
  _testRequiredFilesAndEdges();
  _testMemoryMapRequiresRealFeatureLinks();
  _testMemoryTopology();
  _testLocalLinkResolution();
  _testRetiredReferenceAllowlist();
  _testRetiredPhysicalPaths();
  _testPathSpecificDateMarkers();
  _testDefaultProfilesAndLimits();
  _testCurrentRepositoryPasses();
  stdout.writeln('Agent documentation checker tests passed.');
}

void _testMarkdownParserBoundaries() {
  final references = parseMarkdownReferences(r'''
[inline](one.md)
![image](image.png)
[definition]: <two file.md> "title"
`[ignored](inline-code.md)` [balanced](three(a).md "title")
```text
[ignored](fenced.md)
```
[escaped](four\(x\).md)
''');
  _expect(
    references.map((item) => item.destination).toList().join('|') ==
        'one.md|image.png|two file.md|three(a).md|four(x).md',
    'Markdown parser should handle links, images, definitions, balanced '
    'parentheses, escapes, inline code, and fenced code.',
  );
  _expect(
    references.map((item) => item.line).toList().join(',') == '1,2,3,4,8',
    'Markdown parser should report stable one-based line numbers.',
  );
}

void _testValidFixturePasses() {
  _withFixture((root) {
    final report = _audit(root);
    _expect(
      report.isValid,
      'Valid Agent docs fixture failed:\n${_issues(report)}',
    );
    _expect(
      report.scannedMarkdownFiles >= 25,
      'Fixture should scan maintained Markdown.',
    );
  });
}

void _testRequiredFilesAndEdges() {
  _withFixture((root) {
    _file(root, _validationPath).deleteSync();
    final report = _audit(root);
    _expectRule(report, 'required-file', path: _validationPath);
  });

  _withFixture((root) {
    _write(
      root,
      'AGENTS.md',
      _englishDoc(
        '# Bootstrap\n\n'
        '[Skill](.agents/skills/ssh-mobile-maintenance/SKILL.md)\n'
        '[Map](.agents/skills/ssh-mobile-maintenance/references/memory-map.md)\n',
      ),
    );
    final report = _audit(root);
    _expectRule(report, 'required-reference', path: 'AGENTS.md');
  });

  _withFixture((root) {
    _file(root, 'memory_docs/client/features/ai.md').deleteSync();
    final report = _audit(root);
    _expectRule(
      report,
      'required-file',
      path: 'memory_docs/client/features/ai.md',
    );
    _expectRule(report, 'markdown-link', path: _memoryMapPath);
  });
}

void _testMemoryMapRequiresRealFeatureLinks() {
  _withFixture((root) {
    final file = _file(root, _memoryMapPath);
    final text = file.readAsStringSync();
    file.writeAsStringSync(
      text
          .split('\n')
          .where((line) => !line.contains('client/features/mcp.md'))
          .join('\n'),
    );
    final report = _audit(root);
    _expectRule(report, 'memory-map-reference', path: _memoryMapPath);
  });
}

void _testMemoryTopology() {
  _withFixture((root) {
    _write(root, 'memory_docs/unknown/overview.md', _englishDoc('# Unknown\n'));
    _write(root, 'memory_docs/loose.md', _englishDoc('# Loose\n'));
    _write(root, 'memory_docs/backend/random.md', _englishDoc('# Random\n'));
    _write(
      root,
      'memory_docs/client/features/nested/value.md',
      _englishDoc('# Nested\n'),
    );
    final report = _audit(root);
    _expectRule(report, 'memory-layout', path: 'memory_docs/unknown');
    _expectRule(report, 'memory-layout', path: 'memory_docs/loose.md');
    _expectRule(report, 'memory-layout', path: 'memory_docs/backend/random.md');
    _expectRule(
      report,
      'memory-layout',
      path: 'memory_docs/client/features/nested',
    );
  });

  _withFixture((root) {
    _file(root, 'memory_docs/front/overview.md').deleteSync();
    final report = _audit(root);
    _expectRule(report, 'memory-empty-domain', path: 'memory_docs/front');
  });
}

void _testLocalLinkResolution() {
  _withFixture((root) {
    _write(root, 'docs/target.md', '# Target\n');
    _write(root, 'docs/target file.md', '# Space\n');
    _write(root, 'docs/target(x).md', '# Parentheses\n');
    _write(root, 'docs/网络设计.md', '# Unicode\n');
    _write(root, 'docs/valid-links.md', r'''
# Valid links

[plain](target.md)
[fragment](target.md#section)
[encoded](target%20file.md)
[angle](<target file.md>)
[parentheses](target(x).md)
[unicode](网络设计.md)
[external](https://example.com/path)
[anchor](#section)
[reference]: target.md
''');
    var report = _audit(root);
    _expect(
      !report.violations.any(
        (item) =>
            item.path == 'docs/valid-links.md' &&
            <String>{
              'markdown-link',
              'markdown-link-case',
              'machine-local-link',
              'link-outside-repository',
            }.contains(item.rule),
      ),
      'Portable valid links should pass:\n${_issues(report)}',
    );

    _write(root, 'docs/invalid-links.md', r'''
# Invalid links

[missing](missing.md)
[case](Target.md)
[file](file:///tmp/value)
[drive](C:/temp/value.md)
[unc](\\server\share\value.md)
[posix](/tmp/value.md)
[escape](../../outside.md)
[percent](bad%ZZ.md)
[encoded-absolute](%2Ftmp/value.md)
''');
    report = _audit(root);
    _expectRule(report, 'markdown-link', path: 'docs/invalid-links.md');
    _expectRule(report, 'markdown-link-case', path: 'docs/invalid-links.md');
    _expectRule(report, 'machine-local-link', path: 'docs/invalid-links.md');
    _expectRule(
      report,
      'link-outside-repository',
      path: 'docs/invalid-links.md',
    );

    _write(
      root,
      'docs/protocol-relative.md',
      '# Invalid absolute link\n\n[absolute](//server/share.md)\n',
    );
    report = _audit(root);
    _expectRule(
      report,
      'machine-local-link',
      path: 'docs/protocol-relative.md',
    );
  });
}

void _testRetiredReferenceAllowlist() {
  _withFixture((root) {
    final report = _audit(root);
    _expect(
      !report.violations.any((item) => item.rule == 'retired-reference'),
      'Historical audit allowlist should be exact and sufficient.',
    );

    _append(
      root,
      'memory_docs/README.md',
      '\nDo not restore AGENT_MEMORY.md.\n',
    );
    final changed = _audit(root);
    _expectRule(changed, 'retired-reference', path: 'memory_docs/README.md');
  });

  _withFixture((root) {
    _append(
      root,
      'docs/architecture/MODULAR_REFACTOR_PLAN.md',
      '\n`.workbuddy/memory/old.md`\n',
    );
    final report = _audit(root);
    _expectRule(
      report,
      'retired-reference',
      path: 'docs/architecture/MODULAR_REFACTOR_PLAN.md',
    );
  });
}

void _testRetiredPhysicalPaths() {
  _withFixture((root) {
    _write(root, 'AGENT_MEMORY.md', '# Retired\n');
    final report = _audit(root);
    _expectRule(report, 'retired-file', path: 'AGENT_MEMORY.md');
  });

  _withFixture((root) {
    _write(root, '.workbuddy/memory/old.md', '# Retired\n');
    final report = _audit(root);
    _expectRule(report, 'retired-file', path: '.workbuddy/memory');
  });
}

void _testPathSpecificDateMarkers() {
  _withFixture((root) {
    _write(
      root,
      'memory_docs/front/overview.md',
      '最新更新时间：2026-08-13\n\n# Front\n',
    );
    final report = _audit(root);
    _expectRule(report, 'document-date', path: 'memory_docs/front/overview.md');
  });

  _withFixture((root) {
    _write(
      root,
      _maintenancePath,
      '> Last updated: 2026-08-13\n\n# Governance\n',
    );
    final report = _audit(root);
    _expectRule(report, 'document-date', path: _maintenancePath);
  });

  _withFixture((root) {
    _write(
      root,
      'memory_docs/front/overview.md',
      '# Front\n\n> Last updated: 2026-08-13\n',
    );
    _write(
      root,
      'memory_docs/backend/overview.md',
      '> Last updated: 2026-02-30\n\n# Backend\n',
    );
    final report = _audit(root);
    _expectRule(report, 'document-date', path: 'memory_docs/front/overview.md');
    _expectRule(
      report,
      'document-date',
      path: 'memory_docs/backend/overview.md',
    );
  });
}

void _testDefaultProfilesAndLimits() {
  _withFixture((root) {
    var report = _audit(root);
    final codex = _profile(report, 'Codex');
    final claude = _profile(report, 'Claude');
    _expect(
      codex.bytesByPath.containsKey(_workflowPath),
      'Codex default profile must include workflow.md.',
    );
    _expect(
      claude.bytesByPath.containsKey(_workflowPath),
      'Claude default profile must include workflow.md.',
    );

    final claudeFile = _file(root, 'CLAUDE.md');
    final padding = maxDefaultAgentContextBytes - claude.totalBytes;
    _expect(padding >= 0, 'Base Claude fixture should fit its profile budget.');
    claudeFile.writeAsStringSync(
      '${claudeFile.readAsStringSync()}${'x' * padding}',
    );
    report = _audit(root);
    _expect(
      _profile(report, 'Claude').totalBytes == maxDefaultAgentContextBytes,
      'Claude profile should allow exactly 40960 normalized UTF-8 bytes.',
    );
    _expect(
      !report.violations.any(
        (item) => item.rule == 'default-context-size' && item.path == 'Claude',
      ),
      'Exact Claude limit should pass.',
    );
    claudeFile.writeAsStringSync('x', mode: FileMode.append);
    report = _audit(root);
    _expectRule(report, 'default-context-size', path: 'Claude');
  });

  _withFixture((root) {
    final base = _audit(root);
    final codex = _profile(base, 'Codex');
    final workflow = _file(root, _workflowPath);
    final padding = maxDefaultAgentContextBytes - codex.totalBytes + 1;
    workflow.writeAsStringSync(
      '${workflow.readAsStringSync()}${'y' * padding}',
    );
    final report = _audit(root);
    _expectRule(report, 'default-context-size', path: 'Codex');
  });
}

void _testCurrentRepositoryPasses() {
  final report = AgentDocAuditor(repositoryRoot: Directory.current).audit();
  _expect(
    report.isValid,
    'Current repository should pass Agent docs guard:\n${_issues(report)}',
  );
}

void _withFixture(void Function(Directory root) body) {
  final root = Directory.systemTemp.createTempSync('ssh_mobile_agent_docs_');
  try {
    _createValidFixture(root);
    body(root);
  } finally {
    root.deleteSync(recursive: true);
  }
}

void _createValidFixture(Directory root) {
  _write(
    root,
    'AGENTS.md',
    _englishDoc(
      '# Repository Bootstrap\n\n'
      '[Skill](.agents/skills/ssh-mobile-maintenance/SKILL.md)\n'
      '[Memory Map](.agents/skills/ssh-mobile-maintenance/references/memory-map.md)\n'
      '[Maintenance](docs/agent/skill-memory-maintenance.md)\n',
    ),
  );
  _write(
    root,
    'CLAUDE.md',
    _englishDoc(
      '# Claude Bootstrap\n\n'
      '[Repository](AGENTS.md)\n'
      '[Skill](.agents/skills/ssh-mobile-maintenance/SKILL.md)\n'
      '[Memory Map](.agents/skills/ssh-mobile-maintenance/references/memory-map.md)\n',
    ),
  );

  final skill =
      '''
---
name: ssh-mobile-maintenance
description: Fixture maintenance skill.
---

> Last updated: 2026-08-13

# Maintenance Skill

Canonical references:

- `docs/agent/skill-memory-maintenance.md`
- `.agents/skills/ssh-mobile-maintenance/references/memory-map.md`
- `.agents/skills/ssh-mobile-maintenance/references/workflow.md`
- `.agents/skills/ssh-mobile-maintenance/references/validation.md`
'''
          .trimLeft();
  _write(root, _canonicalSkillPath, skill);

  final mapLinks = _selectedMemoryPaths
      .map((path) => '- [$path](../../../../$path)')
      .join('\n');
  _write(root, _memoryMapPath, _englishDoc('# Memory Map\n\n$mapLinks\n'));
  _write(
    root,
    _workflowPath,
    _englishDoc('# Workflow\n\n[Memory Map](memory-map.md)\n'),
  );
  _write(root, _validationPath, _englishDoc('# Validation\n'));

  _write(root, _maintenancePath, _chineseDoc('# Skill 与 Memory 维护规范\n'));
  _write(
    root,
    _auditPath,
    _chineseDoc(
      '# 迁移审计\n\n'
      '`AGENT_MEMORY.md`、`.workbuddy/memory/2026-07-24.md` 和 '
      '`docs/agent/Skill & Memory Maintenance.md` 是迁移前路径。\n',
    ),
  );
  _write(
    root,
    'docs/architecture/MODULAR_REFACTOR_PLAN.md',
    '# Historical architecture record\n\n`AGENT_MEMORY.md` was synchronized.\n',
  );

  _write(
    root,
    'memory_docs/README.md',
    _englishDoc(
      '# Project Memory\n\n'
      '[Memory Map](../.agents/skills/ssh-mobile-maintenance/references/memory-map.md)\n'
      '[Maintenance](../docs/agent/skill-memory-maintenance.md)\n',
    ),
  );
  for (final path in _selectedMemoryPaths) {
    _write(root, path, _englishDoc('# ${path.split('/').last}\n'));
  }
}

AgentDocReport _audit(Directory root) {
  return AgentDocAuditor(repositoryRoot: root).audit();
}

AgentDocProfileSize _profile(AgentDocReport report, String name) {
  return report.defaultProfiles.singleWhere((profile) => profile.name == name);
}

String _englishDoc(String body) {
  return '> Last updated: 2026-08-13\n\n$body';
}

String _chineseDoc(String body) {
  return '最新更新时间：2026-08-13\n\n$body';
}

void _write(Directory root, String relativePath, String content) {
  final file = _file(root, relativePath)..createSync(recursive: true);
  file.writeAsStringSync(content);
}

void _append(Directory root, String relativePath, String content) {
  _file(root, relativePath).writeAsStringSync(content, mode: FileMode.append);
}

File _file(Directory root, String relativePath) {
  return File(
    '${root.path}${Platform.pathSeparator}'
    '${relativePath.replaceAll('/', Platform.pathSeparator)}',
  );
}

void _expectRule(AgentDocReport report, String rule, {String? path}) {
  _expect(
    report.violations.any(
      (item) => item.rule == rule && (path == null || item.path == path),
    ),
    'Expected [$rule]${path == null ? '' : ' $path'}; got:\n${_issues(report)}',
  );
}

String _issues(AgentDocReport report) => report.violations.join('\n');

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

const _canonicalSkillPath = '.agents/skills/ssh-mobile-maintenance/SKILL.md';
const _memoryMapPath =
    '.agents/skills/ssh-mobile-maintenance/references/memory-map.md';
const _workflowPath =
    '.agents/skills/ssh-mobile-maintenance/references/workflow.md';
const _validationPath =
    '.agents/skills/ssh-mobile-maintenance/references/validation.md';
const _maintenancePath = 'docs/agent/skill-memory-maintenance.md';
const _auditPath = 'docs/agent/skill-memory-refactor-audit.md';

const _selectedMemoryPaths = <String>[
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
];
