// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sftp_database.dart';

// ignore_for_file: type=lint
class $SftpRecentPathsTable extends SftpRecentPaths
    with TableInfo<$SftpRecentPathsTable, SftpRecentPath> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SftpRecentPathsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _connectionIdMeta = const VerificationMeta(
    'connectionId',
  );
  @override
  late final GeneratedColumn<String> connectionId = GeneratedColumn<String>(
    'connection_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
    'path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _visitedAtMeta = const VerificationMeta(
    'visitedAt',
  );
  @override
  late final GeneratedColumn<int> visitedAt = GeneratedColumn<int>(
    'visited_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, connectionId, path, visitedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sftp_recent_paths';
  @override
  VerificationContext validateIntegrity(
    Insertable<SftpRecentPath> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('connection_id')) {
      context.handle(
        _connectionIdMeta,
        connectionId.isAcceptableOrUnknown(
          data['connection_id']!,
          _connectionIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_connectionIdMeta);
    }
    if (data.containsKey('path')) {
      context.handle(
        _pathMeta,
        path.isAcceptableOrUnknown(data['path']!, _pathMeta),
      );
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('visited_at')) {
      context.handle(
        _visitedAtMeta,
        visitedAt.isAcceptableOrUnknown(data['visited_at']!, _visitedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_visitedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SftpRecentPath map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SftpRecentPath(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      connectionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}connection_id'],
      )!,
      path: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}path'],
      )!,
      visitedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}visited_at'],
      )!,
    );
  }

  @override
  $SftpRecentPathsTable createAlias(String alias) {
    return $SftpRecentPathsTable(attachedDatabase, alias);
  }
}

class SftpRecentPath extends DataClass implements Insertable<SftpRecentPath> {
  final String id;
  final String connectionId;
  final String path;
  final int visitedAt;
  const SftpRecentPath({
    required this.id,
    required this.connectionId,
    required this.path,
    required this.visitedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['connection_id'] = Variable<String>(connectionId);
    map['path'] = Variable<String>(path);
    map['visited_at'] = Variable<int>(visitedAt);
    return map;
  }

  SftpRecentPathsCompanion toCompanion(bool nullToAbsent) {
    return SftpRecentPathsCompanion(
      id: Value(id),
      connectionId: Value(connectionId),
      path: Value(path),
      visitedAt: Value(visitedAt),
    );
  }

  factory SftpRecentPath.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SftpRecentPath(
      id: serializer.fromJson<String>(json['id']),
      connectionId: serializer.fromJson<String>(json['connectionId']),
      path: serializer.fromJson<String>(json['path']),
      visitedAt: serializer.fromJson<int>(json['visitedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'connectionId': serializer.toJson<String>(connectionId),
      'path': serializer.toJson<String>(path),
      'visitedAt': serializer.toJson<int>(visitedAt),
    };
  }

  SftpRecentPath copyWith({
    String? id,
    String? connectionId,
    String? path,
    int? visitedAt,
  }) => SftpRecentPath(
    id: id ?? this.id,
    connectionId: connectionId ?? this.connectionId,
    path: path ?? this.path,
    visitedAt: visitedAt ?? this.visitedAt,
  );
  SftpRecentPath copyWithCompanion(SftpRecentPathsCompanion data) {
    return SftpRecentPath(
      id: data.id.present ? data.id.value : this.id,
      connectionId: data.connectionId.present
          ? data.connectionId.value
          : this.connectionId,
      path: data.path.present ? data.path.value : this.path,
      visitedAt: data.visitedAt.present ? data.visitedAt.value : this.visitedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SftpRecentPath(')
          ..write('id: $id, ')
          ..write('connectionId: $connectionId, ')
          ..write('path: $path, ')
          ..write('visitedAt: $visitedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, connectionId, path, visitedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SftpRecentPath &&
          other.id == this.id &&
          other.connectionId == this.connectionId &&
          other.path == this.path &&
          other.visitedAt == this.visitedAt);
}

class SftpRecentPathsCompanion extends UpdateCompanion<SftpRecentPath> {
  final Value<String> id;
  final Value<String> connectionId;
  final Value<String> path;
  final Value<int> visitedAt;
  final Value<int> rowid;
  const SftpRecentPathsCompanion({
    this.id = const Value.absent(),
    this.connectionId = const Value.absent(),
    this.path = const Value.absent(),
    this.visitedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SftpRecentPathsCompanion.insert({
    required String id,
    required String connectionId,
    required String path,
    required int visitedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       connectionId = Value(connectionId),
       path = Value(path),
       visitedAt = Value(visitedAt);
  static Insertable<SftpRecentPath> custom({
    Expression<String>? id,
    Expression<String>? connectionId,
    Expression<String>? path,
    Expression<int>? visitedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (connectionId != null) 'connection_id': connectionId,
      if (path != null) 'path': path,
      if (visitedAt != null) 'visited_at': visitedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SftpRecentPathsCompanion copyWith({
    Value<String>? id,
    Value<String>? connectionId,
    Value<String>? path,
    Value<int>? visitedAt,
    Value<int>? rowid,
  }) {
    return SftpRecentPathsCompanion(
      id: id ?? this.id,
      connectionId: connectionId ?? this.connectionId,
      path: path ?? this.path,
      visitedAt: visitedAt ?? this.visitedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (connectionId.present) {
      map['connection_id'] = Variable<String>(connectionId.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (visitedAt.present) {
      map['visited_at'] = Variable<int>(visitedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SftpRecentPathsCompanion(')
          ..write('id: $id, ')
          ..write('connectionId: $connectionId, ')
          ..write('path: $path, ')
          ..write('visitedAt: $visitedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SftpFavoritePathsTable extends SftpFavoritePaths
    with TableInfo<$SftpFavoritePathsTable, SftpFavoritePath> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SftpFavoritePathsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _connectionIdMeta = const VerificationMeta(
    'connectionId',
  );
  @override
  late final GeneratedColumn<String> connectionId = GeneratedColumn<String>(
    'connection_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
    'path',
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
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    connectionId,
    path,
    name,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sftp_favorite_paths';
  @override
  VerificationContext validateIntegrity(
    Insertable<SftpFavoritePath> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('connection_id')) {
      context.handle(
        _connectionIdMeta,
        connectionId.isAcceptableOrUnknown(
          data['connection_id']!,
          _connectionIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_connectionIdMeta);
    }
    if (data.containsKey('path')) {
      context.handle(
        _pathMeta,
        path.isAcceptableOrUnknown(data['path']!, _pathMeta),
      );
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
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
  SftpFavoritePath map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SftpFavoritePath(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      connectionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}connection_id'],
      )!,
      path: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}path'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $SftpFavoritePathsTable createAlias(String alias) {
    return $SftpFavoritePathsTable(attachedDatabase, alias);
  }
}

class SftpFavoritePath extends DataClass
    implements Insertable<SftpFavoritePath> {
  final String id;
  final String connectionId;
  final String path;
  final String name;
  final int createdAt;
  final int updatedAt;
  const SftpFavoritePath({
    required this.id,
    required this.connectionId,
    required this.path,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['connection_id'] = Variable<String>(connectionId);
    map['path'] = Variable<String>(path);
    map['name'] = Variable<String>(name);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  SftpFavoritePathsCompanion toCompanion(bool nullToAbsent) {
    return SftpFavoritePathsCompanion(
      id: Value(id),
      connectionId: Value(connectionId),
      path: Value(path),
      name: Value(name),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory SftpFavoritePath.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SftpFavoritePath(
      id: serializer.fromJson<String>(json['id']),
      connectionId: serializer.fromJson<String>(json['connectionId']),
      path: serializer.fromJson<String>(json['path']),
      name: serializer.fromJson<String>(json['name']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'connectionId': serializer.toJson<String>(connectionId),
      'path': serializer.toJson<String>(path),
      'name': serializer.toJson<String>(name),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  SftpFavoritePath copyWith({
    String? id,
    String? connectionId,
    String? path,
    String? name,
    int? createdAt,
    int? updatedAt,
  }) => SftpFavoritePath(
    id: id ?? this.id,
    connectionId: connectionId ?? this.connectionId,
    path: path ?? this.path,
    name: name ?? this.name,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  SftpFavoritePath copyWithCompanion(SftpFavoritePathsCompanion data) {
    return SftpFavoritePath(
      id: data.id.present ? data.id.value : this.id,
      connectionId: data.connectionId.present
          ? data.connectionId.value
          : this.connectionId,
      path: data.path.present ? data.path.value : this.path,
      name: data.name.present ? data.name.value : this.name,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SftpFavoritePath(')
          ..write('id: $id, ')
          ..write('connectionId: $connectionId, ')
          ..write('path: $path, ')
          ..write('name: $name, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, connectionId, path, name, createdAt, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SftpFavoritePath &&
          other.id == this.id &&
          other.connectionId == this.connectionId &&
          other.path == this.path &&
          other.name == this.name &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class SftpFavoritePathsCompanion extends UpdateCompanion<SftpFavoritePath> {
  final Value<String> id;
  final Value<String> connectionId;
  final Value<String> path;
  final Value<String> name;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const SftpFavoritePathsCompanion({
    this.id = const Value.absent(),
    this.connectionId = const Value.absent(),
    this.path = const Value.absent(),
    this.name = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SftpFavoritePathsCompanion.insert({
    required String id,
    required String connectionId,
    required String path,
    required String name,
    required int createdAt,
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       connectionId = Value(connectionId),
       path = Value(path),
       name = Value(name),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<SftpFavoritePath> custom({
    Expression<String>? id,
    Expression<String>? connectionId,
    Expression<String>? path,
    Expression<String>? name,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (connectionId != null) 'connection_id': connectionId,
      if (path != null) 'path': path,
      if (name != null) 'name': name,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SftpFavoritePathsCompanion copyWith({
    Value<String>? id,
    Value<String>? connectionId,
    Value<String>? path,
    Value<String>? name,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return SftpFavoritePathsCompanion(
      id: id ?? this.id,
      connectionId: connectionId ?? this.connectionId,
      path: path ?? this.path,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
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
    if (connectionId.present) {
      map['connection_id'] = Variable<String>(connectionId.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SftpFavoritePathsCompanion(')
          ..write('id: $id, ')
          ..write('connectionId: $connectionId, ')
          ..write('path: $path, ')
          ..write('name: $name, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$SftpDatabase extends GeneratedDatabase {
  _$SftpDatabase(QueryExecutor e) : super(e);
  $SftpDatabaseManager get managers => $SftpDatabaseManager(this);
  late final $SftpRecentPathsTable sftpRecentPaths = $SftpRecentPathsTable(
    this,
  );
  late final $SftpFavoritePathsTable sftpFavoritePaths =
      $SftpFavoritePathsTable(this);
  late final SftpPathHistoryDao sftpPathHistoryDao = SftpPathHistoryDao(
    this as SftpDatabase,
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    sftpRecentPaths,
    sftpFavoritePaths,
  ];
}

typedef $$SftpRecentPathsTableCreateCompanionBuilder =
    SftpRecentPathsCompanion Function({
      required String id,
      required String connectionId,
      required String path,
      required int visitedAt,
      Value<int> rowid,
    });
typedef $$SftpRecentPathsTableUpdateCompanionBuilder =
    SftpRecentPathsCompanion Function({
      Value<String> id,
      Value<String> connectionId,
      Value<String> path,
      Value<int> visitedAt,
      Value<int> rowid,
    });

class $$SftpRecentPathsTableFilterComposer
    extends Composer<_$SftpDatabase, $SftpRecentPathsTable> {
  $$SftpRecentPathsTableFilterComposer({
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

  ColumnFilters<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get visitedAt => $composableBuilder(
    column: $table.visitedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SftpRecentPathsTableOrderingComposer
    extends Composer<_$SftpDatabase, $SftpRecentPathsTable> {
  $$SftpRecentPathsTableOrderingComposer({
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

  ColumnOrderings<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get visitedAt => $composableBuilder(
    column: $table.visitedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SftpRecentPathsTableAnnotationComposer
    extends Composer<_$SftpDatabase, $SftpRecentPathsTable> {
  $$SftpRecentPathsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<int> get visitedAt =>
      $composableBuilder(column: $table.visitedAt, builder: (column) => column);
}

class $$SftpRecentPathsTableTableManager
    extends
        RootTableManager<
          _$SftpDatabase,
          $SftpRecentPathsTable,
          SftpRecentPath,
          $$SftpRecentPathsTableFilterComposer,
          $$SftpRecentPathsTableOrderingComposer,
          $$SftpRecentPathsTableAnnotationComposer,
          $$SftpRecentPathsTableCreateCompanionBuilder,
          $$SftpRecentPathsTableUpdateCompanionBuilder,
          (
            SftpRecentPath,
            BaseReferences<
              _$SftpDatabase,
              $SftpRecentPathsTable,
              SftpRecentPath
            >,
          ),
          SftpRecentPath,
          PrefetchHooks Function()
        > {
  $$SftpRecentPathsTableTableManager(
    _$SftpDatabase db,
    $SftpRecentPathsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SftpRecentPathsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SftpRecentPathsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SftpRecentPathsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> connectionId = const Value.absent(),
                Value<String> path = const Value.absent(),
                Value<int> visitedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SftpRecentPathsCompanion(
                id: id,
                connectionId: connectionId,
                path: path,
                visitedAt: visitedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String connectionId,
                required String path,
                required int visitedAt,
                Value<int> rowid = const Value.absent(),
              }) => SftpRecentPathsCompanion.insert(
                id: id,
                connectionId: connectionId,
                path: path,
                visitedAt: visitedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SftpRecentPathsTableProcessedTableManager =
    ProcessedTableManager<
      _$SftpDatabase,
      $SftpRecentPathsTable,
      SftpRecentPath,
      $$SftpRecentPathsTableFilterComposer,
      $$SftpRecentPathsTableOrderingComposer,
      $$SftpRecentPathsTableAnnotationComposer,
      $$SftpRecentPathsTableCreateCompanionBuilder,
      $$SftpRecentPathsTableUpdateCompanionBuilder,
      (
        SftpRecentPath,
        BaseReferences<_$SftpDatabase, $SftpRecentPathsTable, SftpRecentPath>,
      ),
      SftpRecentPath,
      PrefetchHooks Function()
    >;
typedef $$SftpFavoritePathsTableCreateCompanionBuilder =
    SftpFavoritePathsCompanion Function({
      required String id,
      required String connectionId,
      required String path,
      required String name,
      required int createdAt,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$SftpFavoritePathsTableUpdateCompanionBuilder =
    SftpFavoritePathsCompanion Function({
      Value<String> id,
      Value<String> connectionId,
      Value<String> path,
      Value<String> name,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int> rowid,
    });

class $$SftpFavoritePathsTableFilterComposer
    extends Composer<_$SftpDatabase, $SftpFavoritePathsTable> {
  $$SftpFavoritePathsTableFilterComposer({
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

  ColumnFilters<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SftpFavoritePathsTableOrderingComposer
    extends Composer<_$SftpDatabase, $SftpFavoritePathsTable> {
  $$SftpFavoritePathsTableOrderingComposer({
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

  ColumnOrderings<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SftpFavoritePathsTableAnnotationComposer
    extends Composer<_$SftpDatabase, $SftpFavoritePathsTable> {
  $$SftpFavoritePathsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$SftpFavoritePathsTableTableManager
    extends
        RootTableManager<
          _$SftpDatabase,
          $SftpFavoritePathsTable,
          SftpFavoritePath,
          $$SftpFavoritePathsTableFilterComposer,
          $$SftpFavoritePathsTableOrderingComposer,
          $$SftpFavoritePathsTableAnnotationComposer,
          $$SftpFavoritePathsTableCreateCompanionBuilder,
          $$SftpFavoritePathsTableUpdateCompanionBuilder,
          (
            SftpFavoritePath,
            BaseReferences<
              _$SftpDatabase,
              $SftpFavoritePathsTable,
              SftpFavoritePath
            >,
          ),
          SftpFavoritePath,
          PrefetchHooks Function()
        > {
  $$SftpFavoritePathsTableTableManager(
    _$SftpDatabase db,
    $SftpFavoritePathsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SftpFavoritePathsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SftpFavoritePathsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SftpFavoritePathsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> connectionId = const Value.absent(),
                Value<String> path = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SftpFavoritePathsCompanion(
                id: id,
                connectionId: connectionId,
                path: path,
                name: name,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String connectionId,
                required String path,
                required String name,
                required int createdAt,
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => SftpFavoritePathsCompanion.insert(
                id: id,
                connectionId: connectionId,
                path: path,
                name: name,
                createdAt: createdAt,
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

typedef $$SftpFavoritePathsTableProcessedTableManager =
    ProcessedTableManager<
      _$SftpDatabase,
      $SftpFavoritePathsTable,
      SftpFavoritePath,
      $$SftpFavoritePathsTableFilterComposer,
      $$SftpFavoritePathsTableOrderingComposer,
      $$SftpFavoritePathsTableAnnotationComposer,
      $$SftpFavoritePathsTableCreateCompanionBuilder,
      $$SftpFavoritePathsTableUpdateCompanionBuilder,
      (
        SftpFavoritePath,
        BaseReferences<
          _$SftpDatabase,
          $SftpFavoritePathsTable,
          SftpFavoritePath
        >,
      ),
      SftpFavoritePath,
      PrefetchHooks Function()
    >;

class $SftpDatabaseManager {
  final _$SftpDatabase _db;
  $SftpDatabaseManager(this._db);
  $$SftpRecentPathsTableTableManager get sftpRecentPaths =>
      $$SftpRecentPathsTableTableManager(_db, _db.sftpRecentPaths);
  $$SftpFavoritePathsTableTableManager get sftpFavoritePaths =>
      $$SftpFavoritePathsTableTableManager(_db, _db.sftpFavoritePaths);
}

mixin _$SftpPathHistoryDaoMixin on DatabaseAccessor<SftpDatabase> {
  $SftpRecentPathsTable get sftpRecentPaths => attachedDatabase.sftpRecentPaths;
  $SftpFavoritePathsTable get sftpFavoritePaths =>
      attachedDatabase.sftpFavoritePaths;
  SftpPathHistoryDaoManager get managers => SftpPathHistoryDaoManager(this);
}

class SftpPathHistoryDaoManager {
  final _$SftpPathHistoryDaoMixin _db;
  SftpPathHistoryDaoManager(this._db);
  $$SftpRecentPathsTableTableManager get sftpRecentPaths =>
      $$SftpRecentPathsTableTableManager(
        _db.attachedDatabase,
        _db.sftpRecentPaths,
      );
  $$SftpFavoritePathsTableTableManager get sftpFavoritePaths =>
      $$SftpFavoritePathsTableTableManager(
        _db.attachedDatabase,
        _db.sftpFavoritePaths,
      );
}
