// RAG 数据库表定义。
//
// 这里只保存文档元数据、倒排索引统计和文件缓存清单。文档正文、分块文本及
// 向量仍由 RagCacheStore 写入受限文件缓存，避免 rag.db 无界增长。

part of '../rag_database.dart';

class RagDocuments extends Table {
  TextColumn get id => text()();

  TextColumn get name => text()();

  TextColumn get mimeType => text()();

  IntColumn get sizeBytes => integer()();

  DateTimeColumn get uploadedAt => dateTime()();

  IntColumn get chunkCount => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

class RagIndexMetadataTable extends Table {
  TextColumn get id => text()();

  IntColumn get totalDocs => integer()();

  RealColumn get avgDocLength => real()();

  TextColumn get docLengthsJson => text()();

  TextColumn get invertedIndexJson => text()();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class RagCacheEntries extends Table {
  TextColumn get documentId =>
      text().references(RagDocuments, #id, onDelete: KeyAction.cascade)();

  TextColumn get fileName => text()();

  IntColumn get sizeBytes => integer()();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get lastAccessedAt => dateTime()();

  DateTimeColumn get expiresAt => dateTime()();

  @override
  Set<Column> get primaryKey => {documentId};
}
