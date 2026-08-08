// RAG 文档块文件缓存。
//
// 缓存保存可重建的正文分块和向量，不属于数据库；每次写入都检查单文件上限，
// Module/Service 再依据清单执行总大小和 TTL 淘汰。

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/rag_models.dart';

/// RAG 缓存的资源边界，集中表达容量和过期策略，避免散落 Magic Number。
final class RagCachePolicy {
  static const int defaultMaxTotalBytes = 128 * 1024 * 1024;
  static const int defaultMaxEntryBytes = 32 * 1024 * 1024;
  static const int defaultMaxSourceBytes = 16 * 1024 * 1024;
  static const Duration defaultTtl = Duration(days: 30);

  const RagCachePolicy({
    this.maxTotalBytes = defaultMaxTotalBytes,
    this.maxEntryBytes = defaultMaxEntryBytes,
    this.maxSourceBytes = defaultMaxSourceBytes,
    this.ttl = defaultTtl,
  }) : assert(maxTotalBytes > 0),
       assert(maxEntryBytes > 0),
       assert(maxSourceBytes > 0);

  final int maxTotalBytes;
  final int maxEntryBytes;
  final int maxSourceBytes;
  final Duration ttl;
}

/// 文档块缓存超过单文件上限时抛出，防止一次上传耗尽移动端空间。
final class RagCacheLimitExceededException implements Exception {
  const RagCacheLimitExceededException({
    required this.documentId,
    required this.actualBytes,
    required this.allowedBytes,
  });

  final String documentId;
  final int actualBytes;
  final int allowedBytes;

  @override
  String toString() =>
      'RAG cache entry for $documentId is $actualBytes bytes; '
      'maximum is $allowedBytes bytes.';
}

/// 只负责文件缓存读写，不负责数据库清单或淘汰排序。
final class RagCacheStore {
  RagCacheStore({
    Future<Directory> Function()? directoryFactory,
    this.policy = const RagCachePolicy(),
  }) : _directoryFactory = directoryFactory ?? _defaultDirectory;

  final Future<Directory> Function() _directoryFactory;
  final RagCachePolicy policy;
  Future<Directory>? _directoryFuture;

  /// 写入一个文档的全部分块，并返回数据库需要保存的缓存清单。
  Future<RagCacheMetadata> write({
    required String documentId,
    required List<RagChunk> chunks,
  }) async {
    final encoded = utf8.encode(
      jsonEncode(chunks.map((chunk) => chunk.toJson()).toList()),
    );
    if (encoded.length > policy.maxEntryBytes) {
      throw RagCacheLimitExceededException(
        documentId: documentId,
        actualBytes: encoded.length,
        allowedBytes: policy.maxEntryBytes,
      );
    }

    final now = DateTime.now();
    final file = await _file(documentId);
    await file.writeAsBytes(encoded, flush: true);
    return RagCacheMetadata(
      documentId: documentId,
      fileName: p.basename(file.path),
      sizeBytes: encoded.length,
      createdAt: now,
      lastAccessedAt: now,
      expiresAt: now.add(policy.ttl),
    );
  }

  /// 读取文档块；缺失或格式损坏视为缓存未命中。
  Future<List<RagChunk>> read(RagCacheMetadata entry) async {
    try {
      final file = await _file(entry.documentId, fileName: entry.fileName);
      if (!await file.exists() || await file.length() > policy.maxEntryBytes) {
        return const [];
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is Map) RagChunk.fromJson(item.cast<String, dynamic>()),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 判断缓存文件是否仍存在，供 TTL/容量清理使用。
  Future<bool> exists(RagCacheMetadata entry) async {
    final file = await _file(entry.documentId, fileName: entry.fileName);
    if (!await file.exists()) return false;
    return await file.length() <= policy.maxEntryBytes;
  }

  /// 删除缓存文件；不存在时保持幂等。
  Future<void> delete(RagCacheMetadata entry) async {
    final file = await _file(entry.documentId, fileName: entry.fileName);
    if (await file.exists()) await file.delete();
  }

  Future<File> _file(String documentId, {String? fileName}) async {
    final directory = await _directory();
    final expectedName = fileNameFor(documentId);
    final safeName = fileName == expectedName ? fileName : expectedName;
    return File(p.join(directory.path, safeName));
  }

  /// 统一生成安全的缓存文件名，文档 ID 不参与路径分隔。
  static String fileNameFor(String documentId) =>
      'rag_doc_${Uri.encodeComponent(documentId)}.json';

  Future<Directory> _directory() async {
    final existing = _directoryFuture;
    if (existing != null) return existing;
    final future = _directoryFactory();
    _directoryFuture = future;
    try {
      final directory = await future;
      await directory.create(recursive: true);
      return directory;
    } catch (_) {
      _directoryFuture = null;
      rethrow;
    }
  }

  static Future<Directory> _defaultDirectory() async {
    final supportDirectory = await getApplicationSupportDirectory();
    return Directory(p.join(supportDirectory.path, 'rag_cache'));
  }
}
