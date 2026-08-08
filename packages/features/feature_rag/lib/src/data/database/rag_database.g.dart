// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'rag_database.dart';

// ignore_for_file: type=lint
class $RagDocumentsTable extends RagDocuments
    with TableInfo<$RagDocumentsTable, RagDocument> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RagDocumentsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _mimeTypeMeta = const VerificationMeta(
    'mimeType',
  );
  @override
  late final GeneratedColumn<String> mimeType = GeneratedColumn<String>(
    'mime_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sizeBytesMeta = const VerificationMeta(
    'sizeBytes',
  );
  @override
  late final GeneratedColumn<int> sizeBytes = GeneratedColumn<int>(
    'size_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _uploadedAtMeta = const VerificationMeta(
    'uploadedAt',
  );
  @override
  late final GeneratedColumn<DateTime> uploadedAt = GeneratedColumn<DateTime>(
    'uploaded_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _chunkCountMeta = const VerificationMeta(
    'chunkCount',
  );
  @override
  late final GeneratedColumn<int> chunkCount = GeneratedColumn<int>(
    'chunk_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    mimeType,
    sizeBytes,
    uploadedAt,
    chunkCount,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'rag_documents';
  @override
  VerificationContext validateIntegrity(
    Insertable<RagDocument> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('mime_type')) {
      context.handle(
        _mimeTypeMeta,
        mimeType.isAcceptableOrUnknown(data['mime_type']!, _mimeTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_mimeTypeMeta);
    }
    if (data.containsKey('size_bytes')) {
      context.handle(
        _sizeBytesMeta,
        sizeBytes.isAcceptableOrUnknown(data['size_bytes']!, _sizeBytesMeta),
      );
    } else if (isInserting) {
      context.missing(_sizeBytesMeta);
    }
    if (data.containsKey('uploaded_at')) {
      context.handle(
        _uploadedAtMeta,
        uploadedAt.isAcceptableOrUnknown(data['uploaded_at']!, _uploadedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_uploadedAtMeta);
    }
    if (data.containsKey('chunk_count')) {
      context.handle(
        _chunkCountMeta,
        chunkCount.isAcceptableOrUnknown(data['chunk_count']!, _chunkCountMeta),
      );
    } else if (isInserting) {
      context.missing(_chunkCountMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  RagDocument map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RagDocument(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      mimeType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mime_type'],
      )!,
      sizeBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size_bytes'],
      )!,
      uploadedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}uploaded_at'],
      )!,
      chunkCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}chunk_count'],
      )!,
    );
  }

  @override
  $RagDocumentsTable createAlias(String alias) {
    return $RagDocumentsTable(attachedDatabase, alias);
  }
}

class RagDocument extends DataClass implements Insertable<RagDocument> {
  final String id;
  final String name;
  final String mimeType;
  final int sizeBytes;
  final DateTime uploadedAt;
  final int chunkCount;
  const RagDocument({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.sizeBytes,
    required this.uploadedAt,
    required this.chunkCount,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['mime_type'] = Variable<String>(mimeType);
    map['size_bytes'] = Variable<int>(sizeBytes);
    map['uploaded_at'] = Variable<DateTime>(uploadedAt);
    map['chunk_count'] = Variable<int>(chunkCount);
    return map;
  }

  RagDocumentsCompanion toCompanion(bool nullToAbsent) {
    return RagDocumentsCompanion(
      id: Value(id),
      name: Value(name),
      mimeType: Value(mimeType),
      sizeBytes: Value(sizeBytes),
      uploadedAt: Value(uploadedAt),
      chunkCount: Value(chunkCount),
    );
  }

  factory RagDocument.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RagDocument(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      mimeType: serializer.fromJson<String>(json['mimeType']),
      sizeBytes: serializer.fromJson<int>(json['sizeBytes']),
      uploadedAt: serializer.fromJson<DateTime>(json['uploadedAt']),
      chunkCount: serializer.fromJson<int>(json['chunkCount']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'mimeType': serializer.toJson<String>(mimeType),
      'sizeBytes': serializer.toJson<int>(sizeBytes),
      'uploadedAt': serializer.toJson<DateTime>(uploadedAt),
      'chunkCount': serializer.toJson<int>(chunkCount),
    };
  }

  RagDocument copyWith({
    String? id,
    String? name,
    String? mimeType,
    int? sizeBytes,
    DateTime? uploadedAt,
    int? chunkCount,
  }) => RagDocument(
    id: id ?? this.id,
    name: name ?? this.name,
    mimeType: mimeType ?? this.mimeType,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    uploadedAt: uploadedAt ?? this.uploadedAt,
    chunkCount: chunkCount ?? this.chunkCount,
  );
  RagDocument copyWithCompanion(RagDocumentsCompanion data) {
    return RagDocument(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      mimeType: data.mimeType.present ? data.mimeType.value : this.mimeType,
      sizeBytes: data.sizeBytes.present ? data.sizeBytes.value : this.sizeBytes,
      uploadedAt: data.uploadedAt.present
          ? data.uploadedAt.value
          : this.uploadedAt,
      chunkCount: data.chunkCount.present
          ? data.chunkCount.value
          : this.chunkCount,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RagDocument(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('mimeType: $mimeType, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('uploadedAt: $uploadedAt, ')
          ..write('chunkCount: $chunkCount')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, name, mimeType, sizeBytes, uploadedAt, chunkCount);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RagDocument &&
          other.id == this.id &&
          other.name == this.name &&
          other.mimeType == this.mimeType &&
          other.sizeBytes == this.sizeBytes &&
          other.uploadedAt == this.uploadedAt &&
          other.chunkCount == this.chunkCount);
}

class RagDocumentsCompanion extends UpdateCompanion<RagDocument> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> mimeType;
  final Value<int> sizeBytes;
  final Value<DateTime> uploadedAt;
  final Value<int> chunkCount;
  final Value<int> rowid;
  const RagDocumentsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.mimeType = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    this.uploadedAt = const Value.absent(),
    this.chunkCount = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RagDocumentsCompanion.insert({
    required String id,
    required String name,
    required String mimeType,
    required int sizeBytes,
    required DateTime uploadedAt,
    required int chunkCount,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       mimeType = Value(mimeType),
       sizeBytes = Value(sizeBytes),
       uploadedAt = Value(uploadedAt),
       chunkCount = Value(chunkCount);
  static Insertable<RagDocument> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? mimeType,
    Expression<int>? sizeBytes,
    Expression<DateTime>? uploadedAt,
    Expression<int>? chunkCount,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (mimeType != null) 'mime_type': mimeType,
      if (sizeBytes != null) 'size_bytes': sizeBytes,
      if (uploadedAt != null) 'uploaded_at': uploadedAt,
      if (chunkCount != null) 'chunk_count': chunkCount,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RagDocumentsCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String>? mimeType,
    Value<int>? sizeBytes,
    Value<DateTime>? uploadedAt,
    Value<int>? chunkCount,
    Value<int>? rowid,
  }) {
    return RagDocumentsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      mimeType: mimeType ?? this.mimeType,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      uploadedAt: uploadedAt ?? this.uploadedAt,
      chunkCount: chunkCount ?? this.chunkCount,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (mimeType.present) {
      map['mime_type'] = Variable<String>(mimeType.value);
    }
    if (sizeBytes.present) {
      map['size_bytes'] = Variable<int>(sizeBytes.value);
    }
    if (uploadedAt.present) {
      map['uploaded_at'] = Variable<DateTime>(uploadedAt.value);
    }
    if (chunkCount.present) {
      map['chunk_count'] = Variable<int>(chunkCount.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RagDocumentsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('mimeType: $mimeType, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('uploadedAt: $uploadedAt, ')
          ..write('chunkCount: $chunkCount, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RagIndexMetadataTableTable extends RagIndexMetadataTable
    with TableInfo<$RagIndexMetadataTableTable, RagIndexMetadataTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RagIndexMetadataTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _totalDocsMeta = const VerificationMeta(
    'totalDocs',
  );
  @override
  late final GeneratedColumn<int> totalDocs = GeneratedColumn<int>(
    'total_docs',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _avgDocLengthMeta = const VerificationMeta(
    'avgDocLength',
  );
  @override
  late final GeneratedColumn<double> avgDocLength = GeneratedColumn<double>(
    'avg_doc_length',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _docLengthsJsonMeta = const VerificationMeta(
    'docLengthsJson',
  );
  @override
  late final GeneratedColumn<String> docLengthsJson = GeneratedColumn<String>(
    'doc_lengths_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _invertedIndexJsonMeta = const VerificationMeta(
    'invertedIndexJson',
  );
  @override
  late final GeneratedColumn<String> invertedIndexJson =
      GeneratedColumn<String>(
        'inverted_index_json',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    totalDocs,
    avgDocLength,
    docLengthsJson,
    invertedIndexJson,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'rag_index_metadata_table';
  @override
  VerificationContext validateIntegrity(
    Insertable<RagIndexMetadataTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('total_docs')) {
      context.handle(
        _totalDocsMeta,
        totalDocs.isAcceptableOrUnknown(data['total_docs']!, _totalDocsMeta),
      );
    } else if (isInserting) {
      context.missing(_totalDocsMeta);
    }
    if (data.containsKey('avg_doc_length')) {
      context.handle(
        _avgDocLengthMeta,
        avgDocLength.isAcceptableOrUnknown(
          data['avg_doc_length']!,
          _avgDocLengthMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_avgDocLengthMeta);
    }
    if (data.containsKey('doc_lengths_json')) {
      context.handle(
        _docLengthsJsonMeta,
        docLengthsJson.isAcceptableOrUnknown(
          data['doc_lengths_json']!,
          _docLengthsJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_docLengthsJsonMeta);
    }
    if (data.containsKey('inverted_index_json')) {
      context.handle(
        _invertedIndexJsonMeta,
        invertedIndexJson.isAcceptableOrUnknown(
          data['inverted_index_json']!,
          _invertedIndexJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_invertedIndexJsonMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  RagIndexMetadataTableData map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RagIndexMetadataTableData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      totalDocs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}total_docs'],
      )!,
      avgDocLength: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}avg_doc_length'],
      )!,
      docLengthsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}doc_lengths_json'],
      )!,
      invertedIndexJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}inverted_index_json'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $RagIndexMetadataTableTable createAlias(String alias) {
    return $RagIndexMetadataTableTable(attachedDatabase, alias);
  }
}

class RagIndexMetadataTableData extends DataClass
    implements Insertable<RagIndexMetadataTableData> {
  final String id;
  final int totalDocs;
  final double avgDocLength;
  final String docLengthsJson;
  final String invertedIndexJson;
  final DateTime updatedAt;
  const RagIndexMetadataTableData({
    required this.id,
    required this.totalDocs,
    required this.avgDocLength,
    required this.docLengthsJson,
    required this.invertedIndexJson,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['total_docs'] = Variable<int>(totalDocs);
    map['avg_doc_length'] = Variable<double>(avgDocLength);
    map['doc_lengths_json'] = Variable<String>(docLengthsJson);
    map['inverted_index_json'] = Variable<String>(invertedIndexJson);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  RagIndexMetadataTableCompanion toCompanion(bool nullToAbsent) {
    return RagIndexMetadataTableCompanion(
      id: Value(id),
      totalDocs: Value(totalDocs),
      avgDocLength: Value(avgDocLength),
      docLengthsJson: Value(docLengthsJson),
      invertedIndexJson: Value(invertedIndexJson),
      updatedAt: Value(updatedAt),
    );
  }

  factory RagIndexMetadataTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RagIndexMetadataTableData(
      id: serializer.fromJson<String>(json['id']),
      totalDocs: serializer.fromJson<int>(json['totalDocs']),
      avgDocLength: serializer.fromJson<double>(json['avgDocLength']),
      docLengthsJson: serializer.fromJson<String>(json['docLengthsJson']),
      invertedIndexJson: serializer.fromJson<String>(json['invertedIndexJson']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'totalDocs': serializer.toJson<int>(totalDocs),
      'avgDocLength': serializer.toJson<double>(avgDocLength),
      'docLengthsJson': serializer.toJson<String>(docLengthsJson),
      'invertedIndexJson': serializer.toJson<String>(invertedIndexJson),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  RagIndexMetadataTableData copyWith({
    String? id,
    int? totalDocs,
    double? avgDocLength,
    String? docLengthsJson,
    String? invertedIndexJson,
    DateTime? updatedAt,
  }) => RagIndexMetadataTableData(
    id: id ?? this.id,
    totalDocs: totalDocs ?? this.totalDocs,
    avgDocLength: avgDocLength ?? this.avgDocLength,
    docLengthsJson: docLengthsJson ?? this.docLengthsJson,
    invertedIndexJson: invertedIndexJson ?? this.invertedIndexJson,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  RagIndexMetadataTableData copyWithCompanion(
    RagIndexMetadataTableCompanion data,
  ) {
    return RagIndexMetadataTableData(
      id: data.id.present ? data.id.value : this.id,
      totalDocs: data.totalDocs.present ? data.totalDocs.value : this.totalDocs,
      avgDocLength: data.avgDocLength.present
          ? data.avgDocLength.value
          : this.avgDocLength,
      docLengthsJson: data.docLengthsJson.present
          ? data.docLengthsJson.value
          : this.docLengthsJson,
      invertedIndexJson: data.invertedIndexJson.present
          ? data.invertedIndexJson.value
          : this.invertedIndexJson,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RagIndexMetadataTableData(')
          ..write('id: $id, ')
          ..write('totalDocs: $totalDocs, ')
          ..write('avgDocLength: $avgDocLength, ')
          ..write('docLengthsJson: $docLengthsJson, ')
          ..write('invertedIndexJson: $invertedIndexJson, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    totalDocs,
    avgDocLength,
    docLengthsJson,
    invertedIndexJson,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RagIndexMetadataTableData &&
          other.id == this.id &&
          other.totalDocs == this.totalDocs &&
          other.avgDocLength == this.avgDocLength &&
          other.docLengthsJson == this.docLengthsJson &&
          other.invertedIndexJson == this.invertedIndexJson &&
          other.updatedAt == this.updatedAt);
}

class RagIndexMetadataTableCompanion
    extends UpdateCompanion<RagIndexMetadataTableData> {
  final Value<String> id;
  final Value<int> totalDocs;
  final Value<double> avgDocLength;
  final Value<String> docLengthsJson;
  final Value<String> invertedIndexJson;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const RagIndexMetadataTableCompanion({
    this.id = const Value.absent(),
    this.totalDocs = const Value.absent(),
    this.avgDocLength = const Value.absent(),
    this.docLengthsJson = const Value.absent(),
    this.invertedIndexJson = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RagIndexMetadataTableCompanion.insert({
    required String id,
    required int totalDocs,
    required double avgDocLength,
    required String docLengthsJson,
    required String invertedIndexJson,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       totalDocs = Value(totalDocs),
       avgDocLength = Value(avgDocLength),
       docLengthsJson = Value(docLengthsJson),
       invertedIndexJson = Value(invertedIndexJson),
       updatedAt = Value(updatedAt);
  static Insertable<RagIndexMetadataTableData> custom({
    Expression<String>? id,
    Expression<int>? totalDocs,
    Expression<double>? avgDocLength,
    Expression<String>? docLengthsJson,
    Expression<String>? invertedIndexJson,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (totalDocs != null) 'total_docs': totalDocs,
      if (avgDocLength != null) 'avg_doc_length': avgDocLength,
      if (docLengthsJson != null) 'doc_lengths_json': docLengthsJson,
      if (invertedIndexJson != null) 'inverted_index_json': invertedIndexJson,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RagIndexMetadataTableCompanion copyWith({
    Value<String>? id,
    Value<int>? totalDocs,
    Value<double>? avgDocLength,
    Value<String>? docLengthsJson,
    Value<String>? invertedIndexJson,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return RagIndexMetadataTableCompanion(
      id: id ?? this.id,
      totalDocs: totalDocs ?? this.totalDocs,
      avgDocLength: avgDocLength ?? this.avgDocLength,
      docLengthsJson: docLengthsJson ?? this.docLengthsJson,
      invertedIndexJson: invertedIndexJson ?? this.invertedIndexJson,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (totalDocs.present) {
      map['total_docs'] = Variable<int>(totalDocs.value);
    }
    if (avgDocLength.present) {
      map['avg_doc_length'] = Variable<double>(avgDocLength.value);
    }
    if (docLengthsJson.present) {
      map['doc_lengths_json'] = Variable<String>(docLengthsJson.value);
    }
    if (invertedIndexJson.present) {
      map['inverted_index_json'] = Variable<String>(invertedIndexJson.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RagIndexMetadataTableCompanion(')
          ..write('id: $id, ')
          ..write('totalDocs: $totalDocs, ')
          ..write('avgDocLength: $avgDocLength, ')
          ..write('docLengthsJson: $docLengthsJson, ')
          ..write('invertedIndexJson: $invertedIndexJson, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RagCacheEntriesTable extends RagCacheEntries
    with TableInfo<$RagCacheEntriesTable, RagCacheEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RagCacheEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _documentIdMeta = const VerificationMeta(
    'documentId',
  );
  @override
  late final GeneratedColumn<String> documentId = GeneratedColumn<String>(
    'document_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES rag_documents (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _fileNameMeta = const VerificationMeta(
    'fileName',
  );
  @override
  late final GeneratedColumn<String> fileName = GeneratedColumn<String>(
    'file_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sizeBytesMeta = const VerificationMeta(
    'sizeBytes',
  );
  @override
  late final GeneratedColumn<int> sizeBytes = GeneratedColumn<int>(
    'size_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastAccessedAtMeta = const VerificationMeta(
    'lastAccessedAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastAccessedAt =
      GeneratedColumn<DateTime>(
        'last_accessed_at',
        aliasedName,
        false,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _expiresAtMeta = const VerificationMeta(
    'expiresAt',
  );
  @override
  late final GeneratedColumn<DateTime> expiresAt = GeneratedColumn<DateTime>(
    'expires_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    documentId,
    fileName,
    sizeBytes,
    createdAt,
    lastAccessedAt,
    expiresAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'rag_cache_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<RagCacheEntry> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('document_id')) {
      context.handle(
        _documentIdMeta,
        documentId.isAcceptableOrUnknown(data['document_id']!, _documentIdMeta),
      );
    } else if (isInserting) {
      context.missing(_documentIdMeta);
    }
    if (data.containsKey('file_name')) {
      context.handle(
        _fileNameMeta,
        fileName.isAcceptableOrUnknown(data['file_name']!, _fileNameMeta),
      );
    } else if (isInserting) {
      context.missing(_fileNameMeta);
    }
    if (data.containsKey('size_bytes')) {
      context.handle(
        _sizeBytesMeta,
        sizeBytes.isAcceptableOrUnknown(data['size_bytes']!, _sizeBytesMeta),
      );
    } else if (isInserting) {
      context.missing(_sizeBytesMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('last_accessed_at')) {
      context.handle(
        _lastAccessedAtMeta,
        lastAccessedAt.isAcceptableOrUnknown(
          data['last_accessed_at']!,
          _lastAccessedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_lastAccessedAtMeta);
    }
    if (data.containsKey('expires_at')) {
      context.handle(
        _expiresAtMeta,
        expiresAt.isAcceptableOrUnknown(data['expires_at']!, _expiresAtMeta),
      );
    } else if (isInserting) {
      context.missing(_expiresAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {documentId};
  @override
  RagCacheEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RagCacheEntry(
      documentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}document_id'],
      )!,
      fileName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}file_name'],
      )!,
      sizeBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size_bytes'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      lastAccessedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_accessed_at'],
      )!,
      expiresAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}expires_at'],
      )!,
    );
  }

  @override
  $RagCacheEntriesTable createAlias(String alias) {
    return $RagCacheEntriesTable(attachedDatabase, alias);
  }
}

class RagCacheEntry extends DataClass implements Insertable<RagCacheEntry> {
  final String documentId;
  final String fileName;
  final int sizeBytes;
  final DateTime createdAt;
  final DateTime lastAccessedAt;
  final DateTime expiresAt;
  const RagCacheEntry({
    required this.documentId,
    required this.fileName,
    required this.sizeBytes,
    required this.createdAt,
    required this.lastAccessedAt,
    required this.expiresAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['document_id'] = Variable<String>(documentId);
    map['file_name'] = Variable<String>(fileName);
    map['size_bytes'] = Variable<int>(sizeBytes);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['last_accessed_at'] = Variable<DateTime>(lastAccessedAt);
    map['expires_at'] = Variable<DateTime>(expiresAt);
    return map;
  }

  RagCacheEntriesCompanion toCompanion(bool nullToAbsent) {
    return RagCacheEntriesCompanion(
      documentId: Value(documentId),
      fileName: Value(fileName),
      sizeBytes: Value(sizeBytes),
      createdAt: Value(createdAt),
      lastAccessedAt: Value(lastAccessedAt),
      expiresAt: Value(expiresAt),
    );
  }

  factory RagCacheEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RagCacheEntry(
      documentId: serializer.fromJson<String>(json['documentId']),
      fileName: serializer.fromJson<String>(json['fileName']),
      sizeBytes: serializer.fromJson<int>(json['sizeBytes']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      lastAccessedAt: serializer.fromJson<DateTime>(json['lastAccessedAt']),
      expiresAt: serializer.fromJson<DateTime>(json['expiresAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'documentId': serializer.toJson<String>(documentId),
      'fileName': serializer.toJson<String>(fileName),
      'sizeBytes': serializer.toJson<int>(sizeBytes),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'lastAccessedAt': serializer.toJson<DateTime>(lastAccessedAt),
      'expiresAt': serializer.toJson<DateTime>(expiresAt),
    };
  }

  RagCacheEntry copyWith({
    String? documentId,
    String? fileName,
    int? sizeBytes,
    DateTime? createdAt,
    DateTime? lastAccessedAt,
    DateTime? expiresAt,
  }) => RagCacheEntry(
    documentId: documentId ?? this.documentId,
    fileName: fileName ?? this.fileName,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    createdAt: createdAt ?? this.createdAt,
    lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
    expiresAt: expiresAt ?? this.expiresAt,
  );
  RagCacheEntry copyWithCompanion(RagCacheEntriesCompanion data) {
    return RagCacheEntry(
      documentId: data.documentId.present
          ? data.documentId.value
          : this.documentId,
      fileName: data.fileName.present ? data.fileName.value : this.fileName,
      sizeBytes: data.sizeBytes.present ? data.sizeBytes.value : this.sizeBytes,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      lastAccessedAt: data.lastAccessedAt.present
          ? data.lastAccessedAt.value
          : this.lastAccessedAt,
      expiresAt: data.expiresAt.present ? data.expiresAt.value : this.expiresAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RagCacheEntry(')
          ..write('documentId: $documentId, ')
          ..write('fileName: $fileName, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastAccessedAt: $lastAccessedAt, ')
          ..write('expiresAt: $expiresAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    documentId,
    fileName,
    sizeBytes,
    createdAt,
    lastAccessedAt,
    expiresAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RagCacheEntry &&
          other.documentId == this.documentId &&
          other.fileName == this.fileName &&
          other.sizeBytes == this.sizeBytes &&
          other.createdAt == this.createdAt &&
          other.lastAccessedAt == this.lastAccessedAt &&
          other.expiresAt == this.expiresAt);
}

class RagCacheEntriesCompanion extends UpdateCompanion<RagCacheEntry> {
  final Value<String> documentId;
  final Value<String> fileName;
  final Value<int> sizeBytes;
  final Value<DateTime> createdAt;
  final Value<DateTime> lastAccessedAt;
  final Value<DateTime> expiresAt;
  final Value<int> rowid;
  const RagCacheEntriesCompanion({
    this.documentId = const Value.absent(),
    this.fileName = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.lastAccessedAt = const Value.absent(),
    this.expiresAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RagCacheEntriesCompanion.insert({
    required String documentId,
    required String fileName,
    required int sizeBytes,
    required DateTime createdAt,
    required DateTime lastAccessedAt,
    required DateTime expiresAt,
    this.rowid = const Value.absent(),
  }) : documentId = Value(documentId),
       fileName = Value(fileName),
       sizeBytes = Value(sizeBytes),
       createdAt = Value(createdAt),
       lastAccessedAt = Value(lastAccessedAt),
       expiresAt = Value(expiresAt);
  static Insertable<RagCacheEntry> custom({
    Expression<String>? documentId,
    Expression<String>? fileName,
    Expression<int>? sizeBytes,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? lastAccessedAt,
    Expression<DateTime>? expiresAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (documentId != null) 'document_id': documentId,
      if (fileName != null) 'file_name': fileName,
      if (sizeBytes != null) 'size_bytes': sizeBytes,
      if (createdAt != null) 'created_at': createdAt,
      if (lastAccessedAt != null) 'last_accessed_at': lastAccessedAt,
      if (expiresAt != null) 'expires_at': expiresAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RagCacheEntriesCompanion copyWith({
    Value<String>? documentId,
    Value<String>? fileName,
    Value<int>? sizeBytes,
    Value<DateTime>? createdAt,
    Value<DateTime>? lastAccessedAt,
    Value<DateTime>? expiresAt,
    Value<int>? rowid,
  }) {
    return RagCacheEntriesCompanion(
      documentId: documentId ?? this.documentId,
      fileName: fileName ?? this.fileName,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      createdAt: createdAt ?? this.createdAt,
      lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (documentId.present) {
      map['document_id'] = Variable<String>(documentId.value);
    }
    if (fileName.present) {
      map['file_name'] = Variable<String>(fileName.value);
    }
    if (sizeBytes.present) {
      map['size_bytes'] = Variable<int>(sizeBytes.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (lastAccessedAt.present) {
      map['last_accessed_at'] = Variable<DateTime>(lastAccessedAt.value);
    }
    if (expiresAt.present) {
      map['expires_at'] = Variable<DateTime>(expiresAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RagCacheEntriesCompanion(')
          ..write('documentId: $documentId, ')
          ..write('fileName: $fileName, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastAccessedAt: $lastAccessedAt, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$RagDatabase extends GeneratedDatabase {
  _$RagDatabase(QueryExecutor e) : super(e);
  $RagDatabaseManager get managers => $RagDatabaseManager(this);
  late final $RagDocumentsTable ragDocuments = $RagDocumentsTable(this);
  late final $RagIndexMetadataTableTable ragIndexMetadataTable =
      $RagIndexMetadataTableTable(this);
  late final $RagCacheEntriesTable ragCacheEntries = $RagCacheEntriesTable(
    this,
  );
  late final RagDao ragDao = RagDao(this as RagDatabase);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    ragDocuments,
    ragIndexMetadataTable,
    ragCacheEntries,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'rag_documents',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('rag_cache_entries', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$RagDocumentsTableCreateCompanionBuilder =
    RagDocumentsCompanion Function({
      required String id,
      required String name,
      required String mimeType,
      required int sizeBytes,
      required DateTime uploadedAt,
      required int chunkCount,
      Value<int> rowid,
    });
typedef $$RagDocumentsTableUpdateCompanionBuilder =
    RagDocumentsCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<String> mimeType,
      Value<int> sizeBytes,
      Value<DateTime> uploadedAt,
      Value<int> chunkCount,
      Value<int> rowid,
    });

final class $$RagDocumentsTableReferences
    extends BaseReferences<_$RagDatabase, $RagDocumentsTable, RagDocument> {
  $$RagDocumentsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$RagCacheEntriesTable, List<RagCacheEntry>>
  _ragCacheEntriesRefsTable(_$RagDatabase db) => MultiTypedResultKey.fromTable(
    db.ragCacheEntries,
    aliasName: 'rag_documents__id__rag_cache_entries__document_id',
  );

  $$RagCacheEntriesTableProcessedTableManager get ragCacheEntriesRefs {
    final manager = $$RagCacheEntriesTableTableManager(
      $_db,
      $_db.ragCacheEntries,
    ).filter((f) => f.documentId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _ragCacheEntriesRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$RagDocumentsTableFilterComposer
    extends Composer<_$RagDatabase, $RagDocumentsTable> {
  $$RagDocumentsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mimeType => $composableBuilder(
    column: $table.mimeType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get uploadedAt => $composableBuilder(
    column: $table.uploadedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get chunkCount => $composableBuilder(
    column: $table.chunkCount,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> ragCacheEntriesRefs(
    Expression<bool> Function($$RagCacheEntriesTableFilterComposer f) f,
  ) {
    final $$RagCacheEntriesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.ragCacheEntries,
      getReferencedColumn: (t) => t.documentId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RagCacheEntriesTableFilterComposer(
            $db: $db,
            $table: $db.ragCacheEntries,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$RagDocumentsTableOrderingComposer
    extends Composer<_$RagDatabase, $RagDocumentsTable> {
  $$RagDocumentsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mimeType => $composableBuilder(
    column: $table.mimeType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get uploadedAt => $composableBuilder(
    column: $table.uploadedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get chunkCount => $composableBuilder(
    column: $table.chunkCount,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RagDocumentsTableAnnotationComposer
    extends Composer<_$RagDatabase, $RagDocumentsTable> {
  $$RagDocumentsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get mimeType =>
      $composableBuilder(column: $table.mimeType, builder: (column) => column);

  GeneratedColumn<int> get sizeBytes =>
      $composableBuilder(column: $table.sizeBytes, builder: (column) => column);

  GeneratedColumn<DateTime> get uploadedAt => $composableBuilder(
    column: $table.uploadedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get chunkCount => $composableBuilder(
    column: $table.chunkCount,
    builder: (column) => column,
  );

  Expression<T> ragCacheEntriesRefs<T extends Object>(
    Expression<T> Function($$RagCacheEntriesTableAnnotationComposer a) f,
  ) {
    final $$RagCacheEntriesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.ragCacheEntries,
      getReferencedColumn: (t) => t.documentId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RagCacheEntriesTableAnnotationComposer(
            $db: $db,
            $table: $db.ragCacheEntries,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$RagDocumentsTableTableManager
    extends
        RootTableManager<
          _$RagDatabase,
          $RagDocumentsTable,
          RagDocument,
          $$RagDocumentsTableFilterComposer,
          $$RagDocumentsTableOrderingComposer,
          $$RagDocumentsTableAnnotationComposer,
          $$RagDocumentsTableCreateCompanionBuilder,
          $$RagDocumentsTableUpdateCompanionBuilder,
          (RagDocument, $$RagDocumentsTableReferences),
          RagDocument,
          PrefetchHooks Function({bool ragCacheEntriesRefs})
        > {
  $$RagDocumentsTableTableManager(_$RagDatabase db, $RagDocumentsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RagDocumentsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RagDocumentsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RagDocumentsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> mimeType = const Value.absent(),
                Value<int> sizeBytes = const Value.absent(),
                Value<DateTime> uploadedAt = const Value.absent(),
                Value<int> chunkCount = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RagDocumentsCompanion(
                id: id,
                name: name,
                mimeType: mimeType,
                sizeBytes: sizeBytes,
                uploadedAt: uploadedAt,
                chunkCount: chunkCount,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required String mimeType,
                required int sizeBytes,
                required DateTime uploadedAt,
                required int chunkCount,
                Value<int> rowid = const Value.absent(),
              }) => RagDocumentsCompanion.insert(
                id: id,
                name: name,
                mimeType: mimeType,
                sizeBytes: sizeBytes,
                uploadedAt: uploadedAt,
                chunkCount: chunkCount,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$RagDocumentsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({ragCacheEntriesRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (ragCacheEntriesRefs) db.ragCacheEntries,
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (ragCacheEntriesRefs)
                    await $_getPrefetchedData<
                      RagDocument,
                      $RagDocumentsTable,
                      RagCacheEntry
                    >(
                      currentTable: table,
                      referencedTable: $$RagDocumentsTableReferences
                          ._ragCacheEntriesRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$RagDocumentsTableReferences(
                            db,
                            table,
                            p0,
                          ).ragCacheEntriesRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.documentId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$RagDocumentsTableProcessedTableManager =
    ProcessedTableManager<
      _$RagDatabase,
      $RagDocumentsTable,
      RagDocument,
      $$RagDocumentsTableFilterComposer,
      $$RagDocumentsTableOrderingComposer,
      $$RagDocumentsTableAnnotationComposer,
      $$RagDocumentsTableCreateCompanionBuilder,
      $$RagDocumentsTableUpdateCompanionBuilder,
      (RagDocument, $$RagDocumentsTableReferences),
      RagDocument,
      PrefetchHooks Function({bool ragCacheEntriesRefs})
    >;
typedef $$RagIndexMetadataTableTableCreateCompanionBuilder =
    RagIndexMetadataTableCompanion Function({
      required String id,
      required int totalDocs,
      required double avgDocLength,
      required String docLengthsJson,
      required String invertedIndexJson,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$RagIndexMetadataTableTableUpdateCompanionBuilder =
    RagIndexMetadataTableCompanion Function({
      Value<String> id,
      Value<int> totalDocs,
      Value<double> avgDocLength,
      Value<String> docLengthsJson,
      Value<String> invertedIndexJson,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

class $$RagIndexMetadataTableTableFilterComposer
    extends Composer<_$RagDatabase, $RagIndexMetadataTableTable> {
  $$RagIndexMetadataTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get totalDocs => $composableBuilder(
    column: $table.totalDocs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get avgDocLength => $composableBuilder(
    column: $table.avgDocLength,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get docLengthsJson => $composableBuilder(
    column: $table.docLengthsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get invertedIndexJson => $composableBuilder(
    column: $table.invertedIndexJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$RagIndexMetadataTableTableOrderingComposer
    extends Composer<_$RagDatabase, $RagIndexMetadataTableTable> {
  $$RagIndexMetadataTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get totalDocs => $composableBuilder(
    column: $table.totalDocs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get avgDocLength => $composableBuilder(
    column: $table.avgDocLength,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get docLengthsJson => $composableBuilder(
    column: $table.docLengthsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get invertedIndexJson => $composableBuilder(
    column: $table.invertedIndexJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RagIndexMetadataTableTableAnnotationComposer
    extends Composer<_$RagDatabase, $RagIndexMetadataTableTable> {
  $$RagIndexMetadataTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get totalDocs =>
      $composableBuilder(column: $table.totalDocs, builder: (column) => column);

  GeneratedColumn<double> get avgDocLength => $composableBuilder(
    column: $table.avgDocLength,
    builder: (column) => column,
  );

  GeneratedColumn<String> get docLengthsJson => $composableBuilder(
    column: $table.docLengthsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get invertedIndexJson => $composableBuilder(
    column: $table.invertedIndexJson,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$RagIndexMetadataTableTableTableManager
    extends
        RootTableManager<
          _$RagDatabase,
          $RagIndexMetadataTableTable,
          RagIndexMetadataTableData,
          $$RagIndexMetadataTableTableFilterComposer,
          $$RagIndexMetadataTableTableOrderingComposer,
          $$RagIndexMetadataTableTableAnnotationComposer,
          $$RagIndexMetadataTableTableCreateCompanionBuilder,
          $$RagIndexMetadataTableTableUpdateCompanionBuilder,
          (
            RagIndexMetadataTableData,
            BaseReferences<
              _$RagDatabase,
              $RagIndexMetadataTableTable,
              RagIndexMetadataTableData
            >,
          ),
          RagIndexMetadataTableData,
          PrefetchHooks Function()
        > {
  $$RagIndexMetadataTableTableTableManager(
    _$RagDatabase db,
    $RagIndexMetadataTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RagIndexMetadataTableTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$RagIndexMetadataTableTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$RagIndexMetadataTableTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> totalDocs = const Value.absent(),
                Value<double> avgDocLength = const Value.absent(),
                Value<String> docLengthsJson = const Value.absent(),
                Value<String> invertedIndexJson = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RagIndexMetadataTableCompanion(
                id: id,
                totalDocs: totalDocs,
                avgDocLength: avgDocLength,
                docLengthsJson: docLengthsJson,
                invertedIndexJson: invertedIndexJson,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required int totalDocs,
                required double avgDocLength,
                required String docLengthsJson,
                required String invertedIndexJson,
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => RagIndexMetadataTableCompanion.insert(
                id: id,
                totalDocs: totalDocs,
                avgDocLength: avgDocLength,
                docLengthsJson: docLengthsJson,
                invertedIndexJson: invertedIndexJson,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RagIndexMetadataTableTableProcessedTableManager =
    ProcessedTableManager<
      _$RagDatabase,
      $RagIndexMetadataTableTable,
      RagIndexMetadataTableData,
      $$RagIndexMetadataTableTableFilterComposer,
      $$RagIndexMetadataTableTableOrderingComposer,
      $$RagIndexMetadataTableTableAnnotationComposer,
      $$RagIndexMetadataTableTableCreateCompanionBuilder,
      $$RagIndexMetadataTableTableUpdateCompanionBuilder,
      (
        RagIndexMetadataTableData,
        BaseReferences<
          _$RagDatabase,
          $RagIndexMetadataTableTable,
          RagIndexMetadataTableData
        >,
      ),
      RagIndexMetadataTableData,
      PrefetchHooks Function()
    >;
typedef $$RagCacheEntriesTableCreateCompanionBuilder =
    RagCacheEntriesCompanion Function({
      required String documentId,
      required String fileName,
      required int sizeBytes,
      required DateTime createdAt,
      required DateTime lastAccessedAt,
      required DateTime expiresAt,
      Value<int> rowid,
    });
typedef $$RagCacheEntriesTableUpdateCompanionBuilder =
    RagCacheEntriesCompanion Function({
      Value<String> documentId,
      Value<String> fileName,
      Value<int> sizeBytes,
      Value<DateTime> createdAt,
      Value<DateTime> lastAccessedAt,
      Value<DateTime> expiresAt,
      Value<int> rowid,
    });

final class $$RagCacheEntriesTableReferences
    extends
        BaseReferences<_$RagDatabase, $RagCacheEntriesTable, RagCacheEntry> {
  $$RagCacheEntriesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $RagDocumentsTable _documentIdTable(_$RagDatabase db) => db
      .ragDocuments
      .createAlias('rag_cache_entries__document_id__rag_documents__id');

  $$RagDocumentsTableProcessedTableManager get documentId {
    final $_column = $_itemColumn<String>('document_id')!;

    final manager = $$RagDocumentsTableTableManager(
      $_db,
      $_db.ragDocuments,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_documentIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$RagCacheEntriesTableFilterComposer
    extends Composer<_$RagDatabase, $RagCacheEntriesTable> {
  $$RagCacheEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastAccessedAt => $composableBuilder(
    column: $table.lastAccessedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnFilters(column),
  );

  $$RagDocumentsTableFilterComposer get documentId {
    final $$RagDocumentsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.documentId,
      referencedTable: $db.ragDocuments,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RagDocumentsTableFilterComposer(
            $db: $db,
            $table: $db.ragDocuments,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$RagCacheEntriesTableOrderingComposer
    extends Composer<_$RagDatabase, $RagCacheEntriesTable> {
  $$RagCacheEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastAccessedAt => $composableBuilder(
    column: $table.lastAccessedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$RagDocumentsTableOrderingComposer get documentId {
    final $$RagDocumentsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.documentId,
      referencedTable: $db.ragDocuments,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RagDocumentsTableOrderingComposer(
            $db: $db,
            $table: $db.ragDocuments,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$RagCacheEntriesTableAnnotationComposer
    extends Composer<_$RagDatabase, $RagCacheEntriesTable> {
  $$RagCacheEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get fileName =>
      $composableBuilder(column: $table.fileName, builder: (column) => column);

  GeneratedColumn<int> get sizeBytes =>
      $composableBuilder(column: $table.sizeBytes, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get lastAccessedAt => $composableBuilder(
    column: $table.lastAccessedAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get expiresAt =>
      $composableBuilder(column: $table.expiresAt, builder: (column) => column);

  $$RagDocumentsTableAnnotationComposer get documentId {
    final $$RagDocumentsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.documentId,
      referencedTable: $db.ragDocuments,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RagDocumentsTableAnnotationComposer(
            $db: $db,
            $table: $db.ragDocuments,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$RagCacheEntriesTableTableManager
    extends
        RootTableManager<
          _$RagDatabase,
          $RagCacheEntriesTable,
          RagCacheEntry,
          $$RagCacheEntriesTableFilterComposer,
          $$RagCacheEntriesTableOrderingComposer,
          $$RagCacheEntriesTableAnnotationComposer,
          $$RagCacheEntriesTableCreateCompanionBuilder,
          $$RagCacheEntriesTableUpdateCompanionBuilder,
          (RagCacheEntry, $$RagCacheEntriesTableReferences),
          RagCacheEntry,
          PrefetchHooks Function({bool documentId})
        > {
  $$RagCacheEntriesTableTableManager(
    _$RagDatabase db,
    $RagCacheEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RagCacheEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RagCacheEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RagCacheEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> documentId = const Value.absent(),
                Value<String> fileName = const Value.absent(),
                Value<int> sizeBytes = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> lastAccessedAt = const Value.absent(),
                Value<DateTime> expiresAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RagCacheEntriesCompanion(
                documentId: documentId,
                fileName: fileName,
                sizeBytes: sizeBytes,
                createdAt: createdAt,
                lastAccessedAt: lastAccessedAt,
                expiresAt: expiresAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String documentId,
                required String fileName,
                required int sizeBytes,
                required DateTime createdAt,
                required DateTime lastAccessedAt,
                required DateTime expiresAt,
                Value<int> rowid = const Value.absent(),
              }) => RagCacheEntriesCompanion.insert(
                documentId: documentId,
                fileName: fileName,
                sizeBytes: sizeBytes,
                createdAt: createdAt,
                lastAccessedAt: lastAccessedAt,
                expiresAt: expiresAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$RagCacheEntriesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({documentId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (documentId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.documentId,
                                referencedTable:
                                    $$RagCacheEntriesTableReferences
                                        ._documentIdTable(db),
                                referencedColumn:
                                    $$RagCacheEntriesTableReferences
                                        ._documentIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$RagCacheEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$RagDatabase,
      $RagCacheEntriesTable,
      RagCacheEntry,
      $$RagCacheEntriesTableFilterComposer,
      $$RagCacheEntriesTableOrderingComposer,
      $$RagCacheEntriesTableAnnotationComposer,
      $$RagCacheEntriesTableCreateCompanionBuilder,
      $$RagCacheEntriesTableUpdateCompanionBuilder,
      (RagCacheEntry, $$RagCacheEntriesTableReferences),
      RagCacheEntry,
      PrefetchHooks Function({bool documentId})
    >;

class $RagDatabaseManager {
  final _$RagDatabase _db;
  $RagDatabaseManager(this._db);
  $$RagDocumentsTableTableManager get ragDocuments =>
      $$RagDocumentsTableTableManager(_db, _db.ragDocuments);
  $$RagIndexMetadataTableTableTableManager get ragIndexMetadataTable =>
      $$RagIndexMetadataTableTableTableManager(_db, _db.ragIndexMetadataTable);
  $$RagCacheEntriesTableTableManager get ragCacheEntries =>
      $$RagCacheEntriesTableTableManager(_db, _db.ragCacheEntries);
}

mixin _$RagDaoMixin on DatabaseAccessor<RagDatabase> {
  $RagDocumentsTable get ragDocuments => attachedDatabase.ragDocuments;
  $RagIndexMetadataTableTable get ragIndexMetadataTable =>
      attachedDatabase.ragIndexMetadataTable;
  $RagCacheEntriesTable get ragCacheEntries => attachedDatabase.ragCacheEntries;
  RagDaoManager get managers => RagDaoManager(this);
}

class RagDaoManager {
  final _$RagDaoMixin _db;
  RagDaoManager(this._db);
  $$RagDocumentsTableTableManager get ragDocuments =>
      $$RagDocumentsTableTableManager(_db.attachedDatabase, _db.ragDocuments);
  $$RagIndexMetadataTableTableTableManager get ragIndexMetadataTable =>
      $$RagIndexMetadataTableTableTableManager(
        _db.attachedDatabase,
        _db.ragIndexMetadataTable,
      );
  $$RagCacheEntriesTableTableManager get ragCacheEntries =>
      $$RagCacheEntriesTableTableManager(
        _db.attachedDatabase,
        _db.ragCacheEntries,
      );
}
