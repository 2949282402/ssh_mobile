import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/utils/text_chunker.dart';
import 'package:ssh_mobile/utils/bm25_search.dart';
import 'package:ssh_mobile/utils/pdf_text_extractor.dart';

void main() {
  group('TextChunker Tests', () {
    test('Splits standard English text into chunks with sliding window', () {
      const text = 'This is a long test document. It contains multiple sentences. '
          'We want to chunk it. Sliding window is important. Let us verify.';
      final chunks = TextChunker.split(
        text: text,
        documentId: 'doc-1',
        documentName: 'test.txt',
        chunkSize: 50,
        chunkOverlap: 10,
      );

      expect(chunks.isNotEmpty, true);
      expect(chunks[0].documentId, 'doc-1');
      expect(chunks[0].documentName, 'test.txt');
      expect(chunks[0].text.contains('This is a long test document'), true);
      expect(chunks.length > 1, true);
    });

    test('Splits Chinese text correctly and respects sentence boundary', () {
      const text = '这是一个中文测试文档。它包含多句话。我们要对它进行分块。滑动窗口非常重要。让我们来测试一下它的效果吧！';
      final chunks = TextChunker.split(
        text: text,
        documentId: 'doc-2',
        documentName: 'chinese.txt',
        chunkSize: 20,
        chunkOverlap: 5,
      );

      expect(chunks.isNotEmpty, true);
      expect(chunks[0].text.startsWith('这是一个中文测试文档'), true);
    });
  });

  group('Bm25SearchEngine Tokenizer & Retrieval Tests', () {
    test('Tokenizes English, Chinese, and hybrid terms correctly', () {
      final engine = Bm25SearchEngine();

      final tokens1 = engine.tokenize('systemctl restart nginx');
      expect(tokens1, containsAll(['systemctl', 'restart', 'nginx']));

      final tokens2 = engine.tokenize('重装系统 Nginx');
      // "重装系统" has Chinese chars. Bigram tokens: 重, 重装, 装, 装系, 系, 系统, 统
      expect(tokens2, containsAll(['重装', '系统', 'nginx']));
    });

    test('Indexes and retrieves documents correctly by relevance score', () {
      final engine = Bm25SearchEngine();

      final chunk1 = RagChunk(
        id: 'c1',
        documentId: 'doc-1',
        documentName: 'nginx.txt',
        text: 'Nginx is a web server. To restart it, run systemctl restart nginx. It listens on port 80.',
        charStartIndex: 0,
        charEndIndex: 85,
      );

      final chunk2 = RagChunk(
        id: 'c2',
        documentId: 'doc-1',
        documentName: 'nginx.txt',
        text: 'The nginx configuration file is located at /etc/nginx/nginx.conf.',
        charStartIndex: 86,
        charEndIndex: 145,
      );

      final chunk3 = RagChunk(
        id: 'c3',
        documentId: 'doc-2',
        documentName: 'docker.txt',
        text: 'Docker is a container platform. Run docker run to start a container.',
        charStartIndex: 0,
        charEndIndex: 70,
      );

      engine.addChunks([chunk1, chunk2, chunk3]);

      // Search for "restart nginx"
      final results1 = engine.search('restart nginx', limit: 2);
      expect(results1.length, 2);
      expect(results1[0].chunk.id, 'c1'); // Matches "restart" and "nginx"
      expect(results1[1].chunk.id, 'c2'); // Matches only "nginx"

      // Search for "docker container"
      final results2 = engine.search('docker container', limit: 2);
      expect(results2.length, 1);
      expect(results2[0].chunk.id, 'c3');
    });

    test('Serializes and deserializes correctly', () {
      final engine = Bm25SearchEngine();
      final chunk1 = RagChunk(
        id: 'c1',
        documentId: 'doc-1',
        documentName: 'test.txt',
        text: 'Hello test document context.',
        charStartIndex: 0,
        charEndIndex: 28,
      );
      engine.addChunks([chunk1]);

      final json = engine.toJson();
      final engine2 = Bm25SearchEngine();
      engine2.loadFromJson(json);

      expect(engine2.totalDocs, 1);
      expect(engine2.search('context').first.chunk.text, 'Hello test document context.');
    });
  });

  group('PdfTextExtractor Tests', () {
    test('Throws on invalid PDF header', () {
      expect(
        () => PdfTextExtractor.extractText([1, 2, 3, 4]),
        throwsArgumentError,
      );
    });
  });
}
