import 'dart:io';

void main(List<String> arguments) {
  var minimum = 0.0;
  final coveragePaths = <String>[];
  final includePrefixes = <String>[];
  var showDetails = false;

  for (final argument in arguments) {
    if (argument.startsWith('--minimum=')) {
      minimum = double.parse(argument.substring('--minimum='.length));
    } else if (argument.startsWith('--file=')) {
      coveragePaths.add(argument.substring('--file='.length));
    } else if (argument.startsWith('--include=')) {
      includePrefixes.add(argument.substring('--include='.length));
    } else if (argument == '--details') {
      showDetails = true;
    } else {
      stderr.writeln('Unknown argument: $argument');
      exitCode = 64;
      return;
    }
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

  if (showDetails || summary.percentage + 0.000001 < minimum) {
    for (final entry in summary.uncoveredLinesBySource.entries) {
      stdout.writeln('Uncovered ${entry.key}: ${entry.value.join(', ')}');
    }
  }

  if (summary.percentage + 0.000001 < minimum) {
    stderr.writeln(
      'Coverage is below the required ${minimum.toStringAsFixed(1)}%.',
    );
    exitCode = 1;
  }
}

CoverageSummary summarizeLcov(
  Iterable<String> lines, {
  Iterable<String> includePrefixes = const <String>[],
}) {
  return summarizeLcovFiles([lines], includePrefixes: includePrefixes);
}

CoverageSummary summarizeLcovFiles(
  Iterable<Iterable<String>> files, {
  Iterable<String> includePrefixes = const <String>[],
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
            source.endsWith('.g.dart') ||
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

  return CoverageSummary(
    linesFound: linesFound,
    linesHit: linesHit,
    uncoveredLinesBySource: Map<String, List<int>>.unmodifiable(
      uncoveredLinesBySource,
    ),
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

class CoverageSummary {
  const CoverageSummary({
    required this.linesFound,
    required this.linesHit,
    this.uncoveredLinesBySource = const <String, List<int>>{},
  });

  final int linesFound;
  final int linesHit;
  final Map<String, List<int>> uncoveredLinesBySource;

  double get percentage => linesFound == 0 ? 0 : (linesHit * 100) / linesFound;
}
