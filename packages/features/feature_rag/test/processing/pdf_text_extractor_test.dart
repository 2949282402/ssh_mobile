import 'package:archive/archive.dart';
import 'package:feature_rag/feature_rag.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rejects excessive PDF page and stream counts before decoding', () {
    final tooManyPages =
        '%PDF-1.7\n${List.filled(PdfTextExtractor.maxPageCount + 1, '/Type /Page').join('\n')}'
            .codeUnits;
    final tooManyStreams =
        '%PDF-1.7\n${List.filled(PdfTextExtractor.maxStreamCount + 1, 'stream\nx\nendstream').join('\n')}'
            .codeUnits;

    expect(
      () => PdfTextExtractor.extractText(tooManyPages),
      throwsA(
        isA<PdfTextLimitExceededException>().having(
          (error) => error.limit,
          'limit',
          'page_count',
        ),
      ),
    );
    expect(
      () => PdfTextExtractor.extractText(tooManyStreams),
      throwsA(
        isA<PdfTextLimitExceededException>().having(
          (error) => error.limit,
          'limit',
          'stream_count',
        ),
      ),
    );
  });

  test('rejects a compressed stream that expands beyond its hard limit', () {
    final expanded = List<int>.filled(
      PdfTextExtractor.maxExpandedStreamBytes + 1,
      0x20,
    );
    final compressed = ZLibEncoder().encode(expanded);
    final bytes = <int>[
      ...'%PDF-1.7\nstream\n'.codeUnits,
      ...compressed,
      ...'\nendstream'.codeUnits,
    ];

    expect(
      () => PdfTextExtractor.extractText(bytes),
      throwsA(
        isA<PdfTextLimitExceededException>().having(
          (error) => error.limit,
          'limit',
          'expanded_stream_bytes',
        ),
      ),
    );
  });

  test('extracts bounded text from a normal compressed stream', () {
    final compressed = ZLibEncoder().encode('(hello bounded pdf) Tj'.codeUnits);
    final bytes = <int>[
      ...'%PDF-1.7\n/Type /Page\nstream\n'.codeUnits,
      ...compressed,
      ...'\nendstream'.codeUnits,
    ];

    expect(PdfTextExtractor.extractText(bytes), contains('hello bounded pdf'));
  });
}
