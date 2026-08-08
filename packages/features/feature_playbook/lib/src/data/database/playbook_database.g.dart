// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'playbook_database.dart';

// ignore_for_file: type=lint
class $PlaybooksTable extends Playbooks
    with TableInfo<$PlaybooksTable, Playbook> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlaybooksTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _descriptionMeta = const VerificationMeta(
    'description',
  );
  @override
  late final GeneratedColumn<String> description = GeneratedColumn<String>(
    'description',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _contentJsonMeta = const VerificationMeta(
    'contentJson',
  );
  @override
  late final GeneratedColumn<String> contentJson = GeneratedColumn<String>(
    'content_json',
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
    name,
    description,
    contentJson,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'playbooks';
  @override
  VerificationContext validateIntegrity(
    Insertable<Playbook> instance, {
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
    if (data.containsKey('description')) {
      context.handle(
        _descriptionMeta,
        description.isAcceptableOrUnknown(
          data['description']!,
          _descriptionMeta,
        ),
      );
    }
    if (data.containsKey('content_json')) {
      context.handle(
        _contentJsonMeta,
        contentJson.isAcceptableOrUnknown(
          data['content_json']!,
          _contentJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_contentJsonMeta);
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
  Playbook map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Playbook(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      description: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}description'],
      )!,
      contentJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_json'],
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
  $PlaybooksTable createAlias(String alias) {
    return $PlaybooksTable(attachedDatabase, alias);
  }
}

class Playbook extends DataClass implements Insertable<Playbook> {
  final String id;
  final String name;
  final String description;
  final String contentJson;
  final int createdAt;
  final int updatedAt;
  const Playbook({
    required this.id,
    required this.name,
    required this.description,
    required this.contentJson,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['description'] = Variable<String>(description);
    map['content_json'] = Variable<String>(contentJson);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  PlaybooksCompanion toCompanion(bool nullToAbsent) {
    return PlaybooksCompanion(
      id: Value(id),
      name: Value(name),
      description: Value(description),
      contentJson: Value(contentJson),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory Playbook.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Playbook(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      description: serializer.fromJson<String>(json['description']),
      contentJson: serializer.fromJson<String>(json['contentJson']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'description': serializer.toJson<String>(description),
      'contentJson': serializer.toJson<String>(contentJson),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  Playbook copyWith({
    String? id,
    String? name,
    String? description,
    String? contentJson,
    int? createdAt,
    int? updatedAt,
  }) => Playbook(
    id: id ?? this.id,
    name: name ?? this.name,
    description: description ?? this.description,
    contentJson: contentJson ?? this.contentJson,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  Playbook copyWithCompanion(PlaybooksCompanion data) {
    return Playbook(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      description: data.description.present
          ? data.description.value
          : this.description,
      contentJson: data.contentJson.present
          ? data.contentJson.value
          : this.contentJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Playbook(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('description: $description, ')
          ..write('contentJson: $contentJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, name, description, contentJson, createdAt, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Playbook &&
          other.id == this.id &&
          other.name == this.name &&
          other.description == this.description &&
          other.contentJson == this.contentJson &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class PlaybooksCompanion extends UpdateCompanion<Playbook> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> description;
  final Value<String> contentJson;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const PlaybooksCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.description = const Value.absent(),
    this.contentJson = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PlaybooksCompanion.insert({
    required String id,
    required String name,
    this.description = const Value.absent(),
    required String contentJson,
    required int createdAt,
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       contentJson = Value(contentJson),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<Playbook> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? description,
    Expression<String>? contentJson,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (description != null) 'description': description,
      if (contentJson != null) 'content_json': contentJson,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PlaybooksCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String>? description,
    Value<String>? contentJson,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return PlaybooksCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      contentJson: contentJson ?? this.contentJson,
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
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (description.present) {
      map['description'] = Variable<String>(description.value);
    }
    if (contentJson.present) {
      map['content_json'] = Variable<String>(contentJson.value);
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
    return (StringBuffer('PlaybooksCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('description: $description, ')
          ..write('contentJson: $contentJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PlaybookRunsTable extends PlaybookRuns
    with TableInfo<$PlaybookRunsTable, PlaybookRun> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlaybookRunsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _playbookIdMeta = const VerificationMeta(
    'playbookId',
  );
  @override
  late final GeneratedColumn<String> playbookId = GeneratedColumn<String>(
    'playbook_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES playbooks (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _connectionIdMeta = const VerificationMeta(
    'connectionId',
  );
  @override
  late final GeneratedColumn<String> connectionId = GeneratedColumn<String>(
    'connection_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _startedAtMeta = const VerificationMeta(
    'startedAt',
  );
  @override
  late final GeneratedColumn<int> startedAt = GeneratedColumn<int>(
    'started_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _finishedAtMeta = const VerificationMeta(
    'finishedAt',
  );
  @override
  late final GeneratedColumn<int> finishedAt = GeneratedColumn<int>(
    'finished_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _summaryMeta = const VerificationMeta(
    'summary',
  );
  @override
  late final GeneratedColumn<String> summary = GeneratedColumn<String>(
    'summary',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _errorMessageMeta = const VerificationMeta(
    'errorMessage',
  );
  @override
  late final GeneratedColumn<String> errorMessage = GeneratedColumn<String>(
    'error_message',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    playbookId,
    connectionId,
    status,
    startedAt,
    finishedAt,
    summary,
    errorMessage,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'playbook_runs';
  @override
  VerificationContext validateIntegrity(
    Insertable<PlaybookRun> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('playbook_id')) {
      context.handle(
        _playbookIdMeta,
        playbookId.isAcceptableOrUnknown(data['playbook_id']!, _playbookIdMeta),
      );
    } else if (isInserting) {
      context.missing(_playbookIdMeta);
    }
    if (data.containsKey('connection_id')) {
      context.handle(
        _connectionIdMeta,
        connectionId.isAcceptableOrUnknown(
          data['connection_id']!,
          _connectionIdMeta,
        ),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('started_at')) {
      context.handle(
        _startedAtMeta,
        startedAt.isAcceptableOrUnknown(data['started_at']!, _startedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_startedAtMeta);
    }
    if (data.containsKey('finished_at')) {
      context.handle(
        _finishedAtMeta,
        finishedAt.isAcceptableOrUnknown(data['finished_at']!, _finishedAtMeta),
      );
    }
    if (data.containsKey('summary')) {
      context.handle(
        _summaryMeta,
        summary.isAcceptableOrUnknown(data['summary']!, _summaryMeta),
      );
    }
    if (data.containsKey('error_message')) {
      context.handle(
        _errorMessageMeta,
        errorMessage.isAcceptableOrUnknown(
          data['error_message']!,
          _errorMessageMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PlaybookRun map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlaybookRun(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      playbookId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}playbook_id'],
      )!,
      connectionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}connection_id'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      startedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}started_at'],
      )!,
      finishedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}finished_at'],
      ),
      summary: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}summary'],
      )!,
      errorMessage: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}error_message'],
      ),
    );
  }

  @override
  $PlaybookRunsTable createAlias(String alias) {
    return $PlaybookRunsTable(attachedDatabase, alias);
  }
}

class PlaybookRun extends DataClass implements Insertable<PlaybookRun> {
  final String id;
  final String playbookId;
  final String? connectionId;
  final String status;
  final int startedAt;
  final int? finishedAt;
  final String summary;
  final String? errorMessage;
  const PlaybookRun({
    required this.id,
    required this.playbookId,
    this.connectionId,
    required this.status,
    required this.startedAt,
    this.finishedAt,
    required this.summary,
    this.errorMessage,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['playbook_id'] = Variable<String>(playbookId);
    if (!nullToAbsent || connectionId != null) {
      map['connection_id'] = Variable<String>(connectionId);
    }
    map['status'] = Variable<String>(status);
    map['started_at'] = Variable<int>(startedAt);
    if (!nullToAbsent || finishedAt != null) {
      map['finished_at'] = Variable<int>(finishedAt);
    }
    map['summary'] = Variable<String>(summary);
    if (!nullToAbsent || errorMessage != null) {
      map['error_message'] = Variable<String>(errorMessage);
    }
    return map;
  }

  PlaybookRunsCompanion toCompanion(bool nullToAbsent) {
    return PlaybookRunsCompanion(
      id: Value(id),
      playbookId: Value(playbookId),
      connectionId: connectionId == null && nullToAbsent
          ? const Value.absent()
          : Value(connectionId),
      status: Value(status),
      startedAt: Value(startedAt),
      finishedAt: finishedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(finishedAt),
      summary: Value(summary),
      errorMessage: errorMessage == null && nullToAbsent
          ? const Value.absent()
          : Value(errorMessage),
    );
  }

  factory PlaybookRun.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PlaybookRun(
      id: serializer.fromJson<String>(json['id']),
      playbookId: serializer.fromJson<String>(json['playbookId']),
      connectionId: serializer.fromJson<String?>(json['connectionId']),
      status: serializer.fromJson<String>(json['status']),
      startedAt: serializer.fromJson<int>(json['startedAt']),
      finishedAt: serializer.fromJson<int?>(json['finishedAt']),
      summary: serializer.fromJson<String>(json['summary']),
      errorMessage: serializer.fromJson<String?>(json['errorMessage']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'playbookId': serializer.toJson<String>(playbookId),
      'connectionId': serializer.toJson<String?>(connectionId),
      'status': serializer.toJson<String>(status),
      'startedAt': serializer.toJson<int>(startedAt),
      'finishedAt': serializer.toJson<int?>(finishedAt),
      'summary': serializer.toJson<String>(summary),
      'errorMessage': serializer.toJson<String?>(errorMessage),
    };
  }

  PlaybookRun copyWith({
    String? id,
    String? playbookId,
    Value<String?> connectionId = const Value.absent(),
    String? status,
    int? startedAt,
    Value<int?> finishedAt = const Value.absent(),
    String? summary,
    Value<String?> errorMessage = const Value.absent(),
  }) => PlaybookRun(
    id: id ?? this.id,
    playbookId: playbookId ?? this.playbookId,
    connectionId: connectionId.present ? connectionId.value : this.connectionId,
    status: status ?? this.status,
    startedAt: startedAt ?? this.startedAt,
    finishedAt: finishedAt.present ? finishedAt.value : this.finishedAt,
    summary: summary ?? this.summary,
    errorMessage: errorMessage.present ? errorMessage.value : this.errorMessage,
  );
  PlaybookRun copyWithCompanion(PlaybookRunsCompanion data) {
    return PlaybookRun(
      id: data.id.present ? data.id.value : this.id,
      playbookId: data.playbookId.present
          ? data.playbookId.value
          : this.playbookId,
      connectionId: data.connectionId.present
          ? data.connectionId.value
          : this.connectionId,
      status: data.status.present ? data.status.value : this.status,
      startedAt: data.startedAt.present ? data.startedAt.value : this.startedAt,
      finishedAt: data.finishedAt.present
          ? data.finishedAt.value
          : this.finishedAt,
      summary: data.summary.present ? data.summary.value : this.summary,
      errorMessage: data.errorMessage.present
          ? data.errorMessage.value
          : this.errorMessage,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlaybookRun(')
          ..write('id: $id, ')
          ..write('playbookId: $playbookId, ')
          ..write('connectionId: $connectionId, ')
          ..write('status: $status, ')
          ..write('startedAt: $startedAt, ')
          ..write('finishedAt: $finishedAt, ')
          ..write('summary: $summary, ')
          ..write('errorMessage: $errorMessage')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    playbookId,
    connectionId,
    status,
    startedAt,
    finishedAt,
    summary,
    errorMessage,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlaybookRun &&
          other.id == this.id &&
          other.playbookId == this.playbookId &&
          other.connectionId == this.connectionId &&
          other.status == this.status &&
          other.startedAt == this.startedAt &&
          other.finishedAt == this.finishedAt &&
          other.summary == this.summary &&
          other.errorMessage == this.errorMessage);
}

class PlaybookRunsCompanion extends UpdateCompanion<PlaybookRun> {
  final Value<String> id;
  final Value<String> playbookId;
  final Value<String?> connectionId;
  final Value<String> status;
  final Value<int> startedAt;
  final Value<int?> finishedAt;
  final Value<String> summary;
  final Value<String?> errorMessage;
  final Value<int> rowid;
  const PlaybookRunsCompanion({
    this.id = const Value.absent(),
    this.playbookId = const Value.absent(),
    this.connectionId = const Value.absent(),
    this.status = const Value.absent(),
    this.startedAt = const Value.absent(),
    this.finishedAt = const Value.absent(),
    this.summary = const Value.absent(),
    this.errorMessage = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PlaybookRunsCompanion.insert({
    required String id,
    required String playbookId,
    this.connectionId = const Value.absent(),
    required String status,
    required int startedAt,
    this.finishedAt = const Value.absent(),
    this.summary = const Value.absent(),
    this.errorMessage = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       playbookId = Value(playbookId),
       status = Value(status),
       startedAt = Value(startedAt);
  static Insertable<PlaybookRun> custom({
    Expression<String>? id,
    Expression<String>? playbookId,
    Expression<String>? connectionId,
    Expression<String>? status,
    Expression<int>? startedAt,
    Expression<int>? finishedAt,
    Expression<String>? summary,
    Expression<String>? errorMessage,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (playbookId != null) 'playbook_id': playbookId,
      if (connectionId != null) 'connection_id': connectionId,
      if (status != null) 'status': status,
      if (startedAt != null) 'started_at': startedAt,
      if (finishedAt != null) 'finished_at': finishedAt,
      if (summary != null) 'summary': summary,
      if (errorMessage != null) 'error_message': errorMessage,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PlaybookRunsCompanion copyWith({
    Value<String>? id,
    Value<String>? playbookId,
    Value<String?>? connectionId,
    Value<String>? status,
    Value<int>? startedAt,
    Value<int?>? finishedAt,
    Value<String>? summary,
    Value<String?>? errorMessage,
    Value<int>? rowid,
  }) {
    return PlaybookRunsCompanion(
      id: id ?? this.id,
      playbookId: playbookId ?? this.playbookId,
      connectionId: connectionId ?? this.connectionId,
      status: status ?? this.status,
      startedAt: startedAt ?? this.startedAt,
      finishedAt: finishedAt ?? this.finishedAt,
      summary: summary ?? this.summary,
      errorMessage: errorMessage ?? this.errorMessage,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (playbookId.present) {
      map['playbook_id'] = Variable<String>(playbookId.value);
    }
    if (connectionId.present) {
      map['connection_id'] = Variable<String>(connectionId.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (startedAt.present) {
      map['started_at'] = Variable<int>(startedAt.value);
    }
    if (finishedAt.present) {
      map['finished_at'] = Variable<int>(finishedAt.value);
    }
    if (summary.present) {
      map['summary'] = Variable<String>(summary.value);
    }
    if (errorMessage.present) {
      map['error_message'] = Variable<String>(errorMessage.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlaybookRunsCompanion(')
          ..write('id: $id, ')
          ..write('playbookId: $playbookId, ')
          ..write('connectionId: $connectionId, ')
          ..write('status: $status, ')
          ..write('startedAt: $startedAt, ')
          ..write('finishedAt: $finishedAt, ')
          ..write('summary: $summary, ')
          ..write('errorMessage: $errorMessage, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PlaybookRunStepsTable extends PlaybookRunSteps
    with TableInfo<$PlaybookRunStepsTable, PlaybookRunStep> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlaybookRunStepsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _runIdMeta = const VerificationMeta('runId');
  @override
  late final GeneratedColumn<String> runId = GeneratedColumn<String>(
    'run_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES playbook_runs (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _stepIndexMeta = const VerificationMeta(
    'stepIndex',
  );
  @override
  late final GeneratedColumn<int> stepIndex = GeneratedColumn<int>(
    'step_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentJsonMeta = const VerificationMeta(
    'contentJson',
  );
  @override
  late final GeneratedColumn<String> contentJson = GeneratedColumn<String>(
    'content_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, runId, stepIndex, contentJson];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'playbook_run_steps';
  @override
  VerificationContext validateIntegrity(
    Insertable<PlaybookRunStep> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('run_id')) {
      context.handle(
        _runIdMeta,
        runId.isAcceptableOrUnknown(data['run_id']!, _runIdMeta),
      );
    } else if (isInserting) {
      context.missing(_runIdMeta);
    }
    if (data.containsKey('step_index')) {
      context.handle(
        _stepIndexMeta,
        stepIndex.isAcceptableOrUnknown(data['step_index']!, _stepIndexMeta),
      );
    } else if (isInserting) {
      context.missing(_stepIndexMeta);
    }
    if (data.containsKey('content_json')) {
      context.handle(
        _contentJsonMeta,
        contentJson.isAcceptableOrUnknown(
          data['content_json']!,
          _contentJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_contentJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PlaybookRunStep map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlaybookRunStep(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      runId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}run_id'],
      )!,
      stepIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}step_index'],
      )!,
      contentJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_json'],
      )!,
    );
  }

  @override
  $PlaybookRunStepsTable createAlias(String alias) {
    return $PlaybookRunStepsTable(attachedDatabase, alias);
  }
}

class PlaybookRunStep extends DataClass implements Insertable<PlaybookRunStep> {
  final String id;
  final String runId;
  final int stepIndex;
  final String contentJson;
  const PlaybookRunStep({
    required this.id,
    required this.runId,
    required this.stepIndex,
    required this.contentJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['run_id'] = Variable<String>(runId);
    map['step_index'] = Variable<int>(stepIndex);
    map['content_json'] = Variable<String>(contentJson);
    return map;
  }

  PlaybookRunStepsCompanion toCompanion(bool nullToAbsent) {
    return PlaybookRunStepsCompanion(
      id: Value(id),
      runId: Value(runId),
      stepIndex: Value(stepIndex),
      contentJson: Value(contentJson),
    );
  }

  factory PlaybookRunStep.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PlaybookRunStep(
      id: serializer.fromJson<String>(json['id']),
      runId: serializer.fromJson<String>(json['runId']),
      stepIndex: serializer.fromJson<int>(json['stepIndex']),
      contentJson: serializer.fromJson<String>(json['contentJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'runId': serializer.toJson<String>(runId),
      'stepIndex': serializer.toJson<int>(stepIndex),
      'contentJson': serializer.toJson<String>(contentJson),
    };
  }

  PlaybookRunStep copyWith({
    String? id,
    String? runId,
    int? stepIndex,
    String? contentJson,
  }) => PlaybookRunStep(
    id: id ?? this.id,
    runId: runId ?? this.runId,
    stepIndex: stepIndex ?? this.stepIndex,
    contentJson: contentJson ?? this.contentJson,
  );
  PlaybookRunStep copyWithCompanion(PlaybookRunStepsCompanion data) {
    return PlaybookRunStep(
      id: data.id.present ? data.id.value : this.id,
      runId: data.runId.present ? data.runId.value : this.runId,
      stepIndex: data.stepIndex.present ? data.stepIndex.value : this.stepIndex,
      contentJson: data.contentJson.present
          ? data.contentJson.value
          : this.contentJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlaybookRunStep(')
          ..write('id: $id, ')
          ..write('runId: $runId, ')
          ..write('stepIndex: $stepIndex, ')
          ..write('contentJson: $contentJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, runId, stepIndex, contentJson);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlaybookRunStep &&
          other.id == this.id &&
          other.runId == this.runId &&
          other.stepIndex == this.stepIndex &&
          other.contentJson == this.contentJson);
}

class PlaybookRunStepsCompanion extends UpdateCompanion<PlaybookRunStep> {
  final Value<String> id;
  final Value<String> runId;
  final Value<int> stepIndex;
  final Value<String> contentJson;
  final Value<int> rowid;
  const PlaybookRunStepsCompanion({
    this.id = const Value.absent(),
    this.runId = const Value.absent(),
    this.stepIndex = const Value.absent(),
    this.contentJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PlaybookRunStepsCompanion.insert({
    required String id,
    required String runId,
    required int stepIndex,
    required String contentJson,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       runId = Value(runId),
       stepIndex = Value(stepIndex),
       contentJson = Value(contentJson);
  static Insertable<PlaybookRunStep> custom({
    Expression<String>? id,
    Expression<String>? runId,
    Expression<int>? stepIndex,
    Expression<String>? contentJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (runId != null) 'run_id': runId,
      if (stepIndex != null) 'step_index': stepIndex,
      if (contentJson != null) 'content_json': contentJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PlaybookRunStepsCompanion copyWith({
    Value<String>? id,
    Value<String>? runId,
    Value<int>? stepIndex,
    Value<String>? contentJson,
    Value<int>? rowid,
  }) {
    return PlaybookRunStepsCompanion(
      id: id ?? this.id,
      runId: runId ?? this.runId,
      stepIndex: stepIndex ?? this.stepIndex,
      contentJson: contentJson ?? this.contentJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (runId.present) {
      map['run_id'] = Variable<String>(runId.value);
    }
    if (stepIndex.present) {
      map['step_index'] = Variable<int>(stepIndex.value);
    }
    if (contentJson.present) {
      map['content_json'] = Variable<String>(contentJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlaybookRunStepsCompanion(')
          ..write('id: $id, ')
          ..write('runId: $runId, ')
          ..write('stepIndex: $stepIndex, ')
          ..write('contentJson: $contentJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$PlaybookDatabase extends GeneratedDatabase {
  _$PlaybookDatabase(QueryExecutor e) : super(e);
  $PlaybookDatabaseManager get managers => $PlaybookDatabaseManager(this);
  late final $PlaybooksTable playbooks = $PlaybooksTable(this);
  late final $PlaybookRunsTable playbookRuns = $PlaybookRunsTable(this);
  late final $PlaybookRunStepsTable playbookRunSteps = $PlaybookRunStepsTable(
    this,
  );
  late final PlaybookDao playbookDao = PlaybookDao(this as PlaybookDatabase);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    playbooks,
    playbookRuns,
    playbookRunSteps,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'playbooks',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('playbook_runs', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'playbook_runs',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('playbook_run_steps', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$PlaybooksTableCreateCompanionBuilder =
    PlaybooksCompanion Function({
      required String id,
      required String name,
      Value<String> description,
      required String contentJson,
      required int createdAt,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$PlaybooksTableUpdateCompanionBuilder =
    PlaybooksCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<String> description,
      Value<String> contentJson,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int> rowid,
    });

final class $$PlaybooksTableReferences
    extends BaseReferences<_$PlaybookDatabase, $PlaybooksTable, Playbook> {
  $$PlaybooksTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$PlaybookRunsTable, List<PlaybookRun>>
  _playbookRunsRefsTable(_$PlaybookDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.playbookRuns,
        aliasName: 'playbooks__id__playbook_runs__playbook_id',
      );

  $$PlaybookRunsTableProcessedTableManager get playbookRunsRefs {
    final manager = $$PlaybookRunsTableTableManager(
      $_db,
      $_db.playbookRuns,
    ).filter((f) => f.playbookId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_playbookRunsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$PlaybooksTableFilterComposer
    extends Composer<_$PlaybookDatabase, $PlaybooksTable> {
  $$PlaybooksTableFilterComposer({
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

  ColumnFilters<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contentJson => $composableBuilder(
    column: $table.contentJson,
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

  Expression<bool> playbookRunsRefs(
    Expression<bool> Function($$PlaybookRunsTableFilterComposer f) f,
  ) {
    final $$PlaybookRunsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.playbookRuns,
      getReferencedColumn: (t) => t.playbookId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlaybookRunsTableFilterComposer(
            $db: $db,
            $table: $db.playbookRuns,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$PlaybooksTableOrderingComposer
    extends Composer<_$PlaybookDatabase, $PlaybooksTable> {
  $$PlaybooksTableOrderingComposer({
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

  ColumnOrderings<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contentJson => $composableBuilder(
    column: $table.contentJson,
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

class $$PlaybooksTableAnnotationComposer
    extends Composer<_$PlaybookDatabase, $PlaybooksTable> {
  $$PlaybooksTableAnnotationComposer({
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

  GeneratedColumn<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => column,
  );

  GeneratedColumn<String> get contentJson => $composableBuilder(
    column: $table.contentJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  Expression<T> playbookRunsRefs<T extends Object>(
    Expression<T> Function($$PlaybookRunsTableAnnotationComposer a) f,
  ) {
    final $$PlaybookRunsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.playbookRuns,
      getReferencedColumn: (t) => t.playbookId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlaybookRunsTableAnnotationComposer(
            $db: $db,
            $table: $db.playbookRuns,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$PlaybooksTableTableManager
    extends
        RootTableManager<
          _$PlaybookDatabase,
          $PlaybooksTable,
          Playbook,
          $$PlaybooksTableFilterComposer,
          $$PlaybooksTableOrderingComposer,
          $$PlaybooksTableAnnotationComposer,
          $$PlaybooksTableCreateCompanionBuilder,
          $$PlaybooksTableUpdateCompanionBuilder,
          (Playbook, $$PlaybooksTableReferences),
          Playbook,
          PrefetchHooks Function({bool playbookRunsRefs})
        > {
  $$PlaybooksTableTableManager(_$PlaybookDatabase db, $PlaybooksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlaybooksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlaybooksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlaybooksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> description = const Value.absent(),
                Value<String> contentJson = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PlaybooksCompanion(
                id: id,
                name: name,
                description: description,
                contentJson: contentJson,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                Value<String> description = const Value.absent(),
                required String contentJson,
                required int createdAt,
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => PlaybooksCompanion.insert(
                id: id,
                name: name,
                description: description,
                contentJson: contentJson,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$PlaybooksTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({playbookRunsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (playbookRunsRefs) db.playbookRuns],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (playbookRunsRefs)
                    await $_getPrefetchedData<
                      Playbook,
                      $PlaybooksTable,
                      PlaybookRun
                    >(
                      currentTable: table,
                      referencedTable: $$PlaybooksTableReferences
                          ._playbookRunsRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$PlaybooksTableReferences(
                            db,
                            table,
                            p0,
                          ).playbookRunsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.playbookId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$PlaybooksTableProcessedTableManager =
    ProcessedTableManager<
      _$PlaybookDatabase,
      $PlaybooksTable,
      Playbook,
      $$PlaybooksTableFilterComposer,
      $$PlaybooksTableOrderingComposer,
      $$PlaybooksTableAnnotationComposer,
      $$PlaybooksTableCreateCompanionBuilder,
      $$PlaybooksTableUpdateCompanionBuilder,
      (Playbook, $$PlaybooksTableReferences),
      Playbook,
      PrefetchHooks Function({bool playbookRunsRefs})
    >;
typedef $$PlaybookRunsTableCreateCompanionBuilder =
    PlaybookRunsCompanion Function({
      required String id,
      required String playbookId,
      Value<String?> connectionId,
      required String status,
      required int startedAt,
      Value<int?> finishedAt,
      Value<String> summary,
      Value<String?> errorMessage,
      Value<int> rowid,
    });
typedef $$PlaybookRunsTableUpdateCompanionBuilder =
    PlaybookRunsCompanion Function({
      Value<String> id,
      Value<String> playbookId,
      Value<String?> connectionId,
      Value<String> status,
      Value<int> startedAt,
      Value<int?> finishedAt,
      Value<String> summary,
      Value<String?> errorMessage,
      Value<int> rowid,
    });

final class $$PlaybookRunsTableReferences
    extends
        BaseReferences<_$PlaybookDatabase, $PlaybookRunsTable, PlaybookRun> {
  $$PlaybookRunsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $PlaybooksTable _playbookIdTable(_$PlaybookDatabase db) =>
      db.playbooks.createAlias('playbook_runs__playbook_id__playbooks__id');

  $$PlaybooksTableProcessedTableManager get playbookId {
    final $_column = $_itemColumn<String>('playbook_id')!;

    final manager = $$PlaybooksTableTableManager(
      $_db,
      $_db.playbooks,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_playbookIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$PlaybookRunStepsTable, List<PlaybookRunStep>>
  _playbookRunStepsRefsTable(_$PlaybookDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.playbookRunSteps,
        aliasName: 'playbook_runs__id__playbook_run_steps__run_id',
      );

  $$PlaybookRunStepsTableProcessedTableManager get playbookRunStepsRefs {
    final manager = $$PlaybookRunStepsTableTableManager(
      $_db,
      $_db.playbookRunSteps,
    ).filter((f) => f.runId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _playbookRunStepsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$PlaybookRunsTableFilterComposer
    extends Composer<_$PlaybookDatabase, $PlaybookRunsTable> {
  $$PlaybookRunsTableFilterComposer({
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

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get summary => $composableBuilder(
    column: $table.summary,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get errorMessage => $composableBuilder(
    column: $table.errorMessage,
    builder: (column) => ColumnFilters(column),
  );

  $$PlaybooksTableFilterComposer get playbookId {
    final $$PlaybooksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.playbookId,
      referencedTable: $db.playbooks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlaybooksTableFilterComposer(
            $db: $db,
            $table: $db.playbooks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> playbookRunStepsRefs(
    Expression<bool> Function($$PlaybookRunStepsTableFilterComposer f) f,
  ) {
    final $$PlaybookRunStepsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.playbookRunSteps,
      getReferencedColumn: (t) => t.runId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlaybookRunStepsTableFilterComposer(
            $db: $db,
            $table: $db.playbookRunSteps,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$PlaybookRunsTableOrderingComposer
    extends Composer<_$PlaybookDatabase, $PlaybookRunsTable> {
  $$PlaybookRunsTableOrderingComposer({
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

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get summary => $composableBuilder(
    column: $table.summary,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get errorMessage => $composableBuilder(
    column: $table.errorMessage,
    builder: (column) => ColumnOrderings(column),
  );

  $$PlaybooksTableOrderingComposer get playbookId {
    final $$PlaybooksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.playbookId,
      referencedTable: $db.playbooks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlaybooksTableOrderingComposer(
            $db: $db,
            $table: $db.playbooks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PlaybookRunsTableAnnotationComposer
    extends Composer<_$PlaybookDatabase, $PlaybookRunsTable> {
  $$PlaybookRunsTableAnnotationComposer({
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

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get startedAt =>
      $composableBuilder(column: $table.startedAt, builder: (column) => column);

  GeneratedColumn<int> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get summary =>
      $composableBuilder(column: $table.summary, builder: (column) => column);

  GeneratedColumn<String> get errorMessage => $composableBuilder(
    column: $table.errorMessage,
    builder: (column) => column,
  );

  $$PlaybooksTableAnnotationComposer get playbookId {
    final $$PlaybooksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.playbookId,
      referencedTable: $db.playbooks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlaybooksTableAnnotationComposer(
            $db: $db,
            $table: $db.playbooks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> playbookRunStepsRefs<T extends Object>(
    Expression<T> Function($$PlaybookRunStepsTableAnnotationComposer a) f,
  ) {
    final $$PlaybookRunStepsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.playbookRunSteps,
      getReferencedColumn: (t) => t.runId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlaybookRunStepsTableAnnotationComposer(
            $db: $db,
            $table: $db.playbookRunSteps,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$PlaybookRunsTableTableManager
    extends
        RootTableManager<
          _$PlaybookDatabase,
          $PlaybookRunsTable,
          PlaybookRun,
          $$PlaybookRunsTableFilterComposer,
          $$PlaybookRunsTableOrderingComposer,
          $$PlaybookRunsTableAnnotationComposer,
          $$PlaybookRunsTableCreateCompanionBuilder,
          $$PlaybookRunsTableUpdateCompanionBuilder,
          (PlaybookRun, $$PlaybookRunsTableReferences),
          PlaybookRun,
          PrefetchHooks Function({bool playbookId, bool playbookRunStepsRefs})
        > {
  $$PlaybookRunsTableTableManager(
    _$PlaybookDatabase db,
    $PlaybookRunsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlaybookRunsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlaybookRunsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlaybookRunsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> playbookId = const Value.absent(),
                Value<String?> connectionId = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> startedAt = const Value.absent(),
                Value<int?> finishedAt = const Value.absent(),
                Value<String> summary = const Value.absent(),
                Value<String?> errorMessage = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PlaybookRunsCompanion(
                id: id,
                playbookId: playbookId,
                connectionId: connectionId,
                status: status,
                startedAt: startedAt,
                finishedAt: finishedAt,
                summary: summary,
                errorMessage: errorMessage,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String playbookId,
                Value<String?> connectionId = const Value.absent(),
                required String status,
                required int startedAt,
                Value<int?> finishedAt = const Value.absent(),
                Value<String> summary = const Value.absent(),
                Value<String?> errorMessage = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PlaybookRunsCompanion.insert(
                id: id,
                playbookId: playbookId,
                connectionId: connectionId,
                status: status,
                startedAt: startedAt,
                finishedAt: finishedAt,
                summary: summary,
                errorMessage: errorMessage,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$PlaybookRunsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({playbookId = false, playbookRunStepsRefs = false}) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (playbookRunStepsRefs) db.playbookRunSteps,
                  ],
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
                        if (playbookId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.playbookId,
                                    referencedTable:
                                        $$PlaybookRunsTableReferences
                                            ._playbookIdTable(db),
                                    referencedColumn:
                                        $$PlaybookRunsTableReferences
                                            ._playbookIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (playbookRunStepsRefs)
                        await $_getPrefetchedData<
                          PlaybookRun,
                          $PlaybookRunsTable,
                          PlaybookRunStep
                        >(
                          currentTable: table,
                          referencedTable: $$PlaybookRunsTableReferences
                              ._playbookRunStepsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$PlaybookRunsTableReferences(
                                db,
                                table,
                                p0,
                              ).playbookRunStepsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.runId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$PlaybookRunsTableProcessedTableManager =
    ProcessedTableManager<
      _$PlaybookDatabase,
      $PlaybookRunsTable,
      PlaybookRun,
      $$PlaybookRunsTableFilterComposer,
      $$PlaybookRunsTableOrderingComposer,
      $$PlaybookRunsTableAnnotationComposer,
      $$PlaybookRunsTableCreateCompanionBuilder,
      $$PlaybookRunsTableUpdateCompanionBuilder,
      (PlaybookRun, $$PlaybookRunsTableReferences),
      PlaybookRun,
      PrefetchHooks Function({bool playbookId, bool playbookRunStepsRefs})
    >;
typedef $$PlaybookRunStepsTableCreateCompanionBuilder =
    PlaybookRunStepsCompanion Function({
      required String id,
      required String runId,
      required int stepIndex,
      required String contentJson,
      Value<int> rowid,
    });
typedef $$PlaybookRunStepsTableUpdateCompanionBuilder =
    PlaybookRunStepsCompanion Function({
      Value<String> id,
      Value<String> runId,
      Value<int> stepIndex,
      Value<String> contentJson,
      Value<int> rowid,
    });

final class $$PlaybookRunStepsTableReferences
    extends
        BaseReferences<
          _$PlaybookDatabase,
          $PlaybookRunStepsTable,
          PlaybookRunStep
        > {
  $$PlaybookRunStepsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $PlaybookRunsTable _runIdTable(_$PlaybookDatabase db) => db
      .playbookRuns
      .createAlias('playbook_run_steps__run_id__playbook_runs__id');

  $$PlaybookRunsTableProcessedTableManager get runId {
    final $_column = $_itemColumn<String>('run_id')!;

    final manager = $$PlaybookRunsTableTableManager(
      $_db,
      $_db.playbookRuns,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_runIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$PlaybookRunStepsTableFilterComposer
    extends Composer<_$PlaybookDatabase, $PlaybookRunStepsTable> {
  $$PlaybookRunStepsTableFilterComposer({
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

  ColumnFilters<int> get stepIndex => $composableBuilder(
    column: $table.stepIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contentJson => $composableBuilder(
    column: $table.contentJson,
    builder: (column) => ColumnFilters(column),
  );

  $$PlaybookRunsTableFilterComposer get runId {
    final $$PlaybookRunsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.runId,
      referencedTable: $db.playbookRuns,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlaybookRunsTableFilterComposer(
            $db: $db,
            $table: $db.playbookRuns,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PlaybookRunStepsTableOrderingComposer
    extends Composer<_$PlaybookDatabase, $PlaybookRunStepsTable> {
  $$PlaybookRunStepsTableOrderingComposer({
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

  ColumnOrderings<int> get stepIndex => $composableBuilder(
    column: $table.stepIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contentJson => $composableBuilder(
    column: $table.contentJson,
    builder: (column) => ColumnOrderings(column),
  );

  $$PlaybookRunsTableOrderingComposer get runId {
    final $$PlaybookRunsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.runId,
      referencedTable: $db.playbookRuns,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlaybookRunsTableOrderingComposer(
            $db: $db,
            $table: $db.playbookRuns,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PlaybookRunStepsTableAnnotationComposer
    extends Composer<_$PlaybookDatabase, $PlaybookRunStepsTable> {
  $$PlaybookRunStepsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get stepIndex =>
      $composableBuilder(column: $table.stepIndex, builder: (column) => column);

  GeneratedColumn<String> get contentJson => $composableBuilder(
    column: $table.contentJson,
    builder: (column) => column,
  );

  $$PlaybookRunsTableAnnotationComposer get runId {
    final $$PlaybookRunsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.runId,
      referencedTable: $db.playbookRuns,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlaybookRunsTableAnnotationComposer(
            $db: $db,
            $table: $db.playbookRuns,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PlaybookRunStepsTableTableManager
    extends
        RootTableManager<
          _$PlaybookDatabase,
          $PlaybookRunStepsTable,
          PlaybookRunStep,
          $$PlaybookRunStepsTableFilterComposer,
          $$PlaybookRunStepsTableOrderingComposer,
          $$PlaybookRunStepsTableAnnotationComposer,
          $$PlaybookRunStepsTableCreateCompanionBuilder,
          $$PlaybookRunStepsTableUpdateCompanionBuilder,
          (PlaybookRunStep, $$PlaybookRunStepsTableReferences),
          PlaybookRunStep,
          PrefetchHooks Function({bool runId})
        > {
  $$PlaybookRunStepsTableTableManager(
    _$PlaybookDatabase db,
    $PlaybookRunStepsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlaybookRunStepsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlaybookRunStepsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlaybookRunStepsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> runId = const Value.absent(),
                Value<int> stepIndex = const Value.absent(),
                Value<String> contentJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PlaybookRunStepsCompanion(
                id: id,
                runId: runId,
                stepIndex: stepIndex,
                contentJson: contentJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String runId,
                required int stepIndex,
                required String contentJson,
                Value<int> rowid = const Value.absent(),
              }) => PlaybookRunStepsCompanion.insert(
                id: id,
                runId: runId,
                stepIndex: stepIndex,
                contentJson: contentJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$PlaybookRunStepsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({runId = false}) {
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
                    if (runId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.runId,
                                referencedTable:
                                    $$PlaybookRunStepsTableReferences
                                        ._runIdTable(db),
                                referencedColumn:
                                    $$PlaybookRunStepsTableReferences
                                        ._runIdTable(db)
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

typedef $$PlaybookRunStepsTableProcessedTableManager =
    ProcessedTableManager<
      _$PlaybookDatabase,
      $PlaybookRunStepsTable,
      PlaybookRunStep,
      $$PlaybookRunStepsTableFilterComposer,
      $$PlaybookRunStepsTableOrderingComposer,
      $$PlaybookRunStepsTableAnnotationComposer,
      $$PlaybookRunStepsTableCreateCompanionBuilder,
      $$PlaybookRunStepsTableUpdateCompanionBuilder,
      (PlaybookRunStep, $$PlaybookRunStepsTableReferences),
      PlaybookRunStep,
      PrefetchHooks Function({bool runId})
    >;

class $PlaybookDatabaseManager {
  final _$PlaybookDatabase _db;
  $PlaybookDatabaseManager(this._db);
  $$PlaybooksTableTableManager get playbooks =>
      $$PlaybooksTableTableManager(_db, _db.playbooks);
  $$PlaybookRunsTableTableManager get playbookRuns =>
      $$PlaybookRunsTableTableManager(_db, _db.playbookRuns);
  $$PlaybookRunStepsTableTableManager get playbookRunSteps =>
      $$PlaybookRunStepsTableTableManager(_db, _db.playbookRunSteps);
}

mixin _$PlaybookDaoMixin on DatabaseAccessor<PlaybookDatabase> {
  $PlaybooksTable get playbooks => attachedDatabase.playbooks;
  $PlaybookRunsTable get playbookRuns => attachedDatabase.playbookRuns;
  $PlaybookRunStepsTable get playbookRunSteps =>
      attachedDatabase.playbookRunSteps;
  PlaybookDaoManager get managers => PlaybookDaoManager(this);
}

class PlaybookDaoManager {
  final _$PlaybookDaoMixin _db;
  PlaybookDaoManager(this._db);
  $$PlaybooksTableTableManager get playbooks =>
      $$PlaybooksTableTableManager(_db.attachedDatabase, _db.playbooks);
  $$PlaybookRunsTableTableManager get playbookRuns =>
      $$PlaybookRunsTableTableManager(_db.attachedDatabase, _db.playbookRuns);
  $$PlaybookRunStepsTableTableManager get playbookRunSteps =>
      $$PlaybookRunStepsTableTableManager(
        _db.attachedDatabase,
        _db.playbookRunSteps,
      );
}
