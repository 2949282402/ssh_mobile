import 'dart:collection';
import 'dart:io';

/// The source texts that make up the three Network V2 contract views.
///
/// Rust and Dart keep a small stable entrypoint and split their protocol
/// declarations by responsibility. The parity checker must inspect the files
/// reachable from those entrypoints, rather than treating the entrypoints as
/// if they contained the declarations inline.
final class NetworkV2ContractSources {
  const NetworkV2ContractSources({
    required this.protoContent,
    required this.rustContent,
    required this.dartContent,
    required this.rustSourcePaths,
    required this.dartSourcePaths,
  });

  final String protoContent;
  final String rustContent;
  final String dartContent;
  final List<String> rustSourcePaths;
  final List<String> dartSourcePaths;
}

/// Loads the canonical schema and every source module reachable from its
/// hand-written Rust and Dart protocol entrypoints.
NetworkV2ContractSources loadNetworkV2ContractSources(
  Directory repositoryRoot,
) {
  final root = repositoryRoot.absolute;
  final protoPath = 'protocol/proto/network/v2/network.proto';
  final rustEntrypoint =
      'native/network_core/crates/network-protocol/src/lib.rs';
  final dartEntrypoint =
      'apps/ssh_mobile_full/lib/services/network/network_protocol_v2_codec.dart';

  final protoContent = _readRequiredFile(root, protoPath);
  final rustSources = _loadRustSources(root, rustEntrypoint);
  final dartSources = _loadDartSources(root, dartEntrypoint);
  return NetworkV2ContractSources(
    protoContent: protoContent,
    rustContent: _combineSources(rustSources),
    dartContent: _combineSources(dartSources),
    rustSourcePaths: List<String>.unmodifiable(
      rustSources.map((source) => source.relativePath),
    ),
    dartSourcePaths: List<String>.unmodifiable(
      dartSources.map((source) => source.relativePath),
    ),
  );
}

List<_LoadedSource> _loadRustSources(Directory root, String entrypoint) {
  final entryFile = File(_join(root.path, entrypoint));
  final loaded = LinkedHashMap<String, _LoadedSource>();

  void visit(File file, String relativePath) {
    final source = _readRequiredFile(root, relativePath);
    final key = file.absolute.path;
    if (loaded.containsKey(key)) return;
    loaded[key] = _LoadedSource(relativePath, source);

    for (final declaration in _rustFileModuleDeclarations(source)) {
      if (declaration.isTestOnly) continue;
      final child = _resolveRustModule(root, file.parent, declaration.name);
      visit(child.file, child.relativePath);
    }
  }

  visit(entryFile, entrypoint);
  return loaded.values.toList(growable: false);
}

List<_RustModuleDeclaration> _rustFileModuleDeclarations(String source) {
  final declarations = <_RustModuleDeclaration>[];
  final pattern = RegExp(
    r'^\s*(?:pub\s+)?mod\s+([A-Za-z0-9_]+)\s*;',
    multiLine: true,
  );
  for (final match in pattern.allMatches(source)) {
    final name = match.group(1)!;
    declarations.add(
      _RustModuleDeclaration(
        name: name,
        isTestOnly: _isTestOnlyRustModule(source, match.start, name),
      ),
    );
  }
  return declarations;
}

bool _isTestOnlyRustModule(String source, int declarationStart, String name) {
  if (name == 'tests') return true;
  final preceding = source.substring(0, declarationStart).trimRight();
  final lines = preceding.split('\n');
  for (var index = lines.length - 1; index >= 0; index--) {
    final line = lines[index].trim();
    if (!line.startsWith('#[')) break;
    if (line.contains('cfg(test)')) return true;
  }
  return false;
}

_ResolvedSourceFile _resolveRustModule(
  Directory root,
  Directory parent,
  String name,
) {
  final flat = File(_join(parent.path, '$name.rs'));
  if (flat.existsSync()) {
    return _ResolvedSourceFile(flat, _relativeToRoot(root, flat));
  }

  final nested = File(_join(_join(parent.path, name), 'mod.rs'));
  if (nested.existsSync()) {
    return _ResolvedSourceFile(nested, _relativeToRoot(root, nested));
  }

  throw StateError(
    'Rust protocol module "$name" declared by ${parent.path} was not found.',
  );
}

List<_LoadedSource> _loadDartSources(Directory root, String entrypoint) {
  final entryFile = File(_join(root.path, entrypoint));
  final loaded = LinkedHashMap<String, _LoadedSource>();
  final visiting = <String>{};

  void visit(File file) {
    final key = file.absolute.path;
    if (!visiting.add(key)) {
      throw StateError('Dart protocol part cycle detected at ${file.path}.');
    }
    if (loaded.containsKey(key)) {
      visiting.remove(key);
      return;
    }

    final relativePath = _relativeToRoot(root, file);
    final source = _readRequiredFile(root, relativePath);
    loaded[key] = _LoadedSource(relativePath, source);
    for (final partPath in _dartPartPaths(source)) {
      visit(File(_join(file.parent.path, partPath)));
    }

    visiting.remove(key);
  }

  visit(entryFile);
  return loaded.values.toList(growable: false);
}

Iterable<String> _dartPartPaths(String source) sync* {
  final pattern = RegExp(
    r'''^\s*part\s+['"]([^'"]+)['"]\s*;''',
    multiLine: true,
  );
  for (final match in pattern.allMatches(source)) {
    yield match.group(1)!;
  }
}

String _readRequiredFile(Directory root, String relativePath) {
  final file = File(_join(root.path, relativePath));
  if (!file.existsSync()) {
    throw StateError('Required Network V2 source is missing: $relativePath');
  }
  return file.readAsStringSync();
}

String _combineSources(Iterable<_LoadedSource> sources) => sources
    .map(
      (source) =>
          '// Network V2 source: ${source.relativePath}\n${source.content}',
    )
    .join('\n');

String _join(String parent, String child) =>
    '$parent${Platform.pathSeparator}${child.replaceAll('/', Platform.pathSeparator)}';

String _relativeToRoot(Directory root, File file) {
  final rootPath = _normalise(root.absolute.path);
  final path = _normalise(file.absolute.path);
  final relative = path.startsWith('$rootPath/')
      ? path.substring(rootPath.length + 1)
      : path;
  return _collapsePath(relative);
}

String _normalise(String path) => path.replaceAll('\\', '/');

String _collapsePath(String path) {
  final segments = <String>[];
  for (final segment in path.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (segments.isNotEmpty && segments.last != '..') {
        segments.removeLast();
      } else {
        segments.add(segment);
      }
      continue;
    }
    segments.add(segment);
  }
  return segments.join('/');
}

final class _LoadedSource {
  const _LoadedSource(this.relativePath, this.content);

  final String relativePath;
  final String content;
}

final class _RustModuleDeclaration {
  const _RustModuleDeclaration({required this.name, required this.isTestOnly});

  final String name;
  final bool isTestOnly;
}

final class _ResolvedSourceFile {
  const _ResolvedSourceFile(this.file, this.relativePath);

  final File file;
  final String relativePath;
}
