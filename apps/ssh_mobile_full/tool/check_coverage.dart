import 'dart:io';

import 'coverage_sources.dart';

export 'coverage_sources.dart';

const _requiredSourceMinimum = 90.0;

void main(List<String> arguments) {
  var minimum = 0.0;
  final coveragePaths = <String>[];
  final includePrefixes = <String>[];
  final sourceManifestPaths = <String>[];
  final sourceRoots = <String>[];
  String? baseRef;
  var allSources = false;
  var showDetails = false;

  for (final argument in arguments) {
    if (argument.startsWith('--minimum=')) {
      minimum = double.parse(argument.substring('--minimum='.length));
    } else if (argument.startsWith('--file=')) {
      coveragePaths.add(argument.substring('--file='.length));
    } else if (argument.startsWith('--include=')) {
      includePrefixes.add(argument.substring('--include='.length));
    } else if (argument.startsWith('--source-manifest=')) {
      sourceManifestPaths.add(argument.substring('--source-manifest='.length));
    } else if (argument.startsWith('--source-root=')) {
      sourceRoots.add(argument.substring('--source-root='.length));
    } else if (argument.startsWith('--base-ref=')) {
      baseRef = argument.substring('--base-ref='.length);
    } else if (argument == '--all-sources') {
      allSources = true;
    } else if (argument == '--details') {
      showDetails = true;
    } else {
      stderr.writeln('Unknown argument: $argument');
      exitCode = 64;
      return;
    }
  }

  if (allSources && sourceRoots.isEmpty) {
    stderr.writeln('--all-sources requires at least one --source-root.');
    exitCode = 64;
    return;
  }

  final requiredSources = <String>{};
  try {
    for (final manifestPath in sourceManifestPaths) {
      requiredSources.addAll(
        filterHandWrittenProductionSources(
          readSourceManifest(manifestPath),
          sourceRoots: sourceRoots,
          includePrefixes: includePrefixes,
        ),
      );
    }
    if (sourceRoots.isNotEmpty) {
      final resolvedBaseRef = allSources
          ? null
          : resolveCoverageBaseRef(explicitBaseRef: baseRef);
      requiredSources.addAll(
        discoverProductionSources(
          sourceRoots: sourceRoots,
          baseRef: resolvedBaseRef,
          includePrefixes: includePrefixes,
        ),
      );
    }
  } on Object catch (error) {
    stderr.writeln('Unable to discover required coverage sources: $error');
    exitCode = 69;
    return;
  }

  final paths = coveragePaths.isEmpty
      ? <String>['coverage/lcov.info']
      : coveragePaths;
  for (final path in paths) {
    if (!File(path).existsSync()) {
      stderr.writeln('Coverage file not found: $path');
      exitCode = 66;
      return;
    }
  }

  final summary = summarizeLcovFiles(
    paths.map((path) => File(path).readAsLinesSync()),
    includePrefixes: includePrefixes,
    requiredSources: requiredSources,
  );
  if (summary.linesFound == 0) {
    stderr.writeln('Coverage file contains no coverable lines.');
    exitCode = 65;
    return;
  }

  stdout.writeln(
    'Line coverage: ${summary.percentage.toStringAsFixed(1)}% '
    '(${summary.linesHit}/${summary.linesFound}, generated files excluded'
    '${includePrefixes.isEmpty ? '' : ', scoped to ${includePrefixes.join(', ')}'})',
  );

  if (summary.requiredSourceCoverage.isNotEmpty) {
    stdout.writeln(
      'Required hand-written production sources checked: '
      '${summary.requiredSourceCoverage.length}',
    );
  }

  if (showDetails || summary.percentage + 0.000001 < minimum) {
    for (final entry in summary.uncoveredLinesBySource.entries) {
      stdout.writeln('Uncovered ${entry.key}: ${entry.value.join(', ')}');
    }
  }

  final aggregateFailed = summary.percentage + 0.000001 < minimum;
  var failed = aggregateFailed;
  var requiredSourceFailed = false;
  for (final entry in summary.requiredSourceCoverage.entries) {
    final source = entry.key;
    final coverage = entry.value;
    if (coverage.linesFound == 0) {
      stderr.writeln('Required source is missing from LCOV: $source');
      failed = true;
      requiredSourceFailed = true;
    } else if (coverage.percentage + 0.000001 < _requiredSourceMinimum) {
      stderr.writeln(
        'Coverage for required source $source is below the required '
        '${_requiredSourceMinimum.toStringAsFixed(1)}% '
        '(${coverage.linesHit}/${coverage.linesFound}).',
      );
      failed = true;
      requiredSourceFailed = true;
    } else if (showDetails) {
      stdout.writeln(
        'Required source $source: '
        '${coverage.percentage.toStringAsFixed(1)}% '
        '(${coverage.linesHit}/${coverage.linesFound})',
      );
    }
  }

  if (failed) {
    if (aggregateFailed) {
      stderr.writeln(
        'Coverage is below the required ${minimum.toStringAsFixed(1)}%.',
      );
    }
    if (requiredSourceFailed) {
      stderr.writeln('Required source coverage check failed.');
    }
    exitCode = 1;
  }
}

CoverageSummary summarizeLcov(
  Iterable<String> lines, {
  Iterable<String> includePrefixes = const <String>[],
  Iterable<String> requiredSources = const <String>[],
}) {
  return summarizeLcovFiles(
    [lines],
    includePrefixes: includePrefixes,
    requiredSources: requiredSources,
  );
}

CoverageSummary summarizeLcovFiles(
  Iterable<Iterable<String>> files, {
  Iterable<String> includePrefixes = const <String>[],
  Iterable<String> requiredSources = const <String>[],
}) {
  final foundLines = <String, Set<int>>{};
  final hitLines = <String, Set<int>>{};
  final normalizedPrefixes = includePrefixes
      .map(_normalizeCoveragePath)
      .where((prefix) => prefix.isNotEmpty)
      .toList(growable: false);

  for (final lines in files) {
    String? currentSource;
    var skipCurrentFile = false;

    for (final line in lines) {
      if (line.startsWith('SF:')) {
        final source = line.substring(3).replaceAll('\\', '/');
        currentSource = source;
        skipCurrentFile =
            _isGeneratedCoverageSource(source) ||
            source.startsWith('third_party/') ||
            source.contains('/third_party/') ||
            (normalizedPrefixes.isNotEmpty &&
                !normalizedPrefixes.any(
                  (prefix) => _coveragePathMatches(source, prefix),
                ));
      } else if (line == 'end_of_record') {
        currentSource = null;
        skipCurrentFile = false;
      } else if (!skipCurrentFile && line.startsWith('DA:')) {
        final fields = line.substring(3).split(',');
        if (fields.length < 2) {
          continue;
        }

        final lineNumber = int.tryParse(fields[0]);
        final executionCount = int.tryParse(fields[1]);
        final source = currentSource;
        if (source == null || lineNumber == null || executionCount == null) {
          continue;
        }

        foundLines.putIfAbsent(source, () => <int>{}).add(lineNumber);
        if (executionCount > 0) {
          hitLines.putIfAbsent(source, () => <int>{}).add(lineNumber);
        }
      }
    }
  }

  var linesFound = 0;
  for (final sourceLines in foundLines.values) {
    linesFound += sourceLines.length;
  }

  var linesHit = 0;
  for (final sourceLines in hitLines.values) {
    linesHit += sourceLines.length;
  }

  final uncoveredLinesBySource = <String, List<int>>{};
  for (final entry in foundLines.entries) {
    final uncovered =
        entry.value.difference(hitLines[entry.key] ?? <int>{}).toList()..sort();
    if (uncovered.isNotEmpty) {
      uncoveredLinesBySource[entry.key] = List<int>.unmodifiable(uncovered);
    }
  }

  final requiredSourceCoverage = <String, FileCoverage>{};
  final missingRequiredSources = <String>[];
  final normalizedRequiredSources =
      requiredSources
          .map(_normalizeCoveragePath)
          .where((source) => source.isNotEmpty)
          .where(
            (source) =>
                normalizedPrefixes.isEmpty ||
                normalizedPrefixes.any(
                  (prefix) => _coveragePathMatches(source, prefix),
                ),
          )
          .toSet()
          .toList()
        ..sort();
  for (final requiredSource in normalizedRequiredSources) {
    final requiredFoundLines = <int>{};
    final requiredHitLines = <int>{};
    for (final entry in foundLines.entries) {
      if (!_coveragePathMatchesFile(entry.key, requiredSource)) {
        continue;
      }
      requiredFoundLines.addAll(entry.value);
      requiredHitLines.addAll(hitLines[entry.key] ?? <int>{});
    }
    final coverage = FileCoverage(
      linesFound: requiredFoundLines.length,
      linesHit: requiredHitLines.length,
    );
    requiredSourceCoverage[requiredSource] = coverage;
    if (coverage.linesFound == 0) {
      missingRequiredSources.add(requiredSource);
    }
  }

  return CoverageSummary(
    linesFound: linesFound,
    linesHit: linesHit,
    uncoveredLinesBySource: Map<String, List<int>>.unmodifiable(
      uncoveredLinesBySource,
    ),
    requiredSourceCoverage: Map<String, FileCoverage>.unmodifiable(
      requiredSourceCoverage,
    ),
    missingRequiredSources: List<String>.unmodifiable(missingRequiredSources),
  );
}

String _normalizeCoveragePath(String path) {
  return path.replaceAll('\\', '/').replaceFirst(RegExp(r'^\./'), '');
}

bool _coveragePathMatches(String source, String prefix) {
  final normalizedSource = _normalizeCoveragePath(source);
  final normalizedPrefix = prefix.replaceFirst(RegExp(r'/+$'), '');
  return normalizedSource == normalizedPrefix ||
      normalizedSource.startsWith('$normalizedPrefix/') ||
      normalizedSource.contains('/$normalizedPrefix/');
}

bool _coveragePathMatchesFile(String source, String expected) {
  final normalizedSource = _normalizeCoveragePath(source);
  final normalizedExpected = _normalizeCoveragePath(expected);
  return normalizedSource == normalizedExpected ||
      normalizedSource.endsWith('/$normalizedExpected');
}

bool _isGeneratedCoverageSource(String source) {
  final normalized = _normalizeCoveragePath(source);
  final fileName = normalized.split('/').last;
  return normalized.split('/').contains('generated') ||
      fileName.endsWith('.g.dart') ||
      fileName.endsWith('.freezed.dart') ||
      fileName.endsWith('.mocks.dart') ||
      fileName.endsWith('.gen.dart') ||
      fileName.endsWith('.generated.dart');
}

class FileCoverage {
  const FileCoverage({required this.linesFound, required this.linesHit});

  final int linesFound;
  final int linesHit;

  double get percentage => linesFound == 0 ? 0 : (linesHit * 100) / linesFound;
}

class CoverageSummary {
  const CoverageSummary({
    required this.linesFound,
    required this.linesHit,
    this.uncoveredLinesBySource = const <String, List<int>>{},
    this.requiredSourceCoverage = const <String, FileCoverage>{},
    this.missingRequiredSources = const <String>[],
  });

  final int linesFound;
  final int linesHit;
  final Map<String, List<int>> uncoveredLinesBySource;
  final Map<String, FileCoverage> requiredSourceCoverage;
  final List<String> missingRequiredSources;

  double get percentage => linesFound == 0 ? 0 : (linesHit * 100) / linesFound;
}
