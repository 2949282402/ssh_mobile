// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $TerminalHistoryRecordsTable extends TerminalHistoryRecords
    with TableInfo<$TerminalHistoryRecordsTable, TerminalHistoryRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TerminalHistoryRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sessionIdMeta = const VerificationMeta(
    'sessionId',
  );
  @override
  late final GeneratedColumn<String> sessionId = GeneratedColumn<String>(
    'session_id',
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
  static const VerificationMeta _connectionNameMeta = const VerificationMeta(
    'connectionName',
  );
  @override
  late final GeneratedColumn<String> connectionName = GeneratedColumn<String>(
    'connection_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _tmuxSessionNameMeta = const VerificationMeta(
    'tmuxSessionName',
  );
  @override
  late final GeneratedColumn<String> tmuxSessionName = GeneratedColumn<String>(
    'tmux_session_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
    'state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
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
    sessionId,
    connectionId,
    connectionName,
    displayName,
    tmuxSessionName,
    state,
    errorMessage,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'terminal_history_records';
  @override
  VerificationContext validateIntegrity(
    Insertable<TerminalHistoryRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('session_id')) {
      context.handle(
        _sessionIdMeta,
        sessionId.isAcceptableOrUnknown(data['session_id']!, _sessionIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sessionIdMeta);
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
    if (data.containsKey('connection_name')) {
      context.handle(
        _connectionNameMeta,
        connectionName.isAcceptableOrUnknown(
          data['connection_name']!,
          _connectionNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_connectionNameMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_displayNameMeta);
    }
    if (data.containsKey('tmux_session_name')) {
      context.handle(
        _tmuxSessionNameMeta,
        tmuxSessionName.isAcceptableOrUnknown(
          data['tmux_session_name']!,
          _tmuxSessionNameMeta,
        ),
      );
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    } else if (isInserting) {
      context.missing(_stateMeta);
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
  Set<GeneratedColumn> get $primaryKey => {sessionId};
  @override
  TerminalHistoryRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TerminalHistoryRecord(
      sessionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}session_id'],
      )!,
      connectionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}connection_id'],
      )!,
      connectionName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}connection_name'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      )!,
      tmuxSessionName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tmux_session_name'],
      ),
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state'],
      )!,
      errorMessage: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}error_message'],
      ),
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
  $TerminalHistoryRecordsTable createAlias(String alias) {
    return $TerminalHistoryRecordsTable(attachedDatabase, alias);
  }
}

class TerminalHistoryRecord extends DataClass
    implements Insertable<TerminalHistoryRecord> {
  final String sessionId;
  final String connectionId;
  final String connectionName;
  final String displayName;
  final String? tmuxSessionName;
  final String state;
  final String? errorMessage;
  final int createdAt;
  final int updatedAt;
  const TerminalHistoryRecord({
    required this.sessionId,
    required this.connectionId,
    required this.connectionName,
    required this.displayName,
    this.tmuxSessionName,
    required this.state,
    this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['session_id'] = Variable<String>(sessionId);
    map['connection_id'] = Variable<String>(connectionId);
    map['connection_name'] = Variable<String>(connectionName);
    map['display_name'] = Variable<String>(displayName);
    if (!nullToAbsent || tmuxSessionName != null) {
      map['tmux_session_name'] = Variable<String>(tmuxSessionName);
    }
    map['state'] = Variable<String>(state);
    if (!nullToAbsent || errorMessage != null) {
      map['error_message'] = Variable<String>(errorMessage);
    }
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  TerminalHistoryRecordsCompanion toCompanion(bool nullToAbsent) {
    return TerminalHistoryRecordsCompanion(
      sessionId: Value(sessionId),
      connectionId: Value(connectionId),
      connectionName: Value(connectionName),
      displayName: Value(displayName),
      tmuxSessionName: tmuxSessionName == null && nullToAbsent
          ? const Value.absent()
          : Value(tmuxSessionName),
      state: Value(state),
      errorMessage: errorMessage == null && nullToAbsent
          ? const Value.absent()
          : Value(errorMessage),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory TerminalHistoryRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TerminalHistoryRecord(
      sessionId: serializer.fromJson<String>(json['sessionId']),
      connectionId: serializer.fromJson<String>(json['connectionId']),
      connectionName: serializer.fromJson<String>(json['connectionName']),
      displayName: serializer.fromJson<String>(json['displayName']),
      tmuxSessionName: serializer.fromJson<String?>(json['tmuxSessionName']),
      state: serializer.fromJson<String>(json['state']),
      errorMessage: serializer.fromJson<String?>(json['errorMessage']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'sessionId': serializer.toJson<String>(sessionId),
      'connectionId': serializer.toJson<String>(connectionId),
      'connectionName': serializer.toJson<String>(connectionName),
      'displayName': serializer.toJson<String>(displayName),
      'tmuxSessionName': serializer.toJson<String?>(tmuxSessionName),
      'state': serializer.toJson<String>(state),
      'errorMessage': serializer.toJson<String?>(errorMessage),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  TerminalHistoryRecord copyWith({
    String? sessionId,
    String? connectionId,
    String? connectionName,
    String? displayName,
    Value<String?> tmuxSessionName = const Value.absent(),
    String? state,
    Value<String?> errorMessage = const Value.absent(),
    int? createdAt,
    int? updatedAt,
  }) => TerminalHistoryRecord(
    sessionId: sessionId ?? this.sessionId,
    connectionId: connectionId ?? this.connectionId,
    connectionName: connectionName ?? this.connectionName,
    displayName: displayName ?? this.displayName,
    tmuxSessionName: tmuxSessionName.present
        ? tmuxSessionName.value
        : this.tmuxSessionName,
    state: state ?? this.state,
    errorMessage: errorMessage.present ? errorMessage.value : this.errorMessage,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  TerminalHistoryRecord copyWithCompanion(
    TerminalHistoryRecordsCompanion data,
  ) {
    return TerminalHistoryRecord(
      sessionId: data.sessionId.present ? data.sessionId.value : this.sessionId,
      connectionId: data.connectionId.present
          ? data.connectionId.value
          : this.connectionId,
      connectionName: data.connectionName.present
          ? data.connectionName.value
          : this.connectionName,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      tmuxSessionName: data.tmuxSessionName.present
          ? data.tmuxSessionName.value
          : this.tmuxSessionName,
      state: data.state.present ? data.state.value : this.state,
      errorMessage: data.errorMessage.present
          ? data.errorMessage.value
          : this.errorMessage,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TerminalHistoryRecord(')
          ..write('sessionId: $sessionId, ')
          ..write('connectionId: $connectionId, ')
          ..write('connectionName: $connectionName, ')
          ..write('displayName: $displayName, ')
          ..write('tmuxSessionName: $tmuxSessionName, ')
          ..write('state: $state, ')
          ..write('errorMessage: $errorMessage, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    sessionId,
    connectionId,
    connectionName,
    displayName,
    tmuxSessionName,
    state,
    errorMessage,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TerminalHistoryRecord &&
          other.sessionId == this.sessionId &&
          other.connectionId == this.connectionId &&
          other.connectionName == this.connectionName &&
          other.displayName == this.displayName &&
          other.tmuxSessionName == this.tmuxSessionName &&
          other.state == this.state &&
          other.errorMessage == this.errorMessage &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class TerminalHistoryRecordsCompanion
    extends UpdateCompanion<TerminalHistoryRecord> {
  final Value<String> sessionId;
  final Value<String> connectionId;
  final Value<String> connectionName;
  final Value<String> displayName;
  final Value<String?> tmuxSessionName;
  final Value<String> state;
  final Value<String?> errorMessage;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const TerminalHistoryRecordsCompanion({
    this.sessionId = const Value.absent(),
    this.connectionId = const Value.absent(),
    this.connectionName = const Value.absent(),
    this.displayName = const Value.absent(),
    this.tmuxSessionName = const Value.absent(),
    this.state = const Value.absent(),
    this.errorMessage = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TerminalHistoryRecordsCompanion.insert({
    required String sessionId,
    required String connectionId,
    required String connectionName,
    required String displayName,
    this.tmuxSessionName = const Value.absent(),
    required String state,
    this.errorMessage = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : sessionId = Value(sessionId),
       connectionId = Value(connectionId),
       connectionName = Value(connectionName),
       displayName = Value(displayName),
       state = Value(state),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<TerminalHistoryRecord> custom({
    Expression<String>? sessionId,
    Expression<String>? connectionId,
    Expression<String>? connectionName,
    Expression<String>? displayName,
    Expression<String>? tmuxSessionName,
    Expression<String>? state,
    Expression<String>? errorMessage,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (sessionId != null) 'session_id': sessionId,
      if (connectionId != null) 'connection_id': connectionId,
      if (connectionName != null) 'connection_name': connectionName,
      if (displayName != null) 'display_name': displayName,
      if (tmuxSessionName != null) 'tmux_session_name': tmuxSessionName,
      if (state != null) 'state': state,
      if (errorMessage != null) 'error_message': errorMessage,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TerminalHistoryRecordsCompanion copyWith({
    Value<String>? sessionId,
    Value<String>? connectionId,
    Value<String>? connectionName,
    Value<String>? displayName,
    Value<String?>? tmuxSessionName,
    Value<String>? state,
    Value<String?>? errorMessage,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return TerminalHistoryRecordsCompanion(
      sessionId: sessionId ?? this.sessionId,
      connectionId: connectionId ?? this.connectionId,
      connectionName: connectionName ?? this.connectionName,
      displayName: displayName ?? this.displayName,
      tmuxSessionName: tmuxSessionName ?? this.tmuxSessionName,
      state: state ?? this.state,
      errorMessage: errorMessage ?? this.errorMessage,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (sessionId.present) {
      map['session_id'] = Variable<String>(sessionId.value);
    }
    if (connectionId.present) {
      map['connection_id'] = Variable<String>(connectionId.value);
    }
    if (connectionName.present) {
      map['connection_name'] = Variable<String>(connectionName.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (tmuxSessionName.present) {
      map['tmux_session_name'] = Variable<String>(tmuxSessionName.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (errorMessage.present) {
      map['error_message'] = Variable<String>(errorMessage.value);
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
    return (StringBuffer('TerminalHistoryRecordsCompanion(')
          ..write('sessionId: $sessionId, ')
          ..write('connectionId: $connectionId, ')
          ..write('connectionName: $connectionName, ')
          ..write('displayName: $displayName, ')
          ..write('tmuxSessionName: $tmuxSessionName, ')
          ..write('state: $state, ')
          ..write('errorMessage: $errorMessage, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

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
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _commandMeta = const VerificationMeta(
    'command',
  );
  @override
  late final GeneratedColumn<String> command = GeneratedColumn<String>(
    'command',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
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
  static const VerificationMeta _stdoutPreviewMeta = const VerificationMeta(
    'stdoutPreview',
  );
  @override
  late final GeneratedColumn<String> stdoutPreview = GeneratedColumn<String>(
    'stdout_preview',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _stderrPreviewMeta = const VerificationMeta(
    'stderrPreview',
  );
  @override
  late final GeneratedColumn<String> stderrPreview = GeneratedColumn<String>(
    'stderr_preview',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _exitCodeMeta = const VerificationMeta(
    'exitCode',
  );
  @override
  late final GeneratedColumn<int> exitCode = GeneratedColumn<int>(
    'exit_code',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    runId,
    stepIndex,
    name,
    command,
    status,
    stdoutPreview,
    stderrPreview,
    exitCode,
  ];
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
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('command')) {
      context.handle(
        _commandMeta,
        command.isAcceptableOrUnknown(data['command']!, _commandMeta),
      );
    } else if (isInserting) {
      context.missing(_commandMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('stdout_preview')) {
      context.handle(
        _stdoutPreviewMeta,
        stdoutPreview.isAcceptableOrUnknown(
          data['stdout_preview']!,
          _stdoutPreviewMeta,
        ),
      );
    }
    if (data.containsKey('stderr_preview')) {
      context.handle(
        _stderrPreviewMeta,
        stderrPreview.isAcceptableOrUnknown(
          data['stderr_preview']!,
          _stderrPreviewMeta,
        ),
      );
    }
    if (data.containsKey('exit_code')) {
      context.handle(
        _exitCodeMeta,
        exitCode.isAcceptableOrUnknown(data['exit_code']!, _exitCodeMeta),
      );
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
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      command: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}command'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      stdoutPreview: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}stdout_preview'],
      ),
      stderrPreview: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}stderr_preview'],
      ),
      exitCode: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}exit_code'],
      ),
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
  final String name;
  final String command;
  final String status;
  final String? stdoutPreview;
  final String? stderrPreview;
  final int? exitCode;
  const PlaybookRunStep({
    required this.id,
    required this.runId,
    required this.stepIndex,
    required this.name,
    required this.command,
    required this.status,
    this.stdoutPreview,
    this.stderrPreview,
    this.exitCode,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['run_id'] = Variable<String>(runId);
    map['step_index'] = Variable<int>(stepIndex);
    map['name'] = Variable<String>(name);
    map['command'] = Variable<String>(command);
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || stdoutPreview != null) {
      map['stdout_preview'] = Variable<String>(stdoutPreview);
    }
    if (!nullToAbsent || stderrPreview != null) {
      map['stderr_preview'] = Variable<String>(stderrPreview);
    }
    if (!nullToAbsent || exitCode != null) {
      map['exit_code'] = Variable<int>(exitCode);
    }
    return map;
  }

  PlaybookRunStepsCompanion toCompanion(bool nullToAbsent) {
    return PlaybookRunStepsCompanion(
      id: Value(id),
      runId: Value(runId),
      stepIndex: Value(stepIndex),
      name: Value(name),
      command: Value(command),
      status: Value(status),
      stdoutPreview: stdoutPreview == null && nullToAbsent
          ? const Value.absent()
          : Value(stdoutPreview),
      stderrPreview: stderrPreview == null && nullToAbsent
          ? const Value.absent()
          : Value(stderrPreview),
      exitCode: exitCode == null && nullToAbsent
          ? const Value.absent()
          : Value(exitCode),
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
      name: serializer.fromJson<String>(json['name']),
      command: serializer.fromJson<String>(json['command']),
      status: serializer.fromJson<String>(json['status']),
      stdoutPreview: serializer.fromJson<String?>(json['stdoutPreview']),
      stderrPreview: serializer.fromJson<String?>(json['stderrPreview']),
      exitCode: serializer.fromJson<int?>(json['exitCode']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'runId': serializer.toJson<String>(runId),
      'stepIndex': serializer.toJson<int>(stepIndex),
      'name': serializer.toJson<String>(name),
      'command': serializer.toJson<String>(command),
      'status': serializer.toJson<String>(status),
      'stdoutPreview': serializer.toJson<String?>(stdoutPreview),
      'stderrPreview': serializer.toJson<String?>(stderrPreview),
      'exitCode': serializer.toJson<int?>(exitCode),
    };
  }

  PlaybookRunStep copyWith({
    String? id,
    String? runId,
    int? stepIndex,
    String? name,
    String? command,
    String? status,
    Value<String?> stdoutPreview = const Value.absent(),
    Value<String?> stderrPreview = const Value.absent(),
    Value<int?> exitCode = const Value.absent(),
  }) => PlaybookRunStep(
    id: id ?? this.id,
    runId: runId ?? this.runId,
    stepIndex: stepIndex ?? this.stepIndex,
    name: name ?? this.name,
    command: command ?? this.command,
    status: status ?? this.status,
    stdoutPreview: stdoutPreview.present
        ? stdoutPreview.value
        : this.stdoutPreview,
    stderrPreview: stderrPreview.present
        ? stderrPreview.value
        : this.stderrPreview,
    exitCode: exitCode.present ? exitCode.value : this.exitCode,
  );
  PlaybookRunStep copyWithCompanion(PlaybookRunStepsCompanion data) {
    return PlaybookRunStep(
      id: data.id.present ? data.id.value : this.id,
      runId: data.runId.present ? data.runId.value : this.runId,
      stepIndex: data.stepIndex.present ? data.stepIndex.value : this.stepIndex,
      name: data.name.present ? data.name.value : this.name,
      command: data.command.present ? data.command.value : this.command,
      status: data.status.present ? data.status.value : this.status,
      stdoutPreview: data.stdoutPreview.present
          ? data.stdoutPreview.value
          : this.stdoutPreview,
      stderrPreview: data.stderrPreview.present
          ? data.stderrPreview.value
          : this.stderrPreview,
      exitCode: data.exitCode.present ? data.exitCode.value : this.exitCode,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlaybookRunStep(')
          ..write('id: $id, ')
          ..write('runId: $runId, ')
          ..write('stepIndex: $stepIndex, ')
          ..write('name: $name, ')
          ..write('command: $command, ')
          ..write('status: $status, ')
          ..write('stdoutPreview: $stdoutPreview, ')
          ..write('stderrPreview: $stderrPreview, ')
          ..write('exitCode: $exitCode')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    runId,
    stepIndex,
    name,
    command,
    status,
    stdoutPreview,
    stderrPreview,
    exitCode,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlaybookRunStep &&
          other.id == this.id &&
          other.runId == this.runId &&
          other.stepIndex == this.stepIndex &&
          other.name == this.name &&
          other.command == this.command &&
          other.status == this.status &&
          other.stdoutPreview == this.stdoutPreview &&
          other.stderrPreview == this.stderrPreview &&
          other.exitCode == this.exitCode);
}

class PlaybookRunStepsCompanion extends UpdateCompanion<PlaybookRunStep> {
  final Value<String> id;
  final Value<String> runId;
  final Value<int> stepIndex;
  final Value<String> name;
  final Value<String> command;
  final Value<String> status;
  final Value<String?> stdoutPreview;
  final Value<String?> stderrPreview;
  final Value<int?> exitCode;
  final Value<int> rowid;
  const PlaybookRunStepsCompanion({
    this.id = const Value.absent(),
    this.runId = const Value.absent(),
    this.stepIndex = const Value.absent(),
    this.name = const Value.absent(),
    this.command = const Value.absent(),
    this.status = const Value.absent(),
    this.stdoutPreview = const Value.absent(),
    this.stderrPreview = const Value.absent(),
    this.exitCode = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PlaybookRunStepsCompanion.insert({
    required String id,
    required String runId,
    required int stepIndex,
    required String name,
    required String command,
    required String status,
    this.stdoutPreview = const Value.absent(),
    this.stderrPreview = const Value.absent(),
    this.exitCode = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       runId = Value(runId),
       stepIndex = Value(stepIndex),
       name = Value(name),
       command = Value(command),
       status = Value(status);
  static Insertable<PlaybookRunStep> custom({
    Expression<String>? id,
    Expression<String>? runId,
    Expression<int>? stepIndex,
    Expression<String>? name,
    Expression<String>? command,
    Expression<String>? status,
    Expression<String>? stdoutPreview,
    Expression<String>? stderrPreview,
    Expression<int>? exitCode,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (runId != null) 'run_id': runId,
      if (stepIndex != null) 'step_index': stepIndex,
      if (name != null) 'name': name,
      if (command != null) 'command': command,
      if (status != null) 'status': status,
      if (stdoutPreview != null) 'stdout_preview': stdoutPreview,
      if (stderrPreview != null) 'stderr_preview': stderrPreview,
      if (exitCode != null) 'exit_code': exitCode,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PlaybookRunStepsCompanion copyWith({
    Value<String>? id,
    Value<String>? runId,
    Value<int>? stepIndex,
    Value<String>? name,
    Value<String>? command,
    Value<String>? status,
    Value<String?>? stdoutPreview,
    Value<String?>? stderrPreview,
    Value<int?>? exitCode,
    Value<int>? rowid,
  }) {
    return PlaybookRunStepsCompanion(
      id: id ?? this.id,
      runId: runId ?? this.runId,
      stepIndex: stepIndex ?? this.stepIndex,
      name: name ?? this.name,
      command: command ?? this.command,
      status: status ?? this.status,
      stdoutPreview: stdoutPreview ?? this.stdoutPreview,
      stderrPreview: stderrPreview ?? this.stderrPreview,
      exitCode: exitCode ?? this.exitCode,
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
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (command.present) {
      map['command'] = Variable<String>(command.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (stdoutPreview.present) {
      map['stdout_preview'] = Variable<String>(stdoutPreview.value);
    }
    if (stderrPreview.present) {
      map['stderr_preview'] = Variable<String>(stderrPreview.value);
    }
    if (exitCode.present) {
      map['exit_code'] = Variable<int>(exitCode.value);
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
          ..write('name: $name, ')
          ..write('command: $command, ')
          ..write('status: $status, ')
          ..write('stdoutPreview: $stdoutPreview, ')
          ..write('stderrPreview: $stderrPreview, ')
          ..write('exitCode: $exitCode, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

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

class $LanTransferRecordsTable extends LanTransferRecords
    with TableInfo<$LanTransferRecordsTable, LanTransferRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LanTransferRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _senderIdMeta = const VerificationMeta(
    'senderId',
  );
  @override
  late final GeneratedColumn<String> senderId = GeneratedColumn<String>(
    'sender_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _senderAliasMeta = const VerificationMeta(
    'senderAlias',
  );
  @override
  late final GeneratedColumn<String> senderAlias = GeneratedColumn<String>(
    'sender_alias',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _receiverIdMeta = const VerificationMeta(
    'receiverId',
  );
  @override
  late final GeneratedColumn<String> receiverId = GeneratedColumn<String>(
    'receiver_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadTypeMeta = const VerificationMeta(
    'payloadType',
  );
  @override
  late final GeneratedColumn<String> payloadType = GeneratedColumn<String>(
    'payload_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _textContentMeta = const VerificationMeta(
    'textContent',
  );
  @override
  late final GeneratedColumn<String> textContent = GeneratedColumn<String>(
    'text_content',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _fileNameMeta = const VerificationMeta(
    'fileName',
  );
  @override
  late final GeneratedColumn<String> fileName = GeneratedColumn<String>(
    'file_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _fileSizeMeta = const VerificationMeta(
    'fileSize',
  );
  @override
  late final GeneratedColumn<int> fileSize = GeneratedColumn<int>(
    'file_size',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _localPathMeta = const VerificationMeta(
    'localPath',
  );
  @override
  late final GeneratedColumn<String> localPath = GeneratedColumn<String>(
    'local_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _manifestJsonMeta = const VerificationMeta(
    'manifestJson',
  );
  @override
  late final GeneratedColumn<String> manifestJson = GeneratedColumn<String>(
    'manifest_json',
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
  static const VerificationMeta _bytesTransferredMeta = const VerificationMeta(
    'bytesTransferred',
  );
  @override
  late final GeneratedColumn<int> bytesTransferred = GeneratedColumn<int>(
    'bytes_transferred',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
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
  static const VerificationMeta _isIncomingMeta = const VerificationMeta(
    'isIncoming',
  );
  @override
  late final GeneratedColumn<bool> isIncoming = GeneratedColumn<bool>(
    'is_incoming',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_incoming" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _isRecalledMeta = const VerificationMeta(
    'isRecalled',
  );
  @override
  late final GeneratedColumn<bool> isRecalled = GeneratedColumn<bool>(
    'is_recalled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_recalled" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _sftpServerIdMeta = const VerificationMeta(
    'sftpServerId',
  );
  @override
  late final GeneratedColumn<String> sftpServerId = GeneratedColumn<String>(
    'sftp_server_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sftpRemotePathMeta = const VerificationMeta(
    'sftpRemotePath',
  );
  @override
  late final GeneratedColumn<String> sftpRemotePath = GeneratedColumn<String>(
    'sftp_remote_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _transportMeta = const VerificationMeta(
    'transport',
  );
  @override
  late final GeneratedColumn<String> transport = GeneratedColumn<String>(
    'transport',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _routeTypeMeta = const VerificationMeta(
    'routeType',
  );
  @override
  late final GeneratedColumn<String> routeType = GeneratedColumn<String>(
    'route_type',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _avgRttMeta = const VerificationMeta('avgRtt');
  @override
  late final GeneratedColumn<int> avgRtt = GeneratedColumn<int>(
    'avg_rtt',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _bytesTotalMeta = const VerificationMeta(
    'bytesTotal',
  );
  @override
  late final GeneratedColumn<int> bytesTotal = GeneratedColumn<int>(
    'bytes_total',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _failureReasonMeta = const VerificationMeta(
    'failureReason',
  );
  @override
  late final GeneratedColumn<String> failureReason = GeneratedColumn<String>(
    'failure_reason',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    senderId,
    senderAlias,
    receiverId,
    payloadType,
    textContent,
    fileName,
    fileSize,
    localPath,
    manifestJson,
    status,
    bytesTransferred,
    createdAt,
    isIncoming,
    isRecalled,
    sftpServerId,
    sftpRemotePath,
    transport,
    routeType,
    avgRtt,
    bytesTotal,
    failureReason,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'lan_transfer_records';
  @override
  VerificationContext validateIntegrity(
    Insertable<LanTransferRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('sender_id')) {
      context.handle(
        _senderIdMeta,
        senderId.isAcceptableOrUnknown(data['sender_id']!, _senderIdMeta),
      );
    } else if (isInserting) {
      context.missing(_senderIdMeta);
    }
    if (data.containsKey('sender_alias')) {
      context.handle(
        _senderAliasMeta,
        senderAlias.isAcceptableOrUnknown(
          data['sender_alias']!,
          _senderAliasMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_senderAliasMeta);
    }
    if (data.containsKey('receiver_id')) {
      context.handle(
        _receiverIdMeta,
        receiverId.isAcceptableOrUnknown(data['receiver_id']!, _receiverIdMeta),
      );
    } else if (isInserting) {
      context.missing(_receiverIdMeta);
    }
    if (data.containsKey('payload_type')) {
      context.handle(
        _payloadTypeMeta,
        payloadType.isAcceptableOrUnknown(
          data['payload_type']!,
          _payloadTypeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_payloadTypeMeta);
    }
    if (data.containsKey('text_content')) {
      context.handle(
        _textContentMeta,
        textContent.isAcceptableOrUnknown(
          data['text_content']!,
          _textContentMeta,
        ),
      );
    }
    if (data.containsKey('file_name')) {
      context.handle(
        _fileNameMeta,
        fileName.isAcceptableOrUnknown(data['file_name']!, _fileNameMeta),
      );
    }
    if (data.containsKey('file_size')) {
      context.handle(
        _fileSizeMeta,
        fileSize.isAcceptableOrUnknown(data['file_size']!, _fileSizeMeta),
      );
    }
    if (data.containsKey('local_path')) {
      context.handle(
        _localPathMeta,
        localPath.isAcceptableOrUnknown(data['local_path']!, _localPathMeta),
      );
    }
    if (data.containsKey('manifest_json')) {
      context.handle(
        _manifestJsonMeta,
        manifestJson.isAcceptableOrUnknown(
          data['manifest_json']!,
          _manifestJsonMeta,
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
    if (data.containsKey('bytes_transferred')) {
      context.handle(
        _bytesTransferredMeta,
        bytesTransferred.isAcceptableOrUnknown(
          data['bytes_transferred']!,
          _bytesTransferredMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('is_incoming')) {
      context.handle(
        _isIncomingMeta,
        isIncoming.isAcceptableOrUnknown(data['is_incoming']!, _isIncomingMeta),
      );
    }
    if (data.containsKey('is_recalled')) {
      context.handle(
        _isRecalledMeta,
        isRecalled.isAcceptableOrUnknown(data['is_recalled']!, _isRecalledMeta),
      );
    }
    if (data.containsKey('sftp_server_id')) {
      context.handle(
        _sftpServerIdMeta,
        sftpServerId.isAcceptableOrUnknown(
          data['sftp_server_id']!,
          _sftpServerIdMeta,
        ),
      );
    }
    if (data.containsKey('sftp_remote_path')) {
      context.handle(
        _sftpRemotePathMeta,
        sftpRemotePath.isAcceptableOrUnknown(
          data['sftp_remote_path']!,
          _sftpRemotePathMeta,
        ),
      );
    }
    if (data.containsKey('transport')) {
      context.handle(
        _transportMeta,
        transport.isAcceptableOrUnknown(data['transport']!, _transportMeta),
      );
    }
    if (data.containsKey('route_type')) {
      context.handle(
        _routeTypeMeta,
        routeType.isAcceptableOrUnknown(data['route_type']!, _routeTypeMeta),
      );
    }
    if (data.containsKey('avg_rtt')) {
      context.handle(
        _avgRttMeta,
        avgRtt.isAcceptableOrUnknown(data['avg_rtt']!, _avgRttMeta),
      );
    }
    if (data.containsKey('bytes_total')) {
      context.handle(
        _bytesTotalMeta,
        bytesTotal.isAcceptableOrUnknown(data['bytes_total']!, _bytesTotalMeta),
      );
    }
    if (data.containsKey('failure_reason')) {
      context.handle(
        _failureReasonMeta,
        failureReason.isAcceptableOrUnknown(
          data['failure_reason']!,
          _failureReasonMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LanTransferRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LanTransferRecord(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      senderId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sender_id'],
      )!,
      senderAlias: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sender_alias'],
      )!,
      receiverId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}receiver_id'],
      )!,
      payloadType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_type'],
      )!,
      textContent: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}text_content'],
      ),
      fileName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}file_name'],
      ),
      fileSize: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}file_size'],
      )!,
      localPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_path'],
      ),
      manifestJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}manifest_json'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      bytesTransferred: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}bytes_transferred'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      isIncoming: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_incoming'],
      )!,
      isRecalled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_recalled'],
      )!,
      sftpServerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sftp_server_id'],
      ),
      sftpRemotePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sftp_remote_path'],
      ),
      transport: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}transport'],
      ),
      routeType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}route_type'],
      ),
      avgRtt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}avg_rtt'],
      ),
      bytesTotal: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}bytes_total'],
      ),
      failureReason: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}failure_reason'],
      ),
    );
  }

  @override
  $LanTransferRecordsTable createAlias(String alias) {
    return $LanTransferRecordsTable(attachedDatabase, alias);
  }
}

class LanTransferRecord extends DataClass
    implements Insertable<LanTransferRecord> {
  final String id;
  final String senderId;
  final String senderAlias;
  final String receiverId;
  final String payloadType;
  final String? textContent;
  final String? fileName;
  final int fileSize;
  final String? localPath;
  final String? manifestJson;
  final String status;
  final int bytesTransferred;
  final int createdAt;
  final bool isIncoming;
  final bool isRecalled;
  final String? sftpServerId;
  final String? sftpRemotePath;
  final String? transport;
  final String? routeType;
  final int? avgRtt;
  final int? bytesTotal;
  final String? failureReason;
  const LanTransferRecord({
    required this.id,
    required this.senderId,
    required this.senderAlias,
    required this.receiverId,
    required this.payloadType,
    this.textContent,
    this.fileName,
    required this.fileSize,
    this.localPath,
    this.manifestJson,
    required this.status,
    required this.bytesTransferred,
    required this.createdAt,
    required this.isIncoming,
    required this.isRecalled,
    this.sftpServerId,
    this.sftpRemotePath,
    this.transport,
    this.routeType,
    this.avgRtt,
    this.bytesTotal,
    this.failureReason,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['sender_id'] = Variable<String>(senderId);
    map['sender_alias'] = Variable<String>(senderAlias);
    map['receiver_id'] = Variable<String>(receiverId);
    map['payload_type'] = Variable<String>(payloadType);
    if (!nullToAbsent || textContent != null) {
      map['text_content'] = Variable<String>(textContent);
    }
    if (!nullToAbsent || fileName != null) {
      map['file_name'] = Variable<String>(fileName);
    }
    map['file_size'] = Variable<int>(fileSize);
    if (!nullToAbsent || localPath != null) {
      map['local_path'] = Variable<String>(localPath);
    }
    if (!nullToAbsent || manifestJson != null) {
      map['manifest_json'] = Variable<String>(manifestJson);
    }
    map['status'] = Variable<String>(status);
    map['bytes_transferred'] = Variable<int>(bytesTransferred);
    map['created_at'] = Variable<int>(createdAt);
    map['is_incoming'] = Variable<bool>(isIncoming);
    map['is_recalled'] = Variable<bool>(isRecalled);
    if (!nullToAbsent || sftpServerId != null) {
      map['sftp_server_id'] = Variable<String>(sftpServerId);
    }
    if (!nullToAbsent || sftpRemotePath != null) {
      map['sftp_remote_path'] = Variable<String>(sftpRemotePath);
    }
    if (!nullToAbsent || transport != null) {
      map['transport'] = Variable<String>(transport);
    }
    if (!nullToAbsent || routeType != null) {
      map['route_type'] = Variable<String>(routeType);
    }
    if (!nullToAbsent || avgRtt != null) {
      map['avg_rtt'] = Variable<int>(avgRtt);
    }
    if (!nullToAbsent || bytesTotal != null) {
      map['bytes_total'] = Variable<int>(bytesTotal);
    }
    if (!nullToAbsent || failureReason != null) {
      map['failure_reason'] = Variable<String>(failureReason);
    }
    return map;
  }

  LanTransferRecordsCompanion toCompanion(bool nullToAbsent) {
    return LanTransferRecordsCompanion(
      id: Value(id),
      senderId: Value(senderId),
      senderAlias: Value(senderAlias),
      receiverId: Value(receiverId),
      payloadType: Value(payloadType),
      textContent: textContent == null && nullToAbsent
          ? const Value.absent()
          : Value(textContent),
      fileName: fileName == null && nullToAbsent
          ? const Value.absent()
          : Value(fileName),
      fileSize: Value(fileSize),
      localPath: localPath == null && nullToAbsent
          ? const Value.absent()
          : Value(localPath),
      manifestJson: manifestJson == null && nullToAbsent
          ? const Value.absent()
          : Value(manifestJson),
      status: Value(status),
      bytesTransferred: Value(bytesTransferred),
      createdAt: Value(createdAt),
      isIncoming: Value(isIncoming),
      isRecalled: Value(isRecalled),
      sftpServerId: sftpServerId == null && nullToAbsent
          ? const Value.absent()
          : Value(sftpServerId),
      sftpRemotePath: sftpRemotePath == null && nullToAbsent
          ? const Value.absent()
          : Value(sftpRemotePath),
      transport: transport == null && nullToAbsent
          ? const Value.absent()
          : Value(transport),
      routeType: routeType == null && nullToAbsent
          ? const Value.absent()
          : Value(routeType),
      avgRtt: avgRtt == null && nullToAbsent
          ? const Value.absent()
          : Value(avgRtt),
      bytesTotal: bytesTotal == null && nullToAbsent
          ? const Value.absent()
          : Value(bytesTotal),
      failureReason: failureReason == null && nullToAbsent
          ? const Value.absent()
          : Value(failureReason),
    );
  }

  factory LanTransferRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LanTransferRecord(
      id: serializer.fromJson<String>(json['id']),
      senderId: serializer.fromJson<String>(json['senderId']),
      senderAlias: serializer.fromJson<String>(json['senderAlias']),
      receiverId: serializer.fromJson<String>(json['receiverId']),
      payloadType: serializer.fromJson<String>(json['payloadType']),
      textContent: serializer.fromJson<String?>(json['textContent']),
      fileName: serializer.fromJson<String?>(json['fileName']),
      fileSize: serializer.fromJson<int>(json['fileSize']),
      localPath: serializer.fromJson<String?>(json['localPath']),
      manifestJson: serializer.fromJson<String?>(json['manifestJson']),
      status: serializer.fromJson<String>(json['status']),
      bytesTransferred: serializer.fromJson<int>(json['bytesTransferred']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      isIncoming: serializer.fromJson<bool>(json['isIncoming']),
      isRecalled: serializer.fromJson<bool>(json['isRecalled']),
      sftpServerId: serializer.fromJson<String?>(json['sftpServerId']),
      sftpRemotePath: serializer.fromJson<String?>(json['sftpRemotePath']),
      transport: serializer.fromJson<String?>(json['transport']),
      routeType: serializer.fromJson<String?>(json['routeType']),
      avgRtt: serializer.fromJson<int?>(json['avgRtt']),
      bytesTotal: serializer.fromJson<int?>(json['bytesTotal']),
      failureReason: serializer.fromJson<String?>(json['failureReason']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'senderId': serializer.toJson<String>(senderId),
      'senderAlias': serializer.toJson<String>(senderAlias),
      'receiverId': serializer.toJson<String>(receiverId),
      'payloadType': serializer.toJson<String>(payloadType),
      'textContent': serializer.toJson<String?>(textContent),
      'fileName': serializer.toJson<String?>(fileName),
      'fileSize': serializer.toJson<int>(fileSize),
      'localPath': serializer.toJson<String?>(localPath),
      'manifestJson': serializer.toJson<String?>(manifestJson),
      'status': serializer.toJson<String>(status),
      'bytesTransferred': serializer.toJson<int>(bytesTransferred),
      'createdAt': serializer.toJson<int>(createdAt),
      'isIncoming': serializer.toJson<bool>(isIncoming),
      'isRecalled': serializer.toJson<bool>(isRecalled),
      'sftpServerId': serializer.toJson<String?>(sftpServerId),
      'sftpRemotePath': serializer.toJson<String?>(sftpRemotePath),
      'transport': serializer.toJson<String?>(transport),
      'routeType': serializer.toJson<String?>(routeType),
      'avgRtt': serializer.toJson<int?>(avgRtt),
      'bytesTotal': serializer.toJson<int?>(bytesTotal),
      'failureReason': serializer.toJson<String?>(failureReason),
    };
  }

  LanTransferRecord copyWith({
    String? id,
    String? senderId,
    String? senderAlias,
    String? receiverId,
    String? payloadType,
    Value<String?> textContent = const Value.absent(),
    Value<String?> fileName = const Value.absent(),
    int? fileSize,
    Value<String?> localPath = const Value.absent(),
    Value<String?> manifestJson = const Value.absent(),
    String? status,
    int? bytesTransferred,
    int? createdAt,
    bool? isIncoming,
    bool? isRecalled,
    Value<String?> sftpServerId = const Value.absent(),
    Value<String?> sftpRemotePath = const Value.absent(),
    Value<String?> transport = const Value.absent(),
    Value<String?> routeType = const Value.absent(),
    Value<int?> avgRtt = const Value.absent(),
    Value<int?> bytesTotal = const Value.absent(),
    Value<String?> failureReason = const Value.absent(),
  }) => LanTransferRecord(
    id: id ?? this.id,
    senderId: senderId ?? this.senderId,
    senderAlias: senderAlias ?? this.senderAlias,
    receiverId: receiverId ?? this.receiverId,
    payloadType: payloadType ?? this.payloadType,
    textContent: textContent.present ? textContent.value : this.textContent,
    fileName: fileName.present ? fileName.value : this.fileName,
    fileSize: fileSize ?? this.fileSize,
    localPath: localPath.present ? localPath.value : this.localPath,
    manifestJson: manifestJson.present ? manifestJson.value : this.manifestJson,
    status: status ?? this.status,
    bytesTransferred: bytesTransferred ?? this.bytesTransferred,
    createdAt: createdAt ?? this.createdAt,
    isIncoming: isIncoming ?? this.isIncoming,
    isRecalled: isRecalled ?? this.isRecalled,
    sftpServerId: sftpServerId.present ? sftpServerId.value : this.sftpServerId,
    sftpRemotePath: sftpRemotePath.present
        ? sftpRemotePath.value
        : this.sftpRemotePath,
    transport: transport.present ? transport.value : this.transport,
    routeType: routeType.present ? routeType.value : this.routeType,
    avgRtt: avgRtt.present ? avgRtt.value : this.avgRtt,
    bytesTotal: bytesTotal.present ? bytesTotal.value : this.bytesTotal,
    failureReason: failureReason.present
        ? failureReason.value
        : this.failureReason,
  );
  LanTransferRecord copyWithCompanion(LanTransferRecordsCompanion data) {
    return LanTransferRecord(
      id: data.id.present ? data.id.value : this.id,
      senderId: data.senderId.present ? data.senderId.value : this.senderId,
      senderAlias: data.senderAlias.present
          ? data.senderAlias.value
          : this.senderAlias,
      receiverId: data.receiverId.present
          ? data.receiverId.value
          : this.receiverId,
      payloadType: data.payloadType.present
          ? data.payloadType.value
          : this.payloadType,
      textContent: data.textContent.present
          ? data.textContent.value
          : this.textContent,
      fileName: data.fileName.present ? data.fileName.value : this.fileName,
      fileSize: data.fileSize.present ? data.fileSize.value : this.fileSize,
      localPath: data.localPath.present ? data.localPath.value : this.localPath,
      manifestJson: data.manifestJson.present
          ? data.manifestJson.value
          : this.manifestJson,
      status: data.status.present ? data.status.value : this.status,
      bytesTransferred: data.bytesTransferred.present
          ? data.bytesTransferred.value
          : this.bytesTransferred,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      isIncoming: data.isIncoming.present
          ? data.isIncoming.value
          : this.isIncoming,
      isRecalled: data.isRecalled.present
          ? data.isRecalled.value
          : this.isRecalled,
      sftpServerId: data.sftpServerId.present
          ? data.sftpServerId.value
          : this.sftpServerId,
      sftpRemotePath: data.sftpRemotePath.present
          ? data.sftpRemotePath.value
          : this.sftpRemotePath,
      transport: data.transport.present ? data.transport.value : this.transport,
      routeType: data.routeType.present ? data.routeType.value : this.routeType,
      avgRtt: data.avgRtt.present ? data.avgRtt.value : this.avgRtt,
      bytesTotal: data.bytesTotal.present
          ? data.bytesTotal.value
          : this.bytesTotal,
      failureReason: data.failureReason.present
          ? data.failureReason.value
          : this.failureReason,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LanTransferRecord(')
          ..write('id: $id, ')
          ..write('senderId: $senderId, ')
          ..write('senderAlias: $senderAlias, ')
          ..write('receiverId: $receiverId, ')
          ..write('payloadType: $payloadType, ')
          ..write('textContent: $textContent, ')
          ..write('fileName: $fileName, ')
          ..write('fileSize: $fileSize, ')
          ..write('localPath: $localPath, ')
          ..write('manifestJson: $manifestJson, ')
          ..write('status: $status, ')
          ..write('bytesTransferred: $bytesTransferred, ')
          ..write('createdAt: $createdAt, ')
          ..write('isIncoming: $isIncoming, ')
          ..write('isRecalled: $isRecalled, ')
          ..write('sftpServerId: $sftpServerId, ')
          ..write('sftpRemotePath: $sftpRemotePath, ')
          ..write('transport: $transport, ')
          ..write('routeType: $routeType, ')
          ..write('avgRtt: $avgRtt, ')
          ..write('bytesTotal: $bytesTotal, ')
          ..write('failureReason: $failureReason')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    senderId,
    senderAlias,
    receiverId,
    payloadType,
    textContent,
    fileName,
    fileSize,
    localPath,
    manifestJson,
    status,
    bytesTransferred,
    createdAt,
    isIncoming,
    isRecalled,
    sftpServerId,
    sftpRemotePath,
    transport,
    routeType,
    avgRtt,
    bytesTotal,
    failureReason,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LanTransferRecord &&
          other.id == this.id &&
          other.senderId == this.senderId &&
          other.senderAlias == this.senderAlias &&
          other.receiverId == this.receiverId &&
          other.payloadType == this.payloadType &&
          other.textContent == this.textContent &&
          other.fileName == this.fileName &&
          other.fileSize == this.fileSize &&
          other.localPath == this.localPath &&
          other.manifestJson == this.manifestJson &&
          other.status == this.status &&
          other.bytesTransferred == this.bytesTransferred &&
          other.createdAt == this.createdAt &&
          other.isIncoming == this.isIncoming &&
          other.isRecalled == this.isRecalled &&
          other.sftpServerId == this.sftpServerId &&
          other.sftpRemotePath == this.sftpRemotePath &&
          other.transport == this.transport &&
          other.routeType == this.routeType &&
          other.avgRtt == this.avgRtt &&
          other.bytesTotal == this.bytesTotal &&
          other.failureReason == this.failureReason);
}

class LanTransferRecordsCompanion extends UpdateCompanion<LanTransferRecord> {
  final Value<String> id;
  final Value<String> senderId;
  final Value<String> senderAlias;
  final Value<String> receiverId;
  final Value<String> payloadType;
  final Value<String?> textContent;
  final Value<String?> fileName;
  final Value<int> fileSize;
  final Value<String?> localPath;
  final Value<String?> manifestJson;
  final Value<String> status;
  final Value<int> bytesTransferred;
  final Value<int> createdAt;
  final Value<bool> isIncoming;
  final Value<bool> isRecalled;
  final Value<String?> sftpServerId;
  final Value<String?> sftpRemotePath;
  final Value<String?> transport;
  final Value<String?> routeType;
  final Value<int?> avgRtt;
  final Value<int?> bytesTotal;
  final Value<String?> failureReason;
  final Value<int> rowid;
  const LanTransferRecordsCompanion({
    this.id = const Value.absent(),
    this.senderId = const Value.absent(),
    this.senderAlias = const Value.absent(),
    this.receiverId = const Value.absent(),
    this.payloadType = const Value.absent(),
    this.textContent = const Value.absent(),
    this.fileName = const Value.absent(),
    this.fileSize = const Value.absent(),
    this.localPath = const Value.absent(),
    this.manifestJson = const Value.absent(),
    this.status = const Value.absent(),
    this.bytesTransferred = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.isIncoming = const Value.absent(),
    this.isRecalled = const Value.absent(),
    this.sftpServerId = const Value.absent(),
    this.sftpRemotePath = const Value.absent(),
    this.transport = const Value.absent(),
    this.routeType = const Value.absent(),
    this.avgRtt = const Value.absent(),
    this.bytesTotal = const Value.absent(),
    this.failureReason = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LanTransferRecordsCompanion.insert({
    required String id,
    required String senderId,
    required String senderAlias,
    required String receiverId,
    required String payloadType,
    this.textContent = const Value.absent(),
    this.fileName = const Value.absent(),
    this.fileSize = const Value.absent(),
    this.localPath = const Value.absent(),
    this.manifestJson = const Value.absent(),
    required String status,
    this.bytesTransferred = const Value.absent(),
    required int createdAt,
    this.isIncoming = const Value.absent(),
    this.isRecalled = const Value.absent(),
    this.sftpServerId = const Value.absent(),
    this.sftpRemotePath = const Value.absent(),
    this.transport = const Value.absent(),
    this.routeType = const Value.absent(),
    this.avgRtt = const Value.absent(),
    this.bytesTotal = const Value.absent(),
    this.failureReason = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       senderId = Value(senderId),
       senderAlias = Value(senderAlias),
       receiverId = Value(receiverId),
       payloadType = Value(payloadType),
       status = Value(status),
       createdAt = Value(createdAt);
  static Insertable<LanTransferRecord> custom({
    Expression<String>? id,
    Expression<String>? senderId,
    Expression<String>? senderAlias,
    Expression<String>? receiverId,
    Expression<String>? payloadType,
    Expression<String>? textContent,
    Expression<String>? fileName,
    Expression<int>? fileSize,
    Expression<String>? localPath,
    Expression<String>? manifestJson,
    Expression<String>? status,
    Expression<int>? bytesTransferred,
    Expression<int>? createdAt,
    Expression<bool>? isIncoming,
    Expression<bool>? isRecalled,
    Expression<String>? sftpServerId,
    Expression<String>? sftpRemotePath,
    Expression<String>? transport,
    Expression<String>? routeType,
    Expression<int>? avgRtt,
    Expression<int>? bytesTotal,
    Expression<String>? failureReason,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (senderId != null) 'sender_id': senderId,
      if (senderAlias != null) 'sender_alias': senderAlias,
      if (receiverId != null) 'receiver_id': receiverId,
      if (payloadType != null) 'payload_type': payloadType,
      if (textContent != null) 'text_content': textContent,
      if (fileName != null) 'file_name': fileName,
      if (fileSize != null) 'file_size': fileSize,
      if (localPath != null) 'local_path': localPath,
      if (manifestJson != null) 'manifest_json': manifestJson,
      if (status != null) 'status': status,
      if (bytesTransferred != null) 'bytes_transferred': bytesTransferred,
      if (createdAt != null) 'created_at': createdAt,
      if (isIncoming != null) 'is_incoming': isIncoming,
      if (isRecalled != null) 'is_recalled': isRecalled,
      if (sftpServerId != null) 'sftp_server_id': sftpServerId,
      if (sftpRemotePath != null) 'sftp_remote_path': sftpRemotePath,
      if (transport != null) 'transport': transport,
      if (routeType != null) 'route_type': routeType,
      if (avgRtt != null) 'avg_rtt': avgRtt,
      if (bytesTotal != null) 'bytes_total': bytesTotal,
      if (failureReason != null) 'failure_reason': failureReason,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LanTransferRecordsCompanion copyWith({
    Value<String>? id,
    Value<String>? senderId,
    Value<String>? senderAlias,
    Value<String>? receiverId,
    Value<String>? payloadType,
    Value<String?>? textContent,
    Value<String?>? fileName,
    Value<int>? fileSize,
    Value<String?>? localPath,
    Value<String?>? manifestJson,
    Value<String>? status,
    Value<int>? bytesTransferred,
    Value<int>? createdAt,
    Value<bool>? isIncoming,
    Value<bool>? isRecalled,
    Value<String?>? sftpServerId,
    Value<String?>? sftpRemotePath,
    Value<String?>? transport,
    Value<String?>? routeType,
    Value<int?>? avgRtt,
    Value<int?>? bytesTotal,
    Value<String?>? failureReason,
    Value<int>? rowid,
  }) {
    return LanTransferRecordsCompanion(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      senderAlias: senderAlias ?? this.senderAlias,
      receiverId: receiverId ?? this.receiverId,
      payloadType: payloadType ?? this.payloadType,
      textContent: textContent ?? this.textContent,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      localPath: localPath ?? this.localPath,
      manifestJson: manifestJson ?? this.manifestJson,
      status: status ?? this.status,
      bytesTransferred: bytesTransferred ?? this.bytesTransferred,
      createdAt: createdAt ?? this.createdAt,
      isIncoming: isIncoming ?? this.isIncoming,
      isRecalled: isRecalled ?? this.isRecalled,
      sftpServerId: sftpServerId ?? this.sftpServerId,
      sftpRemotePath: sftpRemotePath ?? this.sftpRemotePath,
      transport: transport ?? this.transport,
      routeType: routeType ?? this.routeType,
      avgRtt: avgRtt ?? this.avgRtt,
      bytesTotal: bytesTotal ?? this.bytesTotal,
      failureReason: failureReason ?? this.failureReason,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (senderId.present) {
      map['sender_id'] = Variable<String>(senderId.value);
    }
    if (senderAlias.present) {
      map['sender_alias'] = Variable<String>(senderAlias.value);
    }
    if (receiverId.present) {
      map['receiver_id'] = Variable<String>(receiverId.value);
    }
    if (payloadType.present) {
      map['payload_type'] = Variable<String>(payloadType.value);
    }
    if (textContent.present) {
      map['text_content'] = Variable<String>(textContent.value);
    }
    if (fileName.present) {
      map['file_name'] = Variable<String>(fileName.value);
    }
    if (fileSize.present) {
      map['file_size'] = Variable<int>(fileSize.value);
    }
    if (localPath.present) {
      map['local_path'] = Variable<String>(localPath.value);
    }
    if (manifestJson.present) {
      map['manifest_json'] = Variable<String>(manifestJson.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (bytesTransferred.present) {
      map['bytes_transferred'] = Variable<int>(bytesTransferred.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (isIncoming.present) {
      map['is_incoming'] = Variable<bool>(isIncoming.value);
    }
    if (isRecalled.present) {
      map['is_recalled'] = Variable<bool>(isRecalled.value);
    }
    if (sftpServerId.present) {
      map['sftp_server_id'] = Variable<String>(sftpServerId.value);
    }
    if (sftpRemotePath.present) {
      map['sftp_remote_path'] = Variable<String>(sftpRemotePath.value);
    }
    if (transport.present) {
      map['transport'] = Variable<String>(transport.value);
    }
    if (routeType.present) {
      map['route_type'] = Variable<String>(routeType.value);
    }
    if (avgRtt.present) {
      map['avg_rtt'] = Variable<int>(avgRtt.value);
    }
    if (bytesTotal.present) {
      map['bytes_total'] = Variable<int>(bytesTotal.value);
    }
    if (failureReason.present) {
      map['failure_reason'] = Variable<String>(failureReason.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LanTransferRecordsCompanion(')
          ..write('id: $id, ')
          ..write('senderId: $senderId, ')
          ..write('senderAlias: $senderAlias, ')
          ..write('receiverId: $receiverId, ')
          ..write('payloadType: $payloadType, ')
          ..write('textContent: $textContent, ')
          ..write('fileName: $fileName, ')
          ..write('fileSize: $fileSize, ')
          ..write('localPath: $localPath, ')
          ..write('manifestJson: $manifestJson, ')
          ..write('status: $status, ')
          ..write('bytesTransferred: $bytesTransferred, ')
          ..write('createdAt: $createdAt, ')
          ..write('isIncoming: $isIncoming, ')
          ..write('isRecalled: $isRecalled, ')
          ..write('sftpServerId: $sftpServerId, ')
          ..write('sftpRemotePath: $sftpRemotePath, ')
          ..write('transport: $transport, ')
          ..write('routeType: $routeType, ')
          ..write('avgRtt: $avgRtt, ')
          ..write('bytesTotal: $bytesTotal, ')
          ..write('failureReason: $failureReason, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AppLogRecordsTable extends AppLogRecords
    with TableInfo<$AppLogRecordsTable, AppLogRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AppLogRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _timeMeta = const VerificationMeta('time');
  @override
  late final GeneratedColumn<int> time = GeneratedColumn<int>(
    'time',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _levelMeta = const VerificationMeta('level');
  @override
  late final GeneratedColumn<String> level = GeneratedColumn<String>(
    'level',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _messageMeta = const VerificationMeta(
    'message',
  );
  @override
  late final GeneratedColumn<String> message = GeneratedColumn<String>(
    'message',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceLocationMeta = const VerificationMeta(
    'sourceLocation',
  );
  @override
  late final GeneratedColumn<String> sourceLocation = GeneratedColumn<String>(
    'source_location',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _stackTraceMeta = const VerificationMeta(
    'stackTrace',
  );
  @override
  late final GeneratedColumn<String> stackTrace = GeneratedColumn<String>(
    'stack_trace',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _detailsMeta = const VerificationMeta(
    'details',
  );
  @override
  late final GeneratedColumn<String> details = GeneratedColumn<String>(
    'details',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    time,
    level,
    message,
    sourceLocation,
    stackTrace,
    details,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'app_log_records';
  @override
  VerificationContext validateIntegrity(
    Insertable<AppLogRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('time')) {
      context.handle(
        _timeMeta,
        time.isAcceptableOrUnknown(data['time']!, _timeMeta),
      );
    } else if (isInserting) {
      context.missing(_timeMeta);
    }
    if (data.containsKey('level')) {
      context.handle(
        _levelMeta,
        level.isAcceptableOrUnknown(data['level']!, _levelMeta),
      );
    } else if (isInserting) {
      context.missing(_levelMeta);
    }
    if (data.containsKey('message')) {
      context.handle(
        _messageMeta,
        message.isAcceptableOrUnknown(data['message']!, _messageMeta),
      );
    } else if (isInserting) {
      context.missing(_messageMeta);
    }
    if (data.containsKey('source_location')) {
      context.handle(
        _sourceLocationMeta,
        sourceLocation.isAcceptableOrUnknown(
          data['source_location']!,
          _sourceLocationMeta,
        ),
      );
    }
    if (data.containsKey('stack_trace')) {
      context.handle(
        _stackTraceMeta,
        stackTrace.isAcceptableOrUnknown(data['stack_trace']!, _stackTraceMeta),
      );
    }
    if (data.containsKey('details')) {
      context.handle(
        _detailsMeta,
        details.isAcceptableOrUnknown(data['details']!, _detailsMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AppLogRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AppLogRecord(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      time: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}time'],
      )!,
      level: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}level'],
      )!,
      message: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message'],
      )!,
      sourceLocation: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_location'],
      ),
      stackTrace: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}stack_trace'],
      ),
      details: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}details'],
      ),
    );
  }

  @override
  $AppLogRecordsTable createAlias(String alias) {
    return $AppLogRecordsTable(attachedDatabase, alias);
  }
}

class AppLogRecord extends DataClass implements Insertable<AppLogRecord> {
  final int id;
  final int time;
  final String level;
  final String message;
  final String? sourceLocation;
  final String? stackTrace;
  final String? details;
  const AppLogRecord({
    required this.id,
    required this.time,
    required this.level,
    required this.message,
    this.sourceLocation,
    this.stackTrace,
    this.details,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['time'] = Variable<int>(time);
    map['level'] = Variable<String>(level);
    map['message'] = Variable<String>(message);
    if (!nullToAbsent || sourceLocation != null) {
      map['source_location'] = Variable<String>(sourceLocation);
    }
    if (!nullToAbsent || stackTrace != null) {
      map['stack_trace'] = Variable<String>(stackTrace);
    }
    if (!nullToAbsent || details != null) {
      map['details'] = Variable<String>(details);
    }
    return map;
  }

  AppLogRecordsCompanion toCompanion(bool nullToAbsent) {
    return AppLogRecordsCompanion(
      id: Value(id),
      time: Value(time),
      level: Value(level),
      message: Value(message),
      sourceLocation: sourceLocation == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceLocation),
      stackTrace: stackTrace == null && nullToAbsent
          ? const Value.absent()
          : Value(stackTrace),
      details: details == null && nullToAbsent
          ? const Value.absent()
          : Value(details),
    );
  }

  factory AppLogRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AppLogRecord(
      id: serializer.fromJson<int>(json['id']),
      time: serializer.fromJson<int>(json['time']),
      level: serializer.fromJson<String>(json['level']),
      message: serializer.fromJson<String>(json['message']),
      sourceLocation: serializer.fromJson<String?>(json['sourceLocation']),
      stackTrace: serializer.fromJson<String?>(json['stackTrace']),
      details: serializer.fromJson<String?>(json['details']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'time': serializer.toJson<int>(time),
      'level': serializer.toJson<String>(level),
      'message': serializer.toJson<String>(message),
      'sourceLocation': serializer.toJson<String?>(sourceLocation),
      'stackTrace': serializer.toJson<String?>(stackTrace),
      'details': serializer.toJson<String?>(details),
    };
  }

  AppLogRecord copyWith({
    int? id,
    int? time,
    String? level,
    String? message,
    Value<String?> sourceLocation = const Value.absent(),
    Value<String?> stackTrace = const Value.absent(),
    Value<String?> details = const Value.absent(),
  }) => AppLogRecord(
    id: id ?? this.id,
    time: time ?? this.time,
    level: level ?? this.level,
    message: message ?? this.message,
    sourceLocation: sourceLocation.present
        ? sourceLocation.value
        : this.sourceLocation,
    stackTrace: stackTrace.present ? stackTrace.value : this.stackTrace,
    details: details.present ? details.value : this.details,
  );
  AppLogRecord copyWithCompanion(AppLogRecordsCompanion data) {
    return AppLogRecord(
      id: data.id.present ? data.id.value : this.id,
      time: data.time.present ? data.time.value : this.time,
      level: data.level.present ? data.level.value : this.level,
      message: data.message.present ? data.message.value : this.message,
      sourceLocation: data.sourceLocation.present
          ? data.sourceLocation.value
          : this.sourceLocation,
      stackTrace: data.stackTrace.present
          ? data.stackTrace.value
          : this.stackTrace,
      details: data.details.present ? data.details.value : this.details,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AppLogRecord(')
          ..write('id: $id, ')
          ..write('time: $time, ')
          ..write('level: $level, ')
          ..write('message: $message, ')
          ..write('sourceLocation: $sourceLocation, ')
          ..write('stackTrace: $stackTrace, ')
          ..write('details: $details')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    time,
    level,
    message,
    sourceLocation,
    stackTrace,
    details,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AppLogRecord &&
          other.id == this.id &&
          other.time == this.time &&
          other.level == this.level &&
          other.message == this.message &&
          other.sourceLocation == this.sourceLocation &&
          other.stackTrace == this.stackTrace &&
          other.details == this.details);
}

class AppLogRecordsCompanion extends UpdateCompanion<AppLogRecord> {
  final Value<int> id;
  final Value<int> time;
  final Value<String> level;
  final Value<String> message;
  final Value<String?> sourceLocation;
  final Value<String?> stackTrace;
  final Value<String?> details;
  const AppLogRecordsCompanion({
    this.id = const Value.absent(),
    this.time = const Value.absent(),
    this.level = const Value.absent(),
    this.message = const Value.absent(),
    this.sourceLocation = const Value.absent(),
    this.stackTrace = const Value.absent(),
    this.details = const Value.absent(),
  });
  AppLogRecordsCompanion.insert({
    this.id = const Value.absent(),
    required int time,
    required String level,
    required String message,
    this.sourceLocation = const Value.absent(),
    this.stackTrace = const Value.absent(),
    this.details = const Value.absent(),
  }) : time = Value(time),
       level = Value(level),
       message = Value(message);
  static Insertable<AppLogRecord> custom({
    Expression<int>? id,
    Expression<int>? time,
    Expression<String>? level,
    Expression<String>? message,
    Expression<String>? sourceLocation,
    Expression<String>? stackTrace,
    Expression<String>? details,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (time != null) 'time': time,
      if (level != null) 'level': level,
      if (message != null) 'message': message,
      if (sourceLocation != null) 'source_location': sourceLocation,
      if (stackTrace != null) 'stack_trace': stackTrace,
      if (details != null) 'details': details,
    });
  }

  AppLogRecordsCompanion copyWith({
    Value<int>? id,
    Value<int>? time,
    Value<String>? level,
    Value<String>? message,
    Value<String?>? sourceLocation,
    Value<String?>? stackTrace,
    Value<String?>? details,
  }) {
    return AppLogRecordsCompanion(
      id: id ?? this.id,
      time: time ?? this.time,
      level: level ?? this.level,
      message: message ?? this.message,
      sourceLocation: sourceLocation ?? this.sourceLocation,
      stackTrace: stackTrace ?? this.stackTrace,
      details: details ?? this.details,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (time.present) {
      map['time'] = Variable<int>(time.value);
    }
    if (level.present) {
      map['level'] = Variable<String>(level.value);
    }
    if (message.present) {
      map['message'] = Variable<String>(message.value);
    }
    if (sourceLocation.present) {
      map['source_location'] = Variable<String>(sourceLocation.value);
    }
    if (stackTrace.present) {
      map['stack_trace'] = Variable<String>(stackTrace.value);
    }
    if (details.present) {
      map['details'] = Variable<String>(details.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AppLogRecordsCompanion(')
          ..write('id: $id, ')
          ..write('time: $time, ')
          ..write('level: $level, ')
          ..write('message: $message, ')
          ..write('sourceLocation: $sourceLocation, ')
          ..write('stackTrace: $stackTrace, ')
          ..write('details: $details')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $TerminalHistoryRecordsTable terminalHistoryRecords =
      $TerminalHistoryRecordsTable(this);
  late final $PlaybooksTable playbooks = $PlaybooksTable(this);
  late final $PlaybookRunsTable playbookRuns = $PlaybookRunsTable(this);
  late final $PlaybookRunStepsTable playbookRunSteps = $PlaybookRunStepsTable(
    this,
  );
  late final $SftpRecentPathsTable sftpRecentPaths = $SftpRecentPathsTable(
    this,
  );
  late final $SftpFavoritePathsTable sftpFavoritePaths =
      $SftpFavoritePathsTable(this);
  late final $LanTransferRecordsTable lanTransferRecords =
      $LanTransferRecordsTable(this);
  late final $AppLogRecordsTable appLogRecords = $AppLogRecordsTable(this);
  late final TerminalHistoryDao terminalHistoryDao = TerminalHistoryDao(
    this as AppDatabase,
  );
  late final PlaybookDao playbookDao = PlaybookDao(this as AppDatabase);
  late final SftpHistoryDao sftpHistoryDao = SftpHistoryDao(
    this as AppDatabase,
  );
  late final LanHistoryDao lanHistoryDao = LanHistoryDao(this as AppDatabase);
  late final AppLogDao appLogDao = AppLogDao(this as AppDatabase);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    terminalHistoryRecords,
    playbooks,
    playbookRuns,
    playbookRunSteps,
    sftpRecentPaths,
    sftpFavoritePaths,
    lanTransferRecords,
    appLogRecords,
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

typedef $$TerminalHistoryRecordsTableCreateCompanionBuilder =
    TerminalHistoryRecordsCompanion Function({
      required String sessionId,
      required String connectionId,
      required String connectionName,
      required String displayName,
      Value<String?> tmuxSessionName,
      required String state,
      Value<String?> errorMessage,
      required int createdAt,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$TerminalHistoryRecordsTableUpdateCompanionBuilder =
    TerminalHistoryRecordsCompanion Function({
      Value<String> sessionId,
      Value<String> connectionId,
      Value<String> connectionName,
      Value<String> displayName,
      Value<String?> tmuxSessionName,
      Value<String> state,
      Value<String?> errorMessage,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int> rowid,
    });

class $$TerminalHistoryRecordsTableFilterComposer
    extends Composer<_$AppDatabase, $TerminalHistoryRecordsTable> {
  $$TerminalHistoryRecordsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get sessionId => $composableBuilder(
    column: $table.sessionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get connectionName => $composableBuilder(
    column: $table.connectionName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tmuxSessionName => $composableBuilder(
    column: $table.tmuxSessionName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get errorMessage => $composableBuilder(
    column: $table.errorMessage,
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

class $$TerminalHistoryRecordsTableOrderingComposer
    extends Composer<_$AppDatabase, $TerminalHistoryRecordsTable> {
  $$TerminalHistoryRecordsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get sessionId => $composableBuilder(
    column: $table.sessionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get connectionName => $composableBuilder(
    column: $table.connectionName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tmuxSessionName => $composableBuilder(
    column: $table.tmuxSessionName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get errorMessage => $composableBuilder(
    column: $table.errorMessage,
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

class $$TerminalHistoryRecordsTableAnnotationComposer
    extends Composer<_$AppDatabase, $TerminalHistoryRecordsTable> {
  $$TerminalHistoryRecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get sessionId =>
      $composableBuilder(column: $table.sessionId, builder: (column) => column);

  GeneratedColumn<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get connectionName => $composableBuilder(
    column: $table.connectionName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get tmuxSessionName => $composableBuilder(
    column: $table.tmuxSessionName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<String> get errorMessage => $composableBuilder(
    column: $table.errorMessage,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$TerminalHistoryRecordsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TerminalHistoryRecordsTable,
          TerminalHistoryRecord,
          $$TerminalHistoryRecordsTableFilterComposer,
          $$TerminalHistoryRecordsTableOrderingComposer,
          $$TerminalHistoryRecordsTableAnnotationComposer,
          $$TerminalHistoryRecordsTableCreateCompanionBuilder,
          $$TerminalHistoryRecordsTableUpdateCompanionBuilder,
          (
            TerminalHistoryRecord,
            BaseReferences<
              _$AppDatabase,
              $TerminalHistoryRecordsTable,
              TerminalHistoryRecord
            >,
          ),
          TerminalHistoryRecord,
          PrefetchHooks Function()
        > {
  $$TerminalHistoryRecordsTableTableManager(
    _$AppDatabase db,
    $TerminalHistoryRecordsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TerminalHistoryRecordsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$TerminalHistoryRecordsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$TerminalHistoryRecordsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> sessionId = const Value.absent(),
                Value<String> connectionId = const Value.absent(),
                Value<String> connectionName = const Value.absent(),
                Value<String> displayName = const Value.absent(),
                Value<String?> tmuxSessionName = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<String?> errorMessage = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TerminalHistoryRecordsCompanion(
                sessionId: sessionId,
                connectionId: connectionId,
                connectionName: connectionName,
                displayName: displayName,
                tmuxSessionName: tmuxSessionName,
                state: state,
                errorMessage: errorMessage,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String sessionId,
                required String connectionId,
                required String connectionName,
                required String displayName,
                Value<String?> tmuxSessionName = const Value.absent(),
                required String state,
                Value<String?> errorMessage = const Value.absent(),
                required int createdAt,
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => TerminalHistoryRecordsCompanion.insert(
                sessionId: sessionId,
                connectionId: connectionId,
                connectionName: connectionName,
                displayName: displayName,
                tmuxSessionName: tmuxSessionName,
                state: state,
                errorMessage: errorMessage,
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

typedef $$TerminalHistoryRecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TerminalHistoryRecordsTable,
      TerminalHistoryRecord,
      $$TerminalHistoryRecordsTableFilterComposer,
      $$TerminalHistoryRecordsTableOrderingComposer,
      $$TerminalHistoryRecordsTableAnnotationComposer,
      $$TerminalHistoryRecordsTableCreateCompanionBuilder,
      $$TerminalHistoryRecordsTableUpdateCompanionBuilder,
      (
        TerminalHistoryRecord,
        BaseReferences<
          _$AppDatabase,
          $TerminalHistoryRecordsTable,
          TerminalHistoryRecord
        >,
      ),
      TerminalHistoryRecord,
      PrefetchHooks Function()
    >;
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
    extends BaseReferences<_$AppDatabase, $PlaybooksTable, Playbook> {
  $$PlaybooksTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$PlaybookRunsTable, List<PlaybookRun>>
  _playbookRunsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
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
    extends Composer<_$AppDatabase, $PlaybooksTable> {
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
    extends Composer<_$AppDatabase, $PlaybooksTable> {
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
    extends Composer<_$AppDatabase, $PlaybooksTable> {
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
          _$AppDatabase,
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
  $$PlaybooksTableTableManager(_$AppDatabase db, $PlaybooksTable table)
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
      _$AppDatabase,
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
    extends BaseReferences<_$AppDatabase, $PlaybookRunsTable, PlaybookRun> {
  $$PlaybookRunsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $PlaybooksTable _playbookIdTable(_$AppDatabase db) =>
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
  _playbookRunStepsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
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
    extends Composer<_$AppDatabase, $PlaybookRunsTable> {
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
    extends Composer<_$AppDatabase, $PlaybookRunsTable> {
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
    extends Composer<_$AppDatabase, $PlaybookRunsTable> {
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
          _$AppDatabase,
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
  $$PlaybookRunsTableTableManager(_$AppDatabase db, $PlaybookRunsTable table)
    : super(
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
      _$AppDatabase,
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
      required String name,
      required String command,
      required String status,
      Value<String?> stdoutPreview,
      Value<String?> stderrPreview,
      Value<int?> exitCode,
      Value<int> rowid,
    });
typedef $$PlaybookRunStepsTableUpdateCompanionBuilder =
    PlaybookRunStepsCompanion Function({
      Value<String> id,
      Value<String> runId,
      Value<int> stepIndex,
      Value<String> name,
      Value<String> command,
      Value<String> status,
      Value<String?> stdoutPreview,
      Value<String?> stderrPreview,
      Value<int?> exitCode,
      Value<int> rowid,
    });

final class $$PlaybookRunStepsTableReferences
    extends
        BaseReferences<_$AppDatabase, $PlaybookRunStepsTable, PlaybookRunStep> {
  $$PlaybookRunStepsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $PlaybookRunsTable _runIdTable(_$AppDatabase db) => db.playbookRuns
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
    extends Composer<_$AppDatabase, $PlaybookRunStepsTable> {
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

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get command => $composableBuilder(
    column: $table.command,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stdoutPreview => $composableBuilder(
    column: $table.stdoutPreview,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stderrPreview => $composableBuilder(
    column: $table.stderrPreview,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get exitCode => $composableBuilder(
    column: $table.exitCode,
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
    extends Composer<_$AppDatabase, $PlaybookRunStepsTable> {
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

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get command => $composableBuilder(
    column: $table.command,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stdoutPreview => $composableBuilder(
    column: $table.stdoutPreview,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stderrPreview => $composableBuilder(
    column: $table.stderrPreview,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get exitCode => $composableBuilder(
    column: $table.exitCode,
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
    extends Composer<_$AppDatabase, $PlaybookRunStepsTable> {
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

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get command =>
      $composableBuilder(column: $table.command, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get stdoutPreview => $composableBuilder(
    column: $table.stdoutPreview,
    builder: (column) => column,
  );

  GeneratedColumn<String> get stderrPreview => $composableBuilder(
    column: $table.stderrPreview,
    builder: (column) => column,
  );

  GeneratedColumn<int> get exitCode =>
      $composableBuilder(column: $table.exitCode, builder: (column) => column);

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
          _$AppDatabase,
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
    _$AppDatabase db,
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
                Value<String> name = const Value.absent(),
                Value<String> command = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String?> stdoutPreview = const Value.absent(),
                Value<String?> stderrPreview = const Value.absent(),
                Value<int?> exitCode = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PlaybookRunStepsCompanion(
                id: id,
                runId: runId,
                stepIndex: stepIndex,
                name: name,
                command: command,
                status: status,
                stdoutPreview: stdoutPreview,
                stderrPreview: stderrPreview,
                exitCode: exitCode,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String runId,
                required int stepIndex,
                required String name,
                required String command,
                required String status,
                Value<String?> stdoutPreview = const Value.absent(),
                Value<String?> stderrPreview = const Value.absent(),
                Value<int?> exitCode = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PlaybookRunStepsCompanion.insert(
                id: id,
                runId: runId,
                stepIndex: stepIndex,
                name: name,
                command: command,
                status: status,
                stdoutPreview: stdoutPreview,
                stderrPreview: stderrPreview,
                exitCode: exitCode,
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
      _$AppDatabase,
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
    extends Composer<_$AppDatabase, $SftpRecentPathsTable> {
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
    extends Composer<_$AppDatabase, $SftpRecentPathsTable> {
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
    extends Composer<_$AppDatabase, $SftpRecentPathsTable> {
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
          _$AppDatabase,
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
              _$AppDatabase,
              $SftpRecentPathsTable,
              SftpRecentPath
            >,
          ),
          SftpRecentPath,
          PrefetchHooks Function()
        > {
  $$SftpRecentPathsTableTableManager(
    _$AppDatabase db,
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
      _$AppDatabase,
      $SftpRecentPathsTable,
      SftpRecentPath,
      $$SftpRecentPathsTableFilterComposer,
      $$SftpRecentPathsTableOrderingComposer,
      $$SftpRecentPathsTableAnnotationComposer,
      $$SftpRecentPathsTableCreateCompanionBuilder,
      $$SftpRecentPathsTableUpdateCompanionBuilder,
      (
        SftpRecentPath,
        BaseReferences<_$AppDatabase, $SftpRecentPathsTable, SftpRecentPath>,
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
    extends Composer<_$AppDatabase, $SftpFavoritePathsTable> {
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
    extends Composer<_$AppDatabase, $SftpFavoritePathsTable> {
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
    extends Composer<_$AppDatabase, $SftpFavoritePathsTable> {
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
          _$AppDatabase,
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
              _$AppDatabase,
              $SftpFavoritePathsTable,
              SftpFavoritePath
            >,
          ),
          SftpFavoritePath,
          PrefetchHooks Function()
        > {
  $$SftpFavoritePathsTableTableManager(
    _$AppDatabase db,
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
      _$AppDatabase,
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
          _$AppDatabase,
          $SftpFavoritePathsTable,
          SftpFavoritePath
        >,
      ),
      SftpFavoritePath,
      PrefetchHooks Function()
    >;
typedef $$LanTransferRecordsTableCreateCompanionBuilder =
    LanTransferRecordsCompanion Function({
      required String id,
      required String senderId,
      required String senderAlias,
      required String receiverId,
      required String payloadType,
      Value<String?> textContent,
      Value<String?> fileName,
      Value<int> fileSize,
      Value<String?> localPath,
      Value<String?> manifestJson,
      required String status,
      Value<int> bytesTransferred,
      required int createdAt,
      Value<bool> isIncoming,
      Value<bool> isRecalled,
      Value<String?> sftpServerId,
      Value<String?> sftpRemotePath,
      Value<String?> transport,
      Value<String?> routeType,
      Value<int?> avgRtt,
      Value<int?> bytesTotal,
      Value<String?> failureReason,
      Value<int> rowid,
    });
typedef $$LanTransferRecordsTableUpdateCompanionBuilder =
    LanTransferRecordsCompanion Function({
      Value<String> id,
      Value<String> senderId,
      Value<String> senderAlias,
      Value<String> receiverId,
      Value<String> payloadType,
      Value<String?> textContent,
      Value<String?> fileName,
      Value<int> fileSize,
      Value<String?> localPath,
      Value<String?> manifestJson,
      Value<String> status,
      Value<int> bytesTransferred,
      Value<int> createdAt,
      Value<bool> isIncoming,
      Value<bool> isRecalled,
      Value<String?> sftpServerId,
      Value<String?> sftpRemotePath,
      Value<String?> transport,
      Value<String?> routeType,
      Value<int?> avgRtt,
      Value<int?> bytesTotal,
      Value<String?> failureReason,
      Value<int> rowid,
    });

class $$LanTransferRecordsTableFilterComposer
    extends Composer<_$AppDatabase, $LanTransferRecordsTable> {
  $$LanTransferRecordsTableFilterComposer({
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

  ColumnFilters<String> get senderId => $composableBuilder(
    column: $table.senderId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get senderAlias => $composableBuilder(
    column: $table.senderAlias,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get receiverId => $composableBuilder(
    column: $table.receiverId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payloadType => $composableBuilder(
    column: $table.payloadType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get textContent => $composableBuilder(
    column: $table.textContent,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get fileSize => $composableBuilder(
    column: $table.fileSize,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localPath => $composableBuilder(
    column: $table.localPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get manifestJson => $composableBuilder(
    column: $table.manifestJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bytesTransferred => $composableBuilder(
    column: $table.bytesTransferred,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isIncoming => $composableBuilder(
    column: $table.isIncoming,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isRecalled => $composableBuilder(
    column: $table.isRecalled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sftpServerId => $composableBuilder(
    column: $table.sftpServerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sftpRemotePath => $composableBuilder(
    column: $table.sftpRemotePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get transport => $composableBuilder(
    column: $table.transport,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get routeType => $composableBuilder(
    column: $table.routeType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get avgRtt => $composableBuilder(
    column: $table.avgRtt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bytesTotal => $composableBuilder(
    column: $table.bytesTotal,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get failureReason => $composableBuilder(
    column: $table.failureReason,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LanTransferRecordsTableOrderingComposer
    extends Composer<_$AppDatabase, $LanTransferRecordsTable> {
  $$LanTransferRecordsTableOrderingComposer({
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

  ColumnOrderings<String> get senderId => $composableBuilder(
    column: $table.senderId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get senderAlias => $composableBuilder(
    column: $table.senderAlias,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get receiverId => $composableBuilder(
    column: $table.receiverId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadType => $composableBuilder(
    column: $table.payloadType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get textContent => $composableBuilder(
    column: $table.textContent,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get fileSize => $composableBuilder(
    column: $table.fileSize,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localPath => $composableBuilder(
    column: $table.localPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get manifestJson => $composableBuilder(
    column: $table.manifestJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bytesTransferred => $composableBuilder(
    column: $table.bytesTransferred,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isIncoming => $composableBuilder(
    column: $table.isIncoming,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isRecalled => $composableBuilder(
    column: $table.isRecalled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sftpServerId => $composableBuilder(
    column: $table.sftpServerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sftpRemotePath => $composableBuilder(
    column: $table.sftpRemotePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get transport => $composableBuilder(
    column: $table.transport,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get routeType => $composableBuilder(
    column: $table.routeType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get avgRtt => $composableBuilder(
    column: $table.avgRtt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bytesTotal => $composableBuilder(
    column: $table.bytesTotal,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get failureReason => $composableBuilder(
    column: $table.failureReason,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LanTransferRecordsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LanTransferRecordsTable> {
  $$LanTransferRecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get senderId =>
      $composableBuilder(column: $table.senderId, builder: (column) => column);

  GeneratedColumn<String> get senderAlias => $composableBuilder(
    column: $table.senderAlias,
    builder: (column) => column,
  );

  GeneratedColumn<String> get receiverId => $composableBuilder(
    column: $table.receiverId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get payloadType => $composableBuilder(
    column: $table.payloadType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get textContent => $composableBuilder(
    column: $table.textContent,
    builder: (column) => column,
  );

  GeneratedColumn<String> get fileName =>
      $composableBuilder(column: $table.fileName, builder: (column) => column);

  GeneratedColumn<int> get fileSize =>
      $composableBuilder(column: $table.fileSize, builder: (column) => column);

  GeneratedColumn<String> get localPath =>
      $composableBuilder(column: $table.localPath, builder: (column) => column);

  GeneratedColumn<String> get manifestJson => $composableBuilder(
    column: $table.manifestJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get bytesTransferred => $composableBuilder(
    column: $table.bytesTransferred,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<bool> get isIncoming => $composableBuilder(
    column: $table.isIncoming,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isRecalled => $composableBuilder(
    column: $table.isRecalled,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sftpServerId => $composableBuilder(
    column: $table.sftpServerId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sftpRemotePath => $composableBuilder(
    column: $table.sftpRemotePath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get transport =>
      $composableBuilder(column: $table.transport, builder: (column) => column);

  GeneratedColumn<String> get routeType =>
      $composableBuilder(column: $table.routeType, builder: (column) => column);

  GeneratedColumn<int> get avgRtt =>
      $composableBuilder(column: $table.avgRtt, builder: (column) => column);

  GeneratedColumn<int> get bytesTotal => $composableBuilder(
    column: $table.bytesTotal,
    builder: (column) => column,
  );

  GeneratedColumn<String> get failureReason => $composableBuilder(
    column: $table.failureReason,
    builder: (column) => column,
  );
}

class $$LanTransferRecordsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LanTransferRecordsTable,
          LanTransferRecord,
          $$LanTransferRecordsTableFilterComposer,
          $$LanTransferRecordsTableOrderingComposer,
          $$LanTransferRecordsTableAnnotationComposer,
          $$LanTransferRecordsTableCreateCompanionBuilder,
          $$LanTransferRecordsTableUpdateCompanionBuilder,
          (
            LanTransferRecord,
            BaseReferences<
              _$AppDatabase,
              $LanTransferRecordsTable,
              LanTransferRecord
            >,
          ),
          LanTransferRecord,
          PrefetchHooks Function()
        > {
  $$LanTransferRecordsTableTableManager(
    _$AppDatabase db,
    $LanTransferRecordsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LanTransferRecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LanTransferRecordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LanTransferRecordsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> senderId = const Value.absent(),
                Value<String> senderAlias = const Value.absent(),
                Value<String> receiverId = const Value.absent(),
                Value<String> payloadType = const Value.absent(),
                Value<String?> textContent = const Value.absent(),
                Value<String?> fileName = const Value.absent(),
                Value<int> fileSize = const Value.absent(),
                Value<String?> localPath = const Value.absent(),
                Value<String?> manifestJson = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> bytesTransferred = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<bool> isIncoming = const Value.absent(),
                Value<bool> isRecalled = const Value.absent(),
                Value<String?> sftpServerId = const Value.absent(),
                Value<String?> sftpRemotePath = const Value.absent(),
                Value<String?> transport = const Value.absent(),
                Value<String?> routeType = const Value.absent(),
                Value<int?> avgRtt = const Value.absent(),
                Value<int?> bytesTotal = const Value.absent(),
                Value<String?> failureReason = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LanTransferRecordsCompanion(
                id: id,
                senderId: senderId,
                senderAlias: senderAlias,
                receiverId: receiverId,
                payloadType: payloadType,
                textContent: textContent,
                fileName: fileName,
                fileSize: fileSize,
                localPath: localPath,
                manifestJson: manifestJson,
                status: status,
                bytesTransferred: bytesTransferred,
                createdAt: createdAt,
                isIncoming: isIncoming,
                isRecalled: isRecalled,
                sftpServerId: sftpServerId,
                sftpRemotePath: sftpRemotePath,
                transport: transport,
                routeType: routeType,
                avgRtt: avgRtt,
                bytesTotal: bytesTotal,
                failureReason: failureReason,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String senderId,
                required String senderAlias,
                required String receiverId,
                required String payloadType,
                Value<String?> textContent = const Value.absent(),
                Value<String?> fileName = const Value.absent(),
                Value<int> fileSize = const Value.absent(),
                Value<String?> localPath = const Value.absent(),
                Value<String?> manifestJson = const Value.absent(),
                required String status,
                Value<int> bytesTransferred = const Value.absent(),
                required int createdAt,
                Value<bool> isIncoming = const Value.absent(),
                Value<bool> isRecalled = const Value.absent(),
                Value<String?> sftpServerId = const Value.absent(),
                Value<String?> sftpRemotePath = const Value.absent(),
                Value<String?> transport = const Value.absent(),
                Value<String?> routeType = const Value.absent(),
                Value<int?> avgRtt = const Value.absent(),
                Value<int?> bytesTotal = const Value.absent(),
                Value<String?> failureReason = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LanTransferRecordsCompanion.insert(
                id: id,
                senderId: senderId,
                senderAlias: senderAlias,
                receiverId: receiverId,
                payloadType: payloadType,
                textContent: textContent,
                fileName: fileName,
                fileSize: fileSize,
                localPath: localPath,
                manifestJson: manifestJson,
                status: status,
                bytesTransferred: bytesTransferred,
                createdAt: createdAt,
                isIncoming: isIncoming,
                isRecalled: isRecalled,
                sftpServerId: sftpServerId,
                sftpRemotePath: sftpRemotePath,
                transport: transport,
                routeType: routeType,
                avgRtt: avgRtt,
                bytesTotal: bytesTotal,
                failureReason: failureReason,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LanTransferRecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LanTransferRecordsTable,
      LanTransferRecord,
      $$LanTransferRecordsTableFilterComposer,
      $$LanTransferRecordsTableOrderingComposer,
      $$LanTransferRecordsTableAnnotationComposer,
      $$LanTransferRecordsTableCreateCompanionBuilder,
      $$LanTransferRecordsTableUpdateCompanionBuilder,
      (
        LanTransferRecord,
        BaseReferences<
          _$AppDatabase,
          $LanTransferRecordsTable,
          LanTransferRecord
        >,
      ),
      LanTransferRecord,
      PrefetchHooks Function()
    >;
typedef $$AppLogRecordsTableCreateCompanionBuilder =
    AppLogRecordsCompanion Function({
      Value<int> id,
      required int time,
      required String level,
      required String message,
      Value<String?> sourceLocation,
      Value<String?> stackTrace,
      Value<String?> details,
    });
typedef $$AppLogRecordsTableUpdateCompanionBuilder =
    AppLogRecordsCompanion Function({
      Value<int> id,
      Value<int> time,
      Value<String> level,
      Value<String> message,
      Value<String?> sourceLocation,
      Value<String?> stackTrace,
      Value<String?> details,
    });

class $$AppLogRecordsTableFilterComposer
    extends Composer<_$AppDatabase, $AppLogRecordsTable> {
  $$AppLogRecordsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get time => $composableBuilder(
    column: $table.time,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get level => $composableBuilder(
    column: $table.level,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get message => $composableBuilder(
    column: $table.message,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceLocation => $composableBuilder(
    column: $table.sourceLocation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stackTrace => $composableBuilder(
    column: $table.stackTrace,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get details => $composableBuilder(
    column: $table.details,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AppLogRecordsTableOrderingComposer
    extends Composer<_$AppDatabase, $AppLogRecordsTable> {
  $$AppLogRecordsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get time => $composableBuilder(
    column: $table.time,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get level => $composableBuilder(
    column: $table.level,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get message => $composableBuilder(
    column: $table.message,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceLocation => $composableBuilder(
    column: $table.sourceLocation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stackTrace => $composableBuilder(
    column: $table.stackTrace,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get details => $composableBuilder(
    column: $table.details,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AppLogRecordsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AppLogRecordsTable> {
  $$AppLogRecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get time =>
      $composableBuilder(column: $table.time, builder: (column) => column);

  GeneratedColumn<String> get level =>
      $composableBuilder(column: $table.level, builder: (column) => column);

  GeneratedColumn<String> get message =>
      $composableBuilder(column: $table.message, builder: (column) => column);

  GeneratedColumn<String> get sourceLocation => $composableBuilder(
    column: $table.sourceLocation,
    builder: (column) => column,
  );

  GeneratedColumn<String> get stackTrace => $composableBuilder(
    column: $table.stackTrace,
    builder: (column) => column,
  );

  GeneratedColumn<String> get details =>
      $composableBuilder(column: $table.details, builder: (column) => column);
}

class $$AppLogRecordsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AppLogRecordsTable,
          AppLogRecord,
          $$AppLogRecordsTableFilterComposer,
          $$AppLogRecordsTableOrderingComposer,
          $$AppLogRecordsTableAnnotationComposer,
          $$AppLogRecordsTableCreateCompanionBuilder,
          $$AppLogRecordsTableUpdateCompanionBuilder,
          (
            AppLogRecord,
            BaseReferences<_$AppDatabase, $AppLogRecordsTable, AppLogRecord>,
          ),
          AppLogRecord,
          PrefetchHooks Function()
        > {
  $$AppLogRecordsTableTableManager(_$AppDatabase db, $AppLogRecordsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AppLogRecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AppLogRecordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AppLogRecordsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> time = const Value.absent(),
                Value<String> level = const Value.absent(),
                Value<String> message = const Value.absent(),
                Value<String?> sourceLocation = const Value.absent(),
                Value<String?> stackTrace = const Value.absent(),
                Value<String?> details = const Value.absent(),
              }) => AppLogRecordsCompanion(
                id: id,
                time: time,
                level: level,
                message: message,
                sourceLocation: sourceLocation,
                stackTrace: stackTrace,
                details: details,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int time,
                required String level,
                required String message,
                Value<String?> sourceLocation = const Value.absent(),
                Value<String?> stackTrace = const Value.absent(),
                Value<String?> details = const Value.absent(),
              }) => AppLogRecordsCompanion.insert(
                id: id,
                time: time,
                level: level,
                message: message,
                sourceLocation: sourceLocation,
                stackTrace: stackTrace,
                details: details,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AppLogRecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AppLogRecordsTable,
      AppLogRecord,
      $$AppLogRecordsTableFilterComposer,
      $$AppLogRecordsTableOrderingComposer,
      $$AppLogRecordsTableAnnotationComposer,
      $$AppLogRecordsTableCreateCompanionBuilder,
      $$AppLogRecordsTableUpdateCompanionBuilder,
      (
        AppLogRecord,
        BaseReferences<_$AppDatabase, $AppLogRecordsTable, AppLogRecord>,
      ),
      AppLogRecord,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$TerminalHistoryRecordsTableTableManager get terminalHistoryRecords =>
      $$TerminalHistoryRecordsTableTableManager(
        _db,
        _db.terminalHistoryRecords,
      );
  $$PlaybooksTableTableManager get playbooks =>
      $$PlaybooksTableTableManager(_db, _db.playbooks);
  $$PlaybookRunsTableTableManager get playbookRuns =>
      $$PlaybookRunsTableTableManager(_db, _db.playbookRuns);
  $$PlaybookRunStepsTableTableManager get playbookRunSteps =>
      $$PlaybookRunStepsTableTableManager(_db, _db.playbookRunSteps);
  $$SftpRecentPathsTableTableManager get sftpRecentPaths =>
      $$SftpRecentPathsTableTableManager(_db, _db.sftpRecentPaths);
  $$SftpFavoritePathsTableTableManager get sftpFavoritePaths =>
      $$SftpFavoritePathsTableTableManager(_db, _db.sftpFavoritePaths);
  $$LanTransferRecordsTableTableManager get lanTransferRecords =>
      $$LanTransferRecordsTableTableManager(_db, _db.lanTransferRecords);
  $$AppLogRecordsTableTableManager get appLogRecords =>
      $$AppLogRecordsTableTableManager(_db, _db.appLogRecords);
}

mixin _$TerminalHistoryDaoMixin on DatabaseAccessor<AppDatabase> {
  $TerminalHistoryRecordsTable get terminalHistoryRecords =>
      attachedDatabase.terminalHistoryRecords;
  TerminalHistoryDaoManager get managers => TerminalHistoryDaoManager(this);
}

class TerminalHistoryDaoManager {
  final _$TerminalHistoryDaoMixin _db;
  TerminalHistoryDaoManager(this._db);
  $$TerminalHistoryRecordsTableTableManager get terminalHistoryRecords =>
      $$TerminalHistoryRecordsTableTableManager(
        _db.attachedDatabase,
        _db.terminalHistoryRecords,
      );
}

mixin _$PlaybookDaoMixin on DatabaseAccessor<AppDatabase> {
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

mixin _$SftpHistoryDaoMixin on DatabaseAccessor<AppDatabase> {
  $SftpRecentPathsTable get sftpRecentPaths => attachedDatabase.sftpRecentPaths;
  $SftpFavoritePathsTable get sftpFavoritePaths =>
      attachedDatabase.sftpFavoritePaths;
  SftpHistoryDaoManager get managers => SftpHistoryDaoManager(this);
}

class SftpHistoryDaoManager {
  final _$SftpHistoryDaoMixin _db;
  SftpHistoryDaoManager(this._db);
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

mixin _$LanHistoryDaoMixin on DatabaseAccessor<AppDatabase> {
  $LanTransferRecordsTable get lanTransferRecords =>
      attachedDatabase.lanTransferRecords;
  LanHistoryDaoManager get managers => LanHistoryDaoManager(this);
}

class LanHistoryDaoManager {
  final _$LanHistoryDaoMixin _db;
  LanHistoryDaoManager(this._db);
  $$LanTransferRecordsTableTableManager get lanTransferRecords =>
      $$LanTransferRecordsTableTableManager(
        _db.attachedDatabase,
        _db.lanTransferRecords,
      );
}

mixin _$AppLogDaoMixin on DatabaseAccessor<AppDatabase> {
  $AppLogRecordsTable get appLogRecords => attachedDatabase.appLogRecords;
  AppLogDaoManager get managers => AppLogDaoManager(this);
}

class AppLogDaoManager {
  final _$AppLogDaoMixin _db;
  AppLogDaoManager(this._db);
  $$AppLogRecordsTableTableManager get appLogRecords =>
      $$AppLogRecordsTableTableManager(_db.attachedDatabase, _db.appLogRecords);
}
