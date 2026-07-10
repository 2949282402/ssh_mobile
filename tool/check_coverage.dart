import 'dart:io';

void main(List<String> arguments) {
  var minimum = 0.0;
  var coveragePath = 'coverage/lcov.info';

  for (final argument in arguments) {
    if (argument.startsWith('--minimum=')) {
      minimum = double.parse(argument.substring('--minimum='.length));
    } else if (argument.startsWith('--file=')) {
      coveragePath = argument.substring('--file='.length);
    } else {
      stderr.writeln('Unknown argument: $argument');
      exitCode = 64;
      return;
    }
  }

  final coverageFile = File(coveragePath);
  if (!coverageFile.existsSync()) {
    stderr.writeln('Coverage file not found: $coveragePath');
    exitCode = 66;
    return;
  }

  final summary = summarizeLcov(coverageFile.readAsLinesSync());
  if (summary.linesFound == 0) {
    stderr.writeln('Coverage file contains no coverable lines.');
    exitCode = 65;
    return;
  }

  stdout.writeln(
    'Line coverage: ${summary.percentage.toStringAsFixed(1)}% '
    '(${summary.linesHit}/${summary.linesFound}, generated files excluded)',
  );

  if (summary.percentage + 0.000001 < minimum) {
    stderr.writeln(
      'Coverage is below the required ${minimum.toStringAsFixed(1)}%.',
    );
    exitCode = 1;
  }
}

CoverageSummary summarizeLcov(Iterable<String> lines) {
  var linesFound = 0;
  var linesHit = 0;
  var skipCurrentFile = false;

  for (final line in lines) {
    if (line.startsWith('SF:')) {
      final source = line.substring(3).replaceAll('\\', '/');
      skipCurrentFile =
          source.endsWith('.g.dart') ||
          source.startsWith('third_party/') ||
          source.contains('/third_party/');
    } else if (!skipCurrentFile && line.startsWith('LF:')) {
      linesFound += int.parse(line.substring(3));
    } else if (!skipCurrentFile && line.startsWith('LH:')) {
      linesHit += int.parse(line.substring(3));
    }
  }

  return CoverageSummary(linesFound: linesFound, linesHit: linesHit);
}

class CoverageSummary {
  const CoverageSummary({required this.linesFound, required this.linesHit});

  final int linesFound;
  final int linesHit;

  double get percentage => linesFound == 0 ? 0 : (linesHit * 100) / linesFound;
}
