// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $MigrationMetaTable extends MigrationMeta
    with TableInfo<$MigrationMetaTable, MigrationMetaData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MigrationMetaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
      'key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
      'value', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [key, value, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'migration_meta';
  @override
  VerificationContext validateIntegrity(Insertable<MigrationMetaData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
          _keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
          _valueMeta, value.isAcceptableOrUnknown(data['value']!, _valueMeta));
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  MigrationMetaData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MigrationMetaData(
      key: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      value: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}value'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $MigrationMetaTable createAlias(String alias) {
    return $MigrationMetaTable(attachedDatabase, alias);
  }
}

class MigrationMetaData extends DataClass
    implements Insertable<MigrationMetaData> {
  final String key;
  final String value;
  final int updatedAt;
  const MigrationMetaData(
      {required this.key, required this.value, required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  MigrationMetaCompanion toCompanion(bool nullToAbsent) {
    return MigrationMetaCompanion(
      key: Value(key),
      value: Value(value),
      updatedAt: Value(updatedAt),
    );
  }

  factory MigrationMetaData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MigrationMetaData(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  MigrationMetaData copyWith({String? key, String? value, int? updatedAt}) =>
      MigrationMetaData(
        key: key ?? this.key,
        value: value ?? this.value,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  MigrationMetaData copyWithCompanion(MigrationMetaCompanion data) {
    return MigrationMetaData(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MigrationMetaData(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MigrationMetaData &&
          other.key == this.key &&
          other.value == this.value &&
          other.updatedAt == this.updatedAt);
}

class MigrationMetaCompanion extends UpdateCompanion<MigrationMetaData> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const MigrationMetaCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MigrationMetaCompanion.insert({
    required String key,
    required String value,
    required int updatedAt,
    this.rowid = const Value.absent(),
  })  : key = Value(key),
        value = Value(value),
        updatedAt = Value(updatedAt);
  static Insertable<MigrationMetaData> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MigrationMetaCompanion copyWith(
      {Value<String>? key,
      Value<String>? value,
      Value<int>? updatedAt,
      Value<int>? rowid}) {
    return MigrationMetaCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
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
    return (StringBuffer('MigrationMetaCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AiChatsTable extends AiChats with TableInfo<$AiChatsTable, AiChat> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AiChatsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _modelMeta = const VerificationMeta('model');
  @override
  late final GeneratedColumn<String> model = GeneratedColumn<String>(
      'model', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _planModeMeta =
      const VerificationMeta('planMode');
  @override
  late final GeneratedColumn<bool> planMode = GeneratedColumn<bool>(
      'plan_mode', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("plan_mode" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _approvedPlanAssistantCreatedAtMeta =
      const VerificationMeta('approvedPlanAssistantCreatedAt');
  @override
  late final GeneratedColumn<int> approvedPlanAssistantCreatedAt =
      GeneratedColumn<int>(
          'approved_plan_assistant_created_at', aliasedName, true,
          type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _approvedPlanApprovedAtMeta =
      const VerificationMeta('approvedPlanApprovedAt');
  @override
  late final GeneratedColumn<int> approvedPlanApprovedAt = GeneratedColumn<int>(
      'approved_plan_approved_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        title,
        model,
        createdAt,
        updatedAt,
        planMode,
        approvedPlanAssistantCreatedAt,
        approvedPlanApprovedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ai_chats';
  @override
  VerificationContext validateIntegrity(Insertable<AiChat> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('model')) {
      context.handle(
          _modelMeta, model.isAcceptableOrUnknown(data['model']!, _modelMeta));
    } else if (isInserting) {
      context.missing(_modelMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('plan_mode')) {
      context.handle(_planModeMeta,
          planMode.isAcceptableOrUnknown(data['plan_mode']!, _planModeMeta));
    }
    if (data.containsKey('approved_plan_assistant_created_at')) {
      context.handle(
          _approvedPlanAssistantCreatedAtMeta,
          approvedPlanAssistantCreatedAt.isAcceptableOrUnknown(
              data['approved_plan_assistant_created_at']!,
              _approvedPlanAssistantCreatedAtMeta));
    }
    if (data.containsKey('approved_plan_approved_at')) {
      context.handle(
          _approvedPlanApprovedAtMeta,
          approvedPlanApprovedAt.isAcceptableOrUnknown(
              data['approved_plan_approved_at']!, _approvedPlanApprovedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AiChat map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AiChat(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      model: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}model'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
      planMode: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}plan_mode'])!,
      approvedPlanAssistantCreatedAt: attachedDatabase.typeMapping.read(
          DriftSqlType.int,
          data['${effectivePrefix}approved_plan_assistant_created_at']),
      approvedPlanApprovedAt: attachedDatabase.typeMapping.read(
          DriftSqlType.int,
          data['${effectivePrefix}approved_plan_approved_at']),
    );
  }

  @override
  $AiChatsTable createAlias(String alias) {
    return $AiChatsTable(attachedDatabase, alias);
  }
}

class AiChat extends DataClass implements Insertable<AiChat> {
  final String id;
  final String title;
  final String model;
  final int createdAt;
  final int updatedAt;
  final bool planMode;
  final int? approvedPlanAssistantCreatedAt;
  final int? approvedPlanApprovedAt;
  const AiChat(
      {required this.id,
      required this.title,
      required this.model,
      required this.createdAt,
      required this.updatedAt,
      required this.planMode,
      this.approvedPlanAssistantCreatedAt,
      this.approvedPlanApprovedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['model'] = Variable<String>(model);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    map['plan_mode'] = Variable<bool>(planMode);
    if (!nullToAbsent || approvedPlanAssistantCreatedAt != null) {
      map['approved_plan_assistant_created_at'] =
          Variable<int>(approvedPlanAssistantCreatedAt);
    }
    if (!nullToAbsent || approvedPlanApprovedAt != null) {
      map['approved_plan_approved_at'] = Variable<int>(approvedPlanApprovedAt);
    }
    return map;
  }

  AiChatsCompanion toCompanion(bool nullToAbsent) {
    return AiChatsCompanion(
      id: Value(id),
      title: Value(title),
      model: Value(model),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      planMode: Value(planMode),
      approvedPlanAssistantCreatedAt:
          approvedPlanAssistantCreatedAt == null && nullToAbsent
              ? const Value.absent()
              : Value(approvedPlanAssistantCreatedAt),
      approvedPlanApprovedAt: approvedPlanApprovedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(approvedPlanApprovedAt),
    );
  }

  factory AiChat.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AiChat(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      model: serializer.fromJson<String>(json['model']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      planMode: serializer.fromJson<bool>(json['planMode']),
      approvedPlanAssistantCreatedAt:
          serializer.fromJson<int?>(json['approvedPlanAssistantCreatedAt']),
      approvedPlanApprovedAt:
          serializer.fromJson<int?>(json['approvedPlanApprovedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'model': serializer.toJson<String>(model),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'planMode': serializer.toJson<bool>(planMode),
      'approvedPlanAssistantCreatedAt':
          serializer.toJson<int?>(approvedPlanAssistantCreatedAt),
      'approvedPlanApprovedAt': serializer.toJson<int?>(approvedPlanApprovedAt),
    };
  }

  AiChat copyWith(
          {String? id,
          String? title,
          String? model,
          int? createdAt,
          int? updatedAt,
          bool? planMode,
          Value<int?> approvedPlanAssistantCreatedAt = const Value.absent(),
          Value<int?> approvedPlanApprovedAt = const Value.absent()}) =>
      AiChat(
        id: id ?? this.id,
        title: title ?? this.title,
        model: model ?? this.model,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        planMode: planMode ?? this.planMode,
        approvedPlanAssistantCreatedAt: approvedPlanAssistantCreatedAt.present
            ? approvedPlanAssistantCreatedAt.value
            : this.approvedPlanAssistantCreatedAt,
        approvedPlanApprovedAt: approvedPlanApprovedAt.present
            ? approvedPlanApprovedAt.value
            : this.approvedPlanApprovedAt,
      );
  AiChat copyWithCompanion(AiChatsCompanion data) {
    return AiChat(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      model: data.model.present ? data.model.value : this.model,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      planMode: data.planMode.present ? data.planMode.value : this.planMode,
      approvedPlanAssistantCreatedAt:
          data.approvedPlanAssistantCreatedAt.present
              ? data.approvedPlanAssistantCreatedAt.value
              : this.approvedPlanAssistantCreatedAt,
      approvedPlanApprovedAt: data.approvedPlanApprovedAt.present
          ? data.approvedPlanApprovedAt.value
          : this.approvedPlanApprovedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AiChat(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('model: $model, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('planMode: $planMode, ')
          ..write(
              'approvedPlanAssistantCreatedAt: $approvedPlanAssistantCreatedAt, ')
          ..write('approvedPlanApprovedAt: $approvedPlanApprovedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, title, model, createdAt, updatedAt,
      planMode, approvedPlanAssistantCreatedAt, approvedPlanApprovedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AiChat &&
          other.id == this.id &&
          other.title == this.title &&
          other.model == this.model &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.planMode == this.planMode &&
          other.approvedPlanAssistantCreatedAt ==
              this.approvedPlanAssistantCreatedAt &&
          other.approvedPlanApprovedAt == this.approvedPlanApprovedAt);
}

class AiChatsCompanion extends UpdateCompanion<AiChat> {
  final Value<String> id;
  final Value<String> title;
  final Value<String> model;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<bool> planMode;
  final Value<int?> approvedPlanAssistantCreatedAt;
  final Value<int?> approvedPlanApprovedAt;
  final Value<int> rowid;
  const AiChatsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.model = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.planMode = const Value.absent(),
    this.approvedPlanAssistantCreatedAt = const Value.absent(),
    this.approvedPlanApprovedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AiChatsCompanion.insert({
    required String id,
    required String title,
    required String model,
    required int createdAt,
    required int updatedAt,
    this.planMode = const Value.absent(),
    this.approvedPlanAssistantCreatedAt = const Value.absent(),
    this.approvedPlanApprovedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        title = Value(title),
        model = Value(model),
        createdAt = Value(createdAt),
        updatedAt = Value(updatedAt);
  static Insertable<AiChat> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<String>? model,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<bool>? planMode,
    Expression<int>? approvedPlanAssistantCreatedAt,
    Expression<int>? approvedPlanApprovedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (model != null) 'model': model,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (planMode != null) 'plan_mode': planMode,
      if (approvedPlanAssistantCreatedAt != null)
        'approved_plan_assistant_created_at': approvedPlanAssistantCreatedAt,
      if (approvedPlanApprovedAt != null)
        'approved_plan_approved_at': approvedPlanApprovedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AiChatsCompanion copyWith(
      {Value<String>? id,
      Value<String>? title,
      Value<String>? model,
      Value<int>? createdAt,
      Value<int>? updatedAt,
      Value<bool>? planMode,
      Value<int?>? approvedPlanAssistantCreatedAt,
      Value<int?>? approvedPlanApprovedAt,
      Value<int>? rowid}) {
    return AiChatsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      model: model ?? this.model,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      planMode: planMode ?? this.planMode,
      approvedPlanAssistantCreatedAt:
          approvedPlanAssistantCreatedAt ?? this.approvedPlanAssistantCreatedAt,
      approvedPlanApprovedAt:
          approvedPlanApprovedAt ?? this.approvedPlanApprovedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (model.present) {
      map['model'] = Variable<String>(model.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (planMode.present) {
      map['plan_mode'] = Variable<bool>(planMode.value);
    }
    if (approvedPlanAssistantCreatedAt.present) {
      map['approved_plan_assistant_created_at'] =
          Variable<int>(approvedPlanAssistantCreatedAt.value);
    }
    if (approvedPlanApprovedAt.present) {
      map['approved_plan_approved_at'] =
          Variable<int>(approvedPlanApprovedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AiChatsCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('model: $model, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('planMode: $planMode, ')
          ..write(
              'approvedPlanAssistantCreatedAt: $approvedPlanAssistantCreatedAt, ')
          ..write('approvedPlanApprovedAt: $approvedPlanApprovedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AiChatMessagesTable extends AiChatMessages
    with TableInfo<$AiChatMessagesTable, AiChatMessage> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AiChatMessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _chatIdMeta = const VerificationMeta('chatId');
  @override
  late final GeneratedColumn<String> chatId = GeneratedColumn<String>(
      'chat_id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES ai_chats (id) ON DELETE CASCADE'));
  static const VerificationMeta _roleMeta = const VerificationMeta('role');
  @override
  late final GeneratedColumn<String> role = GeneratedColumn<String>(
      'role', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _textContentMeta =
      const VerificationMeta('textContent');
  @override
  late final GeneratedColumn<String> textContent = GeneratedColumn<String>(
      'text', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _contextTextMeta =
      const VerificationMeta('contextText');
  @override
  late final GeneratedColumn<String> contextText = GeneratedColumn<String>(
      'context_text', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _promptTokensMeta =
      const VerificationMeta('promptTokens');
  @override
  late final GeneratedColumn<int> promptTokens = GeneratedColumn<int>(
      'prompt_tokens', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _completionTokensMeta =
      const VerificationMeta('completionTokens');
  @override
  late final GeneratedColumn<int> completionTokens = GeneratedColumn<int>(
      'completion_tokens', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _totalTokensMeta =
      const VerificationMeta('totalTokens');
  @override
  late final GeneratedColumn<int> totalTokens = GeneratedColumn<int>(
      'total_tokens', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _elapsedMsMeta =
      const VerificationMeta('elapsedMs');
  @override
  late final GeneratedColumn<int> elapsedMs = GeneratedColumn<int>(
      'elapsed_ms', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _tokenUsageEstimatedMeta =
      const VerificationMeta('tokenUsageEstimated');
  @override
  late final GeneratedColumn<bool> tokenUsageEstimated = GeneratedColumn<bool>(
      'token_usage_estimated', aliasedName, true,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("token_usage_estimated" IN (0, 1))'));
  static const VerificationMeta _promptCacheHitTokensMeta =
      const VerificationMeta('promptCacheHitTokens');
  @override
  late final GeneratedColumn<int> promptCacheHitTokens = GeneratedColumn<int>(
      'prompt_cache_hit_tokens', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _promptCacheMissTokensMeta =
      const VerificationMeta('promptCacheMissTokens');
  @override
  late final GeneratedColumn<int> promptCacheMissTokens = GeneratedColumn<int>(
      'prompt_cache_miss_tokens', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _reasoningTokensMeta =
      const VerificationMeta('reasoningTokens');
  @override
  late final GeneratedColumn<int> reasoningTokens = GeneratedColumn<int>(
      'reasoning_tokens', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _attachmentsJsonMeta =
      const VerificationMeta('attachmentsJson');
  @override
  late final GeneratedColumn<String> attachmentsJson = GeneratedColumn<String>(
      'attachments_json', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('[]'));
  static const VerificationMeta _tracesJsonMeta =
      const VerificationMeta('tracesJson');
  @override
  late final GeneratedColumn<String> tracesJson = GeneratedColumn<String>(
      'traces_json', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('[]'));
  static const VerificationMeta _todoStepsJsonMeta =
      const VerificationMeta('todoStepsJson');
  @override
  late final GeneratedColumn<String> todoStepsJson = GeneratedColumn<String>(
      'todo_steps_json', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('[]'));
  @override
  List<GeneratedColumn> get $columns => [
        id,
        chatId,
        role,
        textContent,
        contextText,
        createdAt,
        promptTokens,
        completionTokens,
        totalTokens,
        elapsedMs,
        tokenUsageEstimated,
        promptCacheHitTokens,
        promptCacheMissTokens,
        reasoningTokens,
        attachmentsJson,
        tracesJson,
        todoStepsJson
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ai_chat_messages';
  @override
  VerificationContext validateIntegrity(Insertable<AiChatMessage> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('chat_id')) {
      context.handle(_chatIdMeta,
          chatId.isAcceptableOrUnknown(data['chat_id']!, _chatIdMeta));
    } else if (isInserting) {
      context.missing(_chatIdMeta);
    }
    if (data.containsKey('role')) {
      context.handle(
          _roleMeta, role.isAcceptableOrUnknown(data['role']!, _roleMeta));
    } else if (isInserting) {
      context.missing(_roleMeta);
    }
    if (data.containsKey('text')) {
      context.handle(_textContentMeta,
          textContent.isAcceptableOrUnknown(data['text']!, _textContentMeta));
    } else if (isInserting) {
      context.missing(_textContentMeta);
    }
    if (data.containsKey('context_text')) {
      context.handle(
          _contextTextMeta,
          contextText.isAcceptableOrUnknown(
              data['context_text']!, _contextTextMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('prompt_tokens')) {
      context.handle(
          _promptTokensMeta,
          promptTokens.isAcceptableOrUnknown(
              data['prompt_tokens']!, _promptTokensMeta));
    }
    if (data.containsKey('completion_tokens')) {
      context.handle(
          _completionTokensMeta,
          completionTokens.isAcceptableOrUnknown(
              data['completion_tokens']!, _completionTokensMeta));
    }
    if (data.containsKey('total_tokens')) {
      context.handle(
          _totalTokensMeta,
          totalTokens.isAcceptableOrUnknown(
              data['total_tokens']!, _totalTokensMeta));
    }
    if (data.containsKey('elapsed_ms')) {
      context.handle(_elapsedMsMeta,
          elapsedMs.isAcceptableOrUnknown(data['elapsed_ms']!, _elapsedMsMeta));
    }
    if (data.containsKey('token_usage_estimated')) {
      context.handle(
          _tokenUsageEstimatedMeta,
          tokenUsageEstimated.isAcceptableOrUnknown(
              data['token_usage_estimated']!, _tokenUsageEstimatedMeta));
    }
    if (data.containsKey('prompt_cache_hit_tokens')) {
      context.handle(
          _promptCacheHitTokensMeta,
          promptCacheHitTokens.isAcceptableOrUnknown(
              data['prompt_cache_hit_tokens']!, _promptCacheHitTokensMeta));
    }
    if (data.containsKey('prompt_cache_miss_tokens')) {
      context.handle(
          _promptCacheMissTokensMeta,
          promptCacheMissTokens.isAcceptableOrUnknown(
              data['prompt_cache_miss_tokens']!, _promptCacheMissTokensMeta));
    }
    if (data.containsKey('reasoning_tokens')) {
      context.handle(
          _reasoningTokensMeta,
          reasoningTokens.isAcceptableOrUnknown(
              data['reasoning_tokens']!, _reasoningTokensMeta));
    }
    if (data.containsKey('attachments_json')) {
      context.handle(
          _attachmentsJsonMeta,
          attachmentsJson.isAcceptableOrUnknown(
              data['attachments_json']!, _attachmentsJsonMeta));
    }
    if (data.containsKey('traces_json')) {
      context.handle(
          _tracesJsonMeta,
          tracesJson.isAcceptableOrUnknown(
              data['traces_json']!, _tracesJsonMeta));
    }
    if (data.containsKey('todo_steps_json')) {
      context.handle(
          _todoStepsJsonMeta,
          todoStepsJson.isAcceptableOrUnknown(
              data['todo_steps_json']!, _todoStepsJsonMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AiChatMessage map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AiChatMessage(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      chatId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}chat_id'])!,
      role: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}role'])!,
      textContent: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}text'])!,
      contextText: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}context_text']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
      promptTokens: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}prompt_tokens']),
      completionTokens: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}completion_tokens']),
      totalTokens: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}total_tokens']),
      elapsedMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}elapsed_ms']),
      tokenUsageEstimated: attachedDatabase.typeMapping.read(
          DriftSqlType.bool, data['${effectivePrefix}token_usage_estimated']),
      promptCacheHitTokens: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}prompt_cache_hit_tokens']),
      promptCacheMissTokens: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}prompt_cache_miss_tokens']),
      reasoningTokens: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}reasoning_tokens']),
      attachmentsJson: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}attachments_json'])!,
      tracesJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}traces_json'])!,
      todoStepsJson: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}todo_steps_json'])!,
    );
  }

  @override
  $AiChatMessagesTable createAlias(String alias) {
    return $AiChatMessagesTable(attachedDatabase, alias);
  }
}

class AiChatMessage extends DataClass implements Insertable<AiChatMessage> {
  final String id;
  final String chatId;
  final String role;
  final String textContent;
  final String? contextText;
  final int createdAt;
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
  final int? elapsedMs;
  final bool? tokenUsageEstimated;
  final int? promptCacheHitTokens;
  final int? promptCacheMissTokens;
  final int? reasoningTokens;
  final String attachmentsJson;
  final String tracesJson;
  final String todoStepsJson;
  const AiChatMessage(
      {required this.id,
      required this.chatId,
      required this.role,
      required this.textContent,
      this.contextText,
      required this.createdAt,
      this.promptTokens,
      this.completionTokens,
      this.totalTokens,
      this.elapsedMs,
      this.tokenUsageEstimated,
      this.promptCacheHitTokens,
      this.promptCacheMissTokens,
      this.reasoningTokens,
      required this.attachmentsJson,
      required this.tracesJson,
      required this.todoStepsJson});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['chat_id'] = Variable<String>(chatId);
    map['role'] = Variable<String>(role);
    map['text'] = Variable<String>(textContent);
    if (!nullToAbsent || contextText != null) {
      map['context_text'] = Variable<String>(contextText);
    }
    map['created_at'] = Variable<int>(createdAt);
    if (!nullToAbsent || promptTokens != null) {
      map['prompt_tokens'] = Variable<int>(promptTokens);
    }
    if (!nullToAbsent || completionTokens != null) {
      map['completion_tokens'] = Variable<int>(completionTokens);
    }
    if (!nullToAbsent || totalTokens != null) {
      map['total_tokens'] = Variable<int>(totalTokens);
    }
    if (!nullToAbsent || elapsedMs != null) {
      map['elapsed_ms'] = Variable<int>(elapsedMs);
    }
    if (!nullToAbsent || tokenUsageEstimated != null) {
      map['token_usage_estimated'] = Variable<bool>(tokenUsageEstimated);
    }
    if (!nullToAbsent || promptCacheHitTokens != null) {
      map['prompt_cache_hit_tokens'] = Variable<int>(promptCacheHitTokens);
    }
    if (!nullToAbsent || promptCacheMissTokens != null) {
      map['prompt_cache_miss_tokens'] = Variable<int>(promptCacheMissTokens);
    }
    if (!nullToAbsent || reasoningTokens != null) {
      map['reasoning_tokens'] = Variable<int>(reasoningTokens);
    }
    map['attachments_json'] = Variable<String>(attachmentsJson);
    map['traces_json'] = Variable<String>(tracesJson);
    map['todo_steps_json'] = Variable<String>(todoStepsJson);
    return map;
  }

  AiChatMessagesCompanion toCompanion(bool nullToAbsent) {
    return AiChatMessagesCompanion(
      id: Value(id),
      chatId: Value(chatId),
      role: Value(role),
      textContent: Value(textContent),
      contextText: contextText == null && nullToAbsent
          ? const Value.absent()
          : Value(contextText),
      createdAt: Value(createdAt),
      promptTokens: promptTokens == null && nullToAbsent
          ? const Value.absent()
          : Value(promptTokens),
      completionTokens: completionTokens == null && nullToAbsent
          ? const Value.absent()
          : Value(completionTokens),
      totalTokens: totalTokens == null && nullToAbsent
          ? const Value.absent()
          : Value(totalTokens),
      elapsedMs: elapsedMs == null && nullToAbsent
          ? const Value.absent()
          : Value(elapsedMs),
      tokenUsageEstimated: tokenUsageEstimated == null && nullToAbsent
          ? const Value.absent()
          : Value(tokenUsageEstimated),
      promptCacheHitTokens: promptCacheHitTokens == null && nullToAbsent
          ? const Value.absent()
          : Value(promptCacheHitTokens),
      promptCacheMissTokens: promptCacheMissTokens == null && nullToAbsent
          ? const Value.absent()
          : Value(promptCacheMissTokens),
      reasoningTokens: reasoningTokens == null && nullToAbsent
          ? const Value.absent()
          : Value(reasoningTokens),
      attachmentsJson: Value(attachmentsJson),
      tracesJson: Value(tracesJson),
      todoStepsJson: Value(todoStepsJson),
    );
  }

  factory AiChatMessage.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AiChatMessage(
      id: serializer.fromJson<String>(json['id']),
      chatId: serializer.fromJson<String>(json['chatId']),
      role: serializer.fromJson<String>(json['role']),
      textContent: serializer.fromJson<String>(json['textContent']),
      contextText: serializer.fromJson<String?>(json['contextText']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      promptTokens: serializer.fromJson<int?>(json['promptTokens']),
      completionTokens: serializer.fromJson<int?>(json['completionTokens']),
      totalTokens: serializer.fromJson<int?>(json['totalTokens']),
      elapsedMs: serializer.fromJson<int?>(json['elapsedMs']),
      tokenUsageEstimated:
          serializer.fromJson<bool?>(json['tokenUsageEstimated']),
      promptCacheHitTokens:
          serializer.fromJson<int?>(json['promptCacheHitTokens']),
      promptCacheMissTokens:
          serializer.fromJson<int?>(json['promptCacheMissTokens']),
      reasoningTokens: serializer.fromJson<int?>(json['reasoningTokens']),
      attachmentsJson: serializer.fromJson<String>(json['attachmentsJson']),
      tracesJson: serializer.fromJson<String>(json['tracesJson']),
      todoStepsJson: serializer.fromJson<String>(json['todoStepsJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'chatId': serializer.toJson<String>(chatId),
      'role': serializer.toJson<String>(role),
      'textContent': serializer.toJson<String>(textContent),
      'contextText': serializer.toJson<String?>(contextText),
      'createdAt': serializer.toJson<int>(createdAt),
      'promptTokens': serializer.toJson<int?>(promptTokens),
      'completionTokens': serializer.toJson<int?>(completionTokens),
      'totalTokens': serializer.toJson<int?>(totalTokens),
      'elapsedMs': serializer.toJson<int?>(elapsedMs),
      'tokenUsageEstimated': serializer.toJson<bool?>(tokenUsageEstimated),
      'promptCacheHitTokens': serializer.toJson<int?>(promptCacheHitTokens),
      'promptCacheMissTokens': serializer.toJson<int?>(promptCacheMissTokens),
      'reasoningTokens': serializer.toJson<int?>(reasoningTokens),
      'attachmentsJson': serializer.toJson<String>(attachmentsJson),
      'tracesJson': serializer.toJson<String>(tracesJson),
      'todoStepsJson': serializer.toJson<String>(todoStepsJson),
    };
  }

  AiChatMessage copyWith(
          {String? id,
          String? chatId,
          String? role,
          String? textContent,
          Value<String?> contextText = const Value.absent(),
          int? createdAt,
          Value<int?> promptTokens = const Value.absent(),
          Value<int?> completionTokens = const Value.absent(),
          Value<int?> totalTokens = const Value.absent(),
          Value<int?> elapsedMs = const Value.absent(),
          Value<bool?> tokenUsageEstimated = const Value.absent(),
          Value<int?> promptCacheHitTokens = const Value.absent(),
          Value<int?> promptCacheMissTokens = const Value.absent(),
          Value<int?> reasoningTokens = const Value.absent(),
          String? attachmentsJson,
          String? tracesJson,
          String? todoStepsJson}) =>
      AiChatMessage(
        id: id ?? this.id,
        chatId: chatId ?? this.chatId,
        role: role ?? this.role,
        textContent: textContent ?? this.textContent,
        contextText: contextText.present ? contextText.value : this.contextText,
        createdAt: createdAt ?? this.createdAt,
        promptTokens:
            promptTokens.present ? promptTokens.value : this.promptTokens,
        completionTokens: completionTokens.present
            ? completionTokens.value
            : this.completionTokens,
        totalTokens: totalTokens.present ? totalTokens.value : this.totalTokens,
        elapsedMs: elapsedMs.present ? elapsedMs.value : this.elapsedMs,
        tokenUsageEstimated: tokenUsageEstimated.present
            ? tokenUsageEstimated.value
            : this.tokenUsageEstimated,
        promptCacheHitTokens: promptCacheHitTokens.present
            ? promptCacheHitTokens.value
            : this.promptCacheHitTokens,
        promptCacheMissTokens: promptCacheMissTokens.present
            ? promptCacheMissTokens.value
            : this.promptCacheMissTokens,
        reasoningTokens: reasoningTokens.present
            ? reasoningTokens.value
            : this.reasoningTokens,
        attachmentsJson: attachmentsJson ?? this.attachmentsJson,
        tracesJson: tracesJson ?? this.tracesJson,
        todoStepsJson: todoStepsJson ?? this.todoStepsJson,
      );
  AiChatMessage copyWithCompanion(AiChatMessagesCompanion data) {
    return AiChatMessage(
      id: data.id.present ? data.id.value : this.id,
      chatId: data.chatId.present ? data.chatId.value : this.chatId,
      role: data.role.present ? data.role.value : this.role,
      textContent:
          data.textContent.present ? data.textContent.value : this.textContent,
      contextText:
          data.contextText.present ? data.contextText.value : this.contextText,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      promptTokens: data.promptTokens.present
          ? data.promptTokens.value
          : this.promptTokens,
      completionTokens: data.completionTokens.present
          ? data.completionTokens.value
          : this.completionTokens,
      totalTokens:
          data.totalTokens.present ? data.totalTokens.value : this.totalTokens,
      elapsedMs: data.elapsedMs.present ? data.elapsedMs.value : this.elapsedMs,
      tokenUsageEstimated: data.tokenUsageEstimated.present
          ? data.tokenUsageEstimated.value
          : this.tokenUsageEstimated,
      promptCacheHitTokens: data.promptCacheHitTokens.present
          ? data.promptCacheHitTokens.value
          : this.promptCacheHitTokens,
      promptCacheMissTokens: data.promptCacheMissTokens.present
          ? data.promptCacheMissTokens.value
          : this.promptCacheMissTokens,
      reasoningTokens: data.reasoningTokens.present
          ? data.reasoningTokens.value
          : this.reasoningTokens,
      attachmentsJson: data.attachmentsJson.present
          ? data.attachmentsJson.value
          : this.attachmentsJson,
      tracesJson:
          data.tracesJson.present ? data.tracesJson.value : this.tracesJson,
      todoStepsJson: data.todoStepsJson.present
          ? data.todoStepsJson.value
          : this.todoStepsJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AiChatMessage(')
          ..write('id: $id, ')
          ..write('chatId: $chatId, ')
          ..write('role: $role, ')
          ..write('textContent: $textContent, ')
          ..write('contextText: $contextText, ')
          ..write('createdAt: $createdAt, ')
          ..write('promptTokens: $promptTokens, ')
          ..write('completionTokens: $completionTokens, ')
          ..write('totalTokens: $totalTokens, ')
          ..write('elapsedMs: $elapsedMs, ')
          ..write('tokenUsageEstimated: $tokenUsageEstimated, ')
          ..write('promptCacheHitTokens: $promptCacheHitTokens, ')
          ..write('promptCacheMissTokens: $promptCacheMissTokens, ')
          ..write('reasoningTokens: $reasoningTokens, ')
          ..write('attachmentsJson: $attachmentsJson, ')
          ..write('tracesJson: $tracesJson, ')
          ..write('todoStepsJson: $todoStepsJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      chatId,
      role,
      textContent,
      contextText,
      createdAt,
      promptTokens,
      completionTokens,
      totalTokens,
      elapsedMs,
      tokenUsageEstimated,
      promptCacheHitTokens,
      promptCacheMissTokens,
      reasoningTokens,
      attachmentsJson,
      tracesJson,
      todoStepsJson);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AiChatMessage &&
          other.id == this.id &&
          other.chatId == this.chatId &&
          other.role == this.role &&
          other.textContent == this.textContent &&
          other.contextText == this.contextText &&
          other.createdAt == this.createdAt &&
          other.promptTokens == this.promptTokens &&
          other.completionTokens == this.completionTokens &&
          other.totalTokens == this.totalTokens &&
          other.elapsedMs == this.elapsedMs &&
          other.tokenUsageEstimated == this.tokenUsageEstimated &&
          other.promptCacheHitTokens == this.promptCacheHitTokens &&
          other.promptCacheMissTokens == this.promptCacheMissTokens &&
          other.reasoningTokens == this.reasoningTokens &&
          other.attachmentsJson == this.attachmentsJson &&
          other.tracesJson == this.tracesJson &&
          other.todoStepsJson == this.todoStepsJson);
}

class AiChatMessagesCompanion extends UpdateCompanion<AiChatMessage> {
  final Value<String> id;
  final Value<String> chatId;
  final Value<String> role;
  final Value<String> textContent;
  final Value<String?> contextText;
  final Value<int> createdAt;
  final Value<int?> promptTokens;
  final Value<int?> completionTokens;
  final Value<int?> totalTokens;
  final Value<int?> elapsedMs;
  final Value<bool?> tokenUsageEstimated;
  final Value<int?> promptCacheHitTokens;
  final Value<int?> promptCacheMissTokens;
  final Value<int?> reasoningTokens;
  final Value<String> attachmentsJson;
  final Value<String> tracesJson;
  final Value<String> todoStepsJson;
  final Value<int> rowid;
  const AiChatMessagesCompanion({
    this.id = const Value.absent(),
    this.chatId = const Value.absent(),
    this.role = const Value.absent(),
    this.textContent = const Value.absent(),
    this.contextText = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.promptTokens = const Value.absent(),
    this.completionTokens = const Value.absent(),
    this.totalTokens = const Value.absent(),
    this.elapsedMs = const Value.absent(),
    this.tokenUsageEstimated = const Value.absent(),
    this.promptCacheHitTokens = const Value.absent(),
    this.promptCacheMissTokens = const Value.absent(),
    this.reasoningTokens = const Value.absent(),
    this.attachmentsJson = const Value.absent(),
    this.tracesJson = const Value.absent(),
    this.todoStepsJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AiChatMessagesCompanion.insert({
    required String id,
    required String chatId,
    required String role,
    required String textContent,
    this.contextText = const Value.absent(),
    required int createdAt,
    this.promptTokens = const Value.absent(),
    this.completionTokens = const Value.absent(),
    this.totalTokens = const Value.absent(),
    this.elapsedMs = const Value.absent(),
    this.tokenUsageEstimated = const Value.absent(),
    this.promptCacheHitTokens = const Value.absent(),
    this.promptCacheMissTokens = const Value.absent(),
    this.reasoningTokens = const Value.absent(),
    this.attachmentsJson = const Value.absent(),
    this.tracesJson = const Value.absent(),
    this.todoStepsJson = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        chatId = Value(chatId),
        role = Value(role),
        textContent = Value(textContent),
        createdAt = Value(createdAt);
  static Insertable<AiChatMessage> custom({
    Expression<String>? id,
    Expression<String>? chatId,
    Expression<String>? role,
    Expression<String>? textContent,
    Expression<String>? contextText,
    Expression<int>? createdAt,
    Expression<int>? promptTokens,
    Expression<int>? completionTokens,
    Expression<int>? totalTokens,
    Expression<int>? elapsedMs,
    Expression<bool>? tokenUsageEstimated,
    Expression<int>? promptCacheHitTokens,
    Expression<int>? promptCacheMissTokens,
    Expression<int>? reasoningTokens,
    Expression<String>? attachmentsJson,
    Expression<String>? tracesJson,
    Expression<String>? todoStepsJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (chatId != null) 'chat_id': chatId,
      if (role != null) 'role': role,
      if (textContent != null) 'text': textContent,
      if (contextText != null) 'context_text': contextText,
      if (createdAt != null) 'created_at': createdAt,
      if (promptTokens != null) 'prompt_tokens': promptTokens,
      if (completionTokens != null) 'completion_tokens': completionTokens,
      if (totalTokens != null) 'total_tokens': totalTokens,
      if (elapsedMs != null) 'elapsed_ms': elapsedMs,
      if (tokenUsageEstimated != null)
        'token_usage_estimated': tokenUsageEstimated,
      if (promptCacheHitTokens != null)
        'prompt_cache_hit_tokens': promptCacheHitTokens,
      if (promptCacheMissTokens != null)
        'prompt_cache_miss_tokens': promptCacheMissTokens,
      if (reasoningTokens != null) 'reasoning_tokens': reasoningTokens,
      if (attachmentsJson != null) 'attachments_json': attachmentsJson,
      if (tracesJson != null) 'traces_json': tracesJson,
      if (todoStepsJson != null) 'todo_steps_json': todoStepsJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AiChatMessagesCompanion copyWith(
      {Value<String>? id,
      Value<String>? chatId,
      Value<String>? role,
      Value<String>? textContent,
      Value<String?>? contextText,
      Value<int>? createdAt,
      Value<int?>? promptTokens,
      Value<int?>? completionTokens,
      Value<int?>? totalTokens,
      Value<int?>? elapsedMs,
      Value<bool?>? tokenUsageEstimated,
      Value<int?>? promptCacheHitTokens,
      Value<int?>? promptCacheMissTokens,
      Value<int?>? reasoningTokens,
      Value<String>? attachmentsJson,
      Value<String>? tracesJson,
      Value<String>? todoStepsJson,
      Value<int>? rowid}) {
    return AiChatMessagesCompanion(
      id: id ?? this.id,
      chatId: chatId ?? this.chatId,
      role: role ?? this.role,
      textContent: textContent ?? this.textContent,
      contextText: contextText ?? this.contextText,
      createdAt: createdAt ?? this.createdAt,
      promptTokens: promptTokens ?? this.promptTokens,
      completionTokens: completionTokens ?? this.completionTokens,
      totalTokens: totalTokens ?? this.totalTokens,
      elapsedMs: elapsedMs ?? this.elapsedMs,
      tokenUsageEstimated: tokenUsageEstimated ?? this.tokenUsageEstimated,
      promptCacheHitTokens: promptCacheHitTokens ?? this.promptCacheHitTokens,
      promptCacheMissTokens:
          promptCacheMissTokens ?? this.promptCacheMissTokens,
      reasoningTokens: reasoningTokens ?? this.reasoningTokens,
      attachmentsJson: attachmentsJson ?? this.attachmentsJson,
      tracesJson: tracesJson ?? this.tracesJson,
      todoStepsJson: todoStepsJson ?? this.todoStepsJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (chatId.present) {
      map['chat_id'] = Variable<String>(chatId.value);
    }
    if (role.present) {
      map['role'] = Variable<String>(role.value);
    }
    if (textContent.present) {
      map['text'] = Variable<String>(textContent.value);
    }
    if (contextText.present) {
      map['context_text'] = Variable<String>(contextText.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (promptTokens.present) {
      map['prompt_tokens'] = Variable<int>(promptTokens.value);
    }
    if (completionTokens.present) {
      map['completion_tokens'] = Variable<int>(completionTokens.value);
    }
    if (totalTokens.present) {
      map['total_tokens'] = Variable<int>(totalTokens.value);
    }
    if (elapsedMs.present) {
      map['elapsed_ms'] = Variable<int>(elapsedMs.value);
    }
    if (tokenUsageEstimated.present) {
      map['token_usage_estimated'] = Variable<bool>(tokenUsageEstimated.value);
    }
    if (promptCacheHitTokens.present) {
      map['prompt_cache_hit_tokens'] =
          Variable<int>(promptCacheHitTokens.value);
    }
    if (promptCacheMissTokens.present) {
      map['prompt_cache_miss_tokens'] =
          Variable<int>(promptCacheMissTokens.value);
    }
    if (reasoningTokens.present) {
      map['reasoning_tokens'] = Variable<int>(reasoningTokens.value);
    }
    if (attachmentsJson.present) {
      map['attachments_json'] = Variable<String>(attachmentsJson.value);
    }
    if (tracesJson.present) {
      map['traces_json'] = Variable<String>(tracesJson.value);
    }
    if (todoStepsJson.present) {
      map['todo_steps_json'] = Variable<String>(todoStepsJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AiChatMessagesCompanion(')
          ..write('id: $id, ')
          ..write('chatId: $chatId, ')
          ..write('role: $role, ')
          ..write('textContent: $textContent, ')
          ..write('contextText: $contextText, ')
          ..write('createdAt: $createdAt, ')
          ..write('promptTokens: $promptTokens, ')
          ..write('completionTokens: $completionTokens, ')
          ..write('totalTokens: $totalTokens, ')
          ..write('elapsedMs: $elapsedMs, ')
          ..write('tokenUsageEstimated: $tokenUsageEstimated, ')
          ..write('promptCacheHitTokens: $promptCacheHitTokens, ')
          ..write('promptCacheMissTokens: $promptCacheMissTokens, ')
          ..write('reasoningTokens: $reasoningTokens, ')
          ..write('attachmentsJson: $attachmentsJson, ')
          ..write('tracesJson: $tracesJson, ')
          ..write('todoStepsJson: $todoStepsJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AgentRunMetricsTableTable extends AgentRunMetricsTable
    with TableInfo<$AgentRunMetricsTableTable, AgentRunMetricRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AgentRunMetricsTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _startedAtMeta =
      const VerificationMeta('startedAt');
  @override
  late final GeneratedColumn<int> startedAt = GeneratedColumn<int>(
      'started_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _finishedAtMeta =
      const VerificationMeta('finishedAt');
  @override
  late final GeneratedColumn<int> finishedAt = GeneratedColumn<int>(
      'finished_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _modelMeta = const VerificationMeta('model');
  @override
  late final GeneratedColumn<String> model = GeneratedColumn<String>(
      'model', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _helperModelMeta =
      const VerificationMeta('helperModel');
  @override
  late final GeneratedColumn<String> helperModel = GeneratedColumn<String>(
      'helper_model', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _auditModelMeta =
      const VerificationMeta('auditModel');
  @override
  late final GeneratedColumn<String> auditModel = GeneratedColumn<String>(
      'audit_model', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _promptTokensMeta =
      const VerificationMeta('promptTokens');
  @override
  late final GeneratedColumn<int> promptTokens = GeneratedColumn<int>(
      'prompt_tokens', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _completionTokensMeta =
      const VerificationMeta('completionTokens');
  @override
  late final GeneratedColumn<int> completionTokens = GeneratedColumn<int>(
      'completion_tokens', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _totalTokensMeta =
      const VerificationMeta('totalTokens');
  @override
  late final GeneratedColumn<int> totalTokens = GeneratedColumn<int>(
      'total_tokens', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _elapsedMsMeta =
      const VerificationMeta('elapsedMs');
  @override
  late final GeneratedColumn<int> elapsedMs = GeneratedColumn<int>(
      'elapsed_ms', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _toolCallsMeta =
      const VerificationMeta('toolCalls');
  @override
  late final GeneratedColumn<int> toolCalls = GeneratedColumn<int>(
      'tool_calls', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _cacheHitsMeta =
      const VerificationMeta('cacheHits');
  @override
  late final GeneratedColumn<int> cacheHits = GeneratedColumn<int>(
      'cache_hits', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _dedupBlockedCallsMeta =
      const VerificationMeta('dedupBlockedCalls');
  @override
  late final GeneratedColumn<int> dedupBlockedCalls = GeneratedColumn<int>(
      'dedup_blocked_calls', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _ragHitsMeta =
      const VerificationMeta('ragHits');
  @override
  late final GeneratedColumn<int> ragHits = GeneratedColumn<int>(
      'rag_hits', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _approvalCountMeta =
      const VerificationMeta('approvalCount');
  @override
  late final GeneratedColumn<int> approvalCount = GeneratedColumn<int>(
      'approval_count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _approvedCountMeta =
      const VerificationMeta('approvedCount');
  @override
  late final GeneratedColumn<int> approvedCount = GeneratedColumn<int>(
      'approved_count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _auditCountMeta =
      const VerificationMeta('auditCount');
  @override
  late final GeneratedColumn<int> auditCount = GeneratedColumn<int>(
      'audit_count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _helperFanoutMeta =
      const VerificationMeta('helperFanout');
  @override
  late final GeneratedColumn<int> helperFanout = GeneratedColumn<int>(
      'helper_fanout', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _successMeta =
      const VerificationMeta('success');
  @override
  late final GeneratedColumn<bool> success = GeneratedColumn<bool>(
      'success', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("success" IN (0, 1))'),
      defaultValue: const Constant(true));
  static const VerificationMeta _selectedToolSetJsonMeta =
      const VerificationMeta('selectedToolSetJson');
  @override
  late final GeneratedColumn<String> selectedToolSetJson =
      GeneratedColumn<String>('selected_tool_set_json', aliasedName, false,
          type: DriftSqlType.string,
          requiredDuringInsert: false,
          defaultValue: const Constant('[]'));
  static const VerificationMeta _memorySourcesJsonMeta =
      const VerificationMeta('memorySourcesJson');
  @override
  late final GeneratedColumn<String> memorySourcesJson =
      GeneratedColumn<String>('memory_sources_json', aliasedName, false,
          type: DriftSqlType.string,
          requiredDuringInsert: false,
          defaultValue: const Constant('[]'));
  @override
  List<GeneratedColumn> get $columns => [
        id,
        startedAt,
        finishedAt,
        model,
        helperModel,
        auditModel,
        promptTokens,
        completionTokens,
        totalTokens,
        elapsedMs,
        toolCalls,
        cacheHits,
        dedupBlockedCalls,
        ragHits,
        approvalCount,
        approvedCount,
        auditCount,
        helperFanout,
        success,
        selectedToolSetJson,
        memorySourcesJson
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'agent_run_metrics';
  @override
  VerificationContext validateIntegrity(Insertable<AgentRunMetricRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('started_at')) {
      context.handle(_startedAtMeta,
          startedAt.isAcceptableOrUnknown(data['started_at']!, _startedAtMeta));
    } else if (isInserting) {
      context.missing(_startedAtMeta);
    }
    if (data.containsKey('finished_at')) {
      context.handle(
          _finishedAtMeta,
          finishedAt.isAcceptableOrUnknown(
              data['finished_at']!, _finishedAtMeta));
    } else if (isInserting) {
      context.missing(_finishedAtMeta);
    }
    if (data.containsKey('model')) {
      context.handle(
          _modelMeta, model.isAcceptableOrUnknown(data['model']!, _modelMeta));
    } else if (isInserting) {
      context.missing(_modelMeta);
    }
    if (data.containsKey('helper_model')) {
      context.handle(
          _helperModelMeta,
          helperModel.isAcceptableOrUnknown(
              data['helper_model']!, _helperModelMeta));
    }
    if (data.containsKey('audit_model')) {
      context.handle(
          _auditModelMeta,
          auditModel.isAcceptableOrUnknown(
              data['audit_model']!, _auditModelMeta));
    }
    if (data.containsKey('prompt_tokens')) {
      context.handle(
          _promptTokensMeta,
          promptTokens.isAcceptableOrUnknown(
              data['prompt_tokens']!, _promptTokensMeta));
    }
    if (data.containsKey('completion_tokens')) {
      context.handle(
          _completionTokensMeta,
          completionTokens.isAcceptableOrUnknown(
              data['completion_tokens']!, _completionTokensMeta));
    }
    if (data.containsKey('total_tokens')) {
      context.handle(
          _totalTokensMeta,
          totalTokens.isAcceptableOrUnknown(
              data['total_tokens']!, _totalTokensMeta));
    }
    if (data.containsKey('elapsed_ms')) {
      context.handle(_elapsedMsMeta,
          elapsedMs.isAcceptableOrUnknown(data['elapsed_ms']!, _elapsedMsMeta));
    }
    if (data.containsKey('tool_calls')) {
      context.handle(_toolCallsMeta,
          toolCalls.isAcceptableOrUnknown(data['tool_calls']!, _toolCallsMeta));
    }
    if (data.containsKey('cache_hits')) {
      context.handle(_cacheHitsMeta,
          cacheHits.isAcceptableOrUnknown(data['cache_hits']!, _cacheHitsMeta));
    }
    if (data.containsKey('dedup_blocked_calls')) {
      context.handle(
          _dedupBlockedCallsMeta,
          dedupBlockedCalls.isAcceptableOrUnknown(
              data['dedup_blocked_calls']!, _dedupBlockedCallsMeta));
    }
    if (data.containsKey('rag_hits')) {
      context.handle(_ragHitsMeta,
          ragHits.isAcceptableOrUnknown(data['rag_hits']!, _ragHitsMeta));
    }
    if (data.containsKey('approval_count')) {
      context.handle(
          _approvalCountMeta,
          approvalCount.isAcceptableOrUnknown(
              data['approval_count']!, _approvalCountMeta));
    }
    if (data.containsKey('approved_count')) {
      context.handle(
          _approvedCountMeta,
          approvedCount.isAcceptableOrUnknown(
              data['approved_count']!, _approvedCountMeta));
    }
    if (data.containsKey('audit_count')) {
      context.handle(
          _auditCountMeta,
          auditCount.isAcceptableOrUnknown(
              data['audit_count']!, _auditCountMeta));
    }
    if (data.containsKey('helper_fanout')) {
      context.handle(
          _helperFanoutMeta,
          helperFanout.isAcceptableOrUnknown(
              data['helper_fanout']!, _helperFanoutMeta));
    }
    if (data.containsKey('success')) {
      context.handle(_successMeta,
          success.isAcceptableOrUnknown(data['success']!, _successMeta));
    }
    if (data.containsKey('selected_tool_set_json')) {
      context.handle(
          _selectedToolSetJsonMeta,
          selectedToolSetJson.isAcceptableOrUnknown(
              data['selected_tool_set_json']!, _selectedToolSetJsonMeta));
    }
    if (data.containsKey('memory_sources_json')) {
      context.handle(
          _memorySourcesJsonMeta,
          memorySourcesJson.isAcceptableOrUnknown(
              data['memory_sources_json']!, _memorySourcesJsonMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AgentRunMetricRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AgentRunMetricRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      startedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}started_at'])!,
      finishedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}finished_at'])!,
      model: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}model'])!,
      helperModel: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}helper_model'])!,
      auditModel: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}audit_model'])!,
      promptTokens: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}prompt_tokens'])!,
      completionTokens: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}completion_tokens'])!,
      totalTokens: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}total_tokens'])!,
      elapsedMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}elapsed_ms'])!,
      toolCalls: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}tool_calls'])!,
      cacheHits: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}cache_hits'])!,
      dedupBlockedCalls: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}dedup_blocked_calls'])!,
      ragHits: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}rag_hits'])!,
      approvalCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}approval_count'])!,
      approvedCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}approved_count'])!,
      auditCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}audit_count'])!,
      helperFanout: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}helper_fanout'])!,
      success: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}success'])!,
      selectedToolSetJson: attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}selected_tool_set_json'])!,
      memorySourcesJson: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}memory_sources_json'])!,
    );
  }

  @override
  $AgentRunMetricsTableTable createAlias(String alias) {
    return $AgentRunMetricsTableTable(attachedDatabase, alias);
  }
}

class AgentRunMetricRow extends DataClass
    implements Insertable<AgentRunMetricRow> {
  final String id;
  final int startedAt;
  final int finishedAt;
  final String model;
  final String helperModel;
  final String auditModel;
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final int elapsedMs;
  final int toolCalls;
  final int cacheHits;
  final int dedupBlockedCalls;
  final int ragHits;
  final int approvalCount;
  final int approvedCount;
  final int auditCount;
  final int helperFanout;
  final bool success;
  final String selectedToolSetJson;
  final String memorySourcesJson;
  const AgentRunMetricRow(
      {required this.id,
      required this.startedAt,
      required this.finishedAt,
      required this.model,
      required this.helperModel,
      required this.auditModel,
      required this.promptTokens,
      required this.completionTokens,
      required this.totalTokens,
      required this.elapsedMs,
      required this.toolCalls,
      required this.cacheHits,
      required this.dedupBlockedCalls,
      required this.ragHits,
      required this.approvalCount,
      required this.approvedCount,
      required this.auditCount,
      required this.helperFanout,
      required this.success,
      required this.selectedToolSetJson,
      required this.memorySourcesJson});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['started_at'] = Variable<int>(startedAt);
    map['finished_at'] = Variable<int>(finishedAt);
    map['model'] = Variable<String>(model);
    map['helper_model'] = Variable<String>(helperModel);
    map['audit_model'] = Variable<String>(auditModel);
    map['prompt_tokens'] = Variable<int>(promptTokens);
    map['completion_tokens'] = Variable<int>(completionTokens);
    map['total_tokens'] = Variable<int>(totalTokens);
    map['elapsed_ms'] = Variable<int>(elapsedMs);
    map['tool_calls'] = Variable<int>(toolCalls);
    map['cache_hits'] = Variable<int>(cacheHits);
    map['dedup_blocked_calls'] = Variable<int>(dedupBlockedCalls);
    map['rag_hits'] = Variable<int>(ragHits);
    map['approval_count'] = Variable<int>(approvalCount);
    map['approved_count'] = Variable<int>(approvedCount);
    map['audit_count'] = Variable<int>(auditCount);
    map['helper_fanout'] = Variable<int>(helperFanout);
    map['success'] = Variable<bool>(success);
    map['selected_tool_set_json'] = Variable<String>(selectedToolSetJson);
    map['memory_sources_json'] = Variable<String>(memorySourcesJson);
    return map;
  }

  AgentRunMetricsTableCompanion toCompanion(bool nullToAbsent) {
    return AgentRunMetricsTableCompanion(
      id: Value(id),
      startedAt: Value(startedAt),
      finishedAt: Value(finishedAt),
      model: Value(model),
      helperModel: Value(helperModel),
      auditModel: Value(auditModel),
      promptTokens: Value(promptTokens),
      completionTokens: Value(completionTokens),
      totalTokens: Value(totalTokens),
      elapsedMs: Value(elapsedMs),
      toolCalls: Value(toolCalls),
      cacheHits: Value(cacheHits),
      dedupBlockedCalls: Value(dedupBlockedCalls),
      ragHits: Value(ragHits),
      approvalCount: Value(approvalCount),
      approvedCount: Value(approvedCount),
      auditCount: Value(auditCount),
      helperFanout: Value(helperFanout),
      success: Value(success),
      selectedToolSetJson: Value(selectedToolSetJson),
      memorySourcesJson: Value(memorySourcesJson),
    );
  }

  factory AgentRunMetricRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AgentRunMetricRow(
      id: serializer.fromJson<String>(json['id']),
      startedAt: serializer.fromJson<int>(json['startedAt']),
      finishedAt: serializer.fromJson<int>(json['finishedAt']),
      model: serializer.fromJson<String>(json['model']),
      helperModel: serializer.fromJson<String>(json['helperModel']),
      auditModel: serializer.fromJson<String>(json['auditModel']),
      promptTokens: serializer.fromJson<int>(json['promptTokens']),
      completionTokens: serializer.fromJson<int>(json['completionTokens']),
      totalTokens: serializer.fromJson<int>(json['totalTokens']),
      elapsedMs: serializer.fromJson<int>(json['elapsedMs']),
      toolCalls: serializer.fromJson<int>(json['toolCalls']),
      cacheHits: serializer.fromJson<int>(json['cacheHits']),
      dedupBlockedCalls: serializer.fromJson<int>(json['dedupBlockedCalls']),
      ragHits: serializer.fromJson<int>(json['ragHits']),
      approvalCount: serializer.fromJson<int>(json['approvalCount']),
      approvedCount: serializer.fromJson<int>(json['approvedCount']),
      auditCount: serializer.fromJson<int>(json['auditCount']),
      helperFanout: serializer.fromJson<int>(json['helperFanout']),
      success: serializer.fromJson<bool>(json['success']),
      selectedToolSetJson:
          serializer.fromJson<String>(json['selectedToolSetJson']),
      memorySourcesJson: serializer.fromJson<String>(json['memorySourcesJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'startedAt': serializer.toJson<int>(startedAt),
      'finishedAt': serializer.toJson<int>(finishedAt),
      'model': serializer.toJson<String>(model),
      'helperModel': serializer.toJson<String>(helperModel),
      'auditModel': serializer.toJson<String>(auditModel),
      'promptTokens': serializer.toJson<int>(promptTokens),
      'completionTokens': serializer.toJson<int>(completionTokens),
      'totalTokens': serializer.toJson<int>(totalTokens),
      'elapsedMs': serializer.toJson<int>(elapsedMs),
      'toolCalls': serializer.toJson<int>(toolCalls),
      'cacheHits': serializer.toJson<int>(cacheHits),
      'dedupBlockedCalls': serializer.toJson<int>(dedupBlockedCalls),
      'ragHits': serializer.toJson<int>(ragHits),
      'approvalCount': serializer.toJson<int>(approvalCount),
      'approvedCount': serializer.toJson<int>(approvedCount),
      'auditCount': serializer.toJson<int>(auditCount),
      'helperFanout': serializer.toJson<int>(helperFanout),
      'success': serializer.toJson<bool>(success),
      'selectedToolSetJson': serializer.toJson<String>(selectedToolSetJson),
      'memorySourcesJson': serializer.toJson<String>(memorySourcesJson),
    };
  }

  AgentRunMetricRow copyWith(
          {String? id,
          int? startedAt,
          int? finishedAt,
          String? model,
          String? helperModel,
          String? auditModel,
          int? promptTokens,
          int? completionTokens,
          int? totalTokens,
          int? elapsedMs,
          int? toolCalls,
          int? cacheHits,
          int? dedupBlockedCalls,
          int? ragHits,
          int? approvalCount,
          int? approvedCount,
          int? auditCount,
          int? helperFanout,
          bool? success,
          String? selectedToolSetJson,
          String? memorySourcesJson}) =>
      AgentRunMetricRow(
        id: id ?? this.id,
        startedAt: startedAt ?? this.startedAt,
        finishedAt: finishedAt ?? this.finishedAt,
        model: model ?? this.model,
        helperModel: helperModel ?? this.helperModel,
        auditModel: auditModel ?? this.auditModel,
        promptTokens: promptTokens ?? this.promptTokens,
        completionTokens: completionTokens ?? this.completionTokens,
        totalTokens: totalTokens ?? this.totalTokens,
        elapsedMs: elapsedMs ?? this.elapsedMs,
        toolCalls: toolCalls ?? this.toolCalls,
        cacheHits: cacheHits ?? this.cacheHits,
        dedupBlockedCalls: dedupBlockedCalls ?? this.dedupBlockedCalls,
        ragHits: ragHits ?? this.ragHits,
        approvalCount: approvalCount ?? this.approvalCount,
        approvedCount: approvedCount ?? this.approvedCount,
        auditCount: auditCount ?? this.auditCount,
        helperFanout: helperFanout ?? this.helperFanout,
        success: success ?? this.success,
        selectedToolSetJson: selectedToolSetJson ?? this.selectedToolSetJson,
        memorySourcesJson: memorySourcesJson ?? this.memorySourcesJson,
      );
  AgentRunMetricRow copyWithCompanion(AgentRunMetricsTableCompanion data) {
    return AgentRunMetricRow(
      id: data.id.present ? data.id.value : this.id,
      startedAt: data.startedAt.present ? data.startedAt.value : this.startedAt,
      finishedAt:
          data.finishedAt.present ? data.finishedAt.value : this.finishedAt,
      model: data.model.present ? data.model.value : this.model,
      helperModel:
          data.helperModel.present ? data.helperModel.value : this.helperModel,
      auditModel:
          data.auditModel.present ? data.auditModel.value : this.auditModel,
      promptTokens: data.promptTokens.present
          ? data.promptTokens.value
          : this.promptTokens,
      completionTokens: data.completionTokens.present
          ? data.completionTokens.value
          : this.completionTokens,
      totalTokens:
          data.totalTokens.present ? data.totalTokens.value : this.totalTokens,
      elapsedMs: data.elapsedMs.present ? data.elapsedMs.value : this.elapsedMs,
      toolCalls: data.toolCalls.present ? data.toolCalls.value : this.toolCalls,
      cacheHits: data.cacheHits.present ? data.cacheHits.value : this.cacheHits,
      dedupBlockedCalls: data.dedupBlockedCalls.present
          ? data.dedupBlockedCalls.value
          : this.dedupBlockedCalls,
      ragHits: data.ragHits.present ? data.ragHits.value : this.ragHits,
      approvalCount: data.approvalCount.present
          ? data.approvalCount.value
          : this.approvalCount,
      approvedCount: data.approvedCount.present
          ? data.approvedCount.value
          : this.approvedCount,
      auditCount:
          data.auditCount.present ? data.auditCount.value : this.auditCount,
      helperFanout: data.helperFanout.present
          ? data.helperFanout.value
          : this.helperFanout,
      success: data.success.present ? data.success.value : this.success,
      selectedToolSetJson: data.selectedToolSetJson.present
          ? data.selectedToolSetJson.value
          : this.selectedToolSetJson,
      memorySourcesJson: data.memorySourcesJson.present
          ? data.memorySourcesJson.value
          : this.memorySourcesJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AgentRunMetricRow(')
          ..write('id: $id, ')
          ..write('startedAt: $startedAt, ')
          ..write('finishedAt: $finishedAt, ')
          ..write('model: $model, ')
          ..write('helperModel: $helperModel, ')
          ..write('auditModel: $auditModel, ')
          ..write('promptTokens: $promptTokens, ')
          ..write('completionTokens: $completionTokens, ')
          ..write('totalTokens: $totalTokens, ')
          ..write('elapsedMs: $elapsedMs, ')
          ..write('toolCalls: $toolCalls, ')
          ..write('cacheHits: $cacheHits, ')
          ..write('dedupBlockedCalls: $dedupBlockedCalls, ')
          ..write('ragHits: $ragHits, ')
          ..write('approvalCount: $approvalCount, ')
          ..write('approvedCount: $approvedCount, ')
          ..write('auditCount: $auditCount, ')
          ..write('helperFanout: $helperFanout, ')
          ..write('success: $success, ')
          ..write('selectedToolSetJson: $selectedToolSetJson, ')
          ..write('memorySourcesJson: $memorySourcesJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
        id,
        startedAt,
        finishedAt,
        model,
        helperModel,
        auditModel,
        promptTokens,
        completionTokens,
        totalTokens,
        elapsedMs,
        toolCalls,
        cacheHits,
        dedupBlockedCalls,
        ragHits,
        approvalCount,
        approvedCount,
        auditCount,
        helperFanout,
        success,
        selectedToolSetJson,
        memorySourcesJson
      ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AgentRunMetricRow &&
          other.id == this.id &&
          other.startedAt == this.startedAt &&
          other.finishedAt == this.finishedAt &&
          other.model == this.model &&
          other.helperModel == this.helperModel &&
          other.auditModel == this.auditModel &&
          other.promptTokens == this.promptTokens &&
          other.completionTokens == this.completionTokens &&
          other.totalTokens == this.totalTokens &&
          other.elapsedMs == this.elapsedMs &&
          other.toolCalls == this.toolCalls &&
          other.cacheHits == this.cacheHits &&
          other.dedupBlockedCalls == this.dedupBlockedCalls &&
          other.ragHits == this.ragHits &&
          other.approvalCount == this.approvalCount &&
          other.approvedCount == this.approvedCount &&
          other.auditCount == this.auditCount &&
          other.helperFanout == this.helperFanout &&
          other.success == this.success &&
          other.selectedToolSetJson == this.selectedToolSetJson &&
          other.memorySourcesJson == this.memorySourcesJson);
}

class AgentRunMetricsTableCompanion extends UpdateCompanion<AgentRunMetricRow> {
  final Value<String> id;
  final Value<int> startedAt;
  final Value<int> finishedAt;
  final Value<String> model;
  final Value<String> helperModel;
  final Value<String> auditModel;
  final Value<int> promptTokens;
  final Value<int> completionTokens;
  final Value<int> totalTokens;
  final Value<int> elapsedMs;
  final Value<int> toolCalls;
  final Value<int> cacheHits;
  final Value<int> dedupBlockedCalls;
  final Value<int> ragHits;
  final Value<int> approvalCount;
  final Value<int> approvedCount;
  final Value<int> auditCount;
  final Value<int> helperFanout;
  final Value<bool> success;
  final Value<String> selectedToolSetJson;
  final Value<String> memorySourcesJson;
  final Value<int> rowid;
  const AgentRunMetricsTableCompanion({
    this.id = const Value.absent(),
    this.startedAt = const Value.absent(),
    this.finishedAt = const Value.absent(),
    this.model = const Value.absent(),
    this.helperModel = const Value.absent(),
    this.auditModel = const Value.absent(),
    this.promptTokens = const Value.absent(),
    this.completionTokens = const Value.absent(),
    this.totalTokens = const Value.absent(),
    this.elapsedMs = const Value.absent(),
    this.toolCalls = const Value.absent(),
    this.cacheHits = const Value.absent(),
    this.dedupBlockedCalls = const Value.absent(),
    this.ragHits = const Value.absent(),
    this.approvalCount = const Value.absent(),
    this.approvedCount = const Value.absent(),
    this.auditCount = const Value.absent(),
    this.helperFanout = const Value.absent(),
    this.success = const Value.absent(),
    this.selectedToolSetJson = const Value.absent(),
    this.memorySourcesJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AgentRunMetricsTableCompanion.insert({
    required String id,
    required int startedAt,
    required int finishedAt,
    required String model,
    this.helperModel = const Value.absent(),
    this.auditModel = const Value.absent(),
    this.promptTokens = const Value.absent(),
    this.completionTokens = const Value.absent(),
    this.totalTokens = const Value.absent(),
    this.elapsedMs = const Value.absent(),
    this.toolCalls = const Value.absent(),
    this.cacheHits = const Value.absent(),
    this.dedupBlockedCalls = const Value.absent(),
    this.ragHits = const Value.absent(),
    this.approvalCount = const Value.absent(),
    this.approvedCount = const Value.absent(),
    this.auditCount = const Value.absent(),
    this.helperFanout = const Value.absent(),
    this.success = const Value.absent(),
    this.selectedToolSetJson = const Value.absent(),
    this.memorySourcesJson = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        startedAt = Value(startedAt),
        finishedAt = Value(finishedAt),
        model = Value(model);
  static Insertable<AgentRunMetricRow> custom({
    Expression<String>? id,
    Expression<int>? startedAt,
    Expression<int>? finishedAt,
    Expression<String>? model,
    Expression<String>? helperModel,
    Expression<String>? auditModel,
    Expression<int>? promptTokens,
    Expression<int>? completionTokens,
    Expression<int>? totalTokens,
    Expression<int>? elapsedMs,
    Expression<int>? toolCalls,
    Expression<int>? cacheHits,
    Expression<int>? dedupBlockedCalls,
    Expression<int>? ragHits,
    Expression<int>? approvalCount,
    Expression<int>? approvedCount,
    Expression<int>? auditCount,
    Expression<int>? helperFanout,
    Expression<bool>? success,
    Expression<String>? selectedToolSetJson,
    Expression<String>? memorySourcesJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (startedAt != null) 'started_at': startedAt,
      if (finishedAt != null) 'finished_at': finishedAt,
      if (model != null) 'model': model,
      if (helperModel != null) 'helper_model': helperModel,
      if (auditModel != null) 'audit_model': auditModel,
      if (promptTokens != null) 'prompt_tokens': promptTokens,
      if (completionTokens != null) 'completion_tokens': completionTokens,
      if (totalTokens != null) 'total_tokens': totalTokens,
      if (elapsedMs != null) 'elapsed_ms': elapsedMs,
      if (toolCalls != null) 'tool_calls': toolCalls,
      if (cacheHits != null) 'cache_hits': cacheHits,
      if (dedupBlockedCalls != null) 'dedup_blocked_calls': dedupBlockedCalls,
      if (ragHits != null) 'rag_hits': ragHits,
      if (approvalCount != null) 'approval_count': approvalCount,
      if (approvedCount != null) 'approved_count': approvedCount,
      if (auditCount != null) 'audit_count': auditCount,
      if (helperFanout != null) 'helper_fanout': helperFanout,
      if (success != null) 'success': success,
      if (selectedToolSetJson != null)
        'selected_tool_set_json': selectedToolSetJson,
      if (memorySourcesJson != null) 'memory_sources_json': memorySourcesJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AgentRunMetricsTableCompanion copyWith(
      {Value<String>? id,
      Value<int>? startedAt,
      Value<int>? finishedAt,
      Value<String>? model,
      Value<String>? helperModel,
      Value<String>? auditModel,
      Value<int>? promptTokens,
      Value<int>? completionTokens,
      Value<int>? totalTokens,
      Value<int>? elapsedMs,
      Value<int>? toolCalls,
      Value<int>? cacheHits,
      Value<int>? dedupBlockedCalls,
      Value<int>? ragHits,
      Value<int>? approvalCount,
      Value<int>? approvedCount,
      Value<int>? auditCount,
      Value<int>? helperFanout,
      Value<bool>? success,
      Value<String>? selectedToolSetJson,
      Value<String>? memorySourcesJson,
      Value<int>? rowid}) {
    return AgentRunMetricsTableCompanion(
      id: id ?? this.id,
      startedAt: startedAt ?? this.startedAt,
      finishedAt: finishedAt ?? this.finishedAt,
      model: model ?? this.model,
      helperModel: helperModel ?? this.helperModel,
      auditModel: auditModel ?? this.auditModel,
      promptTokens: promptTokens ?? this.promptTokens,
      completionTokens: completionTokens ?? this.completionTokens,
      totalTokens: totalTokens ?? this.totalTokens,
      elapsedMs: elapsedMs ?? this.elapsedMs,
      toolCalls: toolCalls ?? this.toolCalls,
      cacheHits: cacheHits ?? this.cacheHits,
      dedupBlockedCalls: dedupBlockedCalls ?? this.dedupBlockedCalls,
      ragHits: ragHits ?? this.ragHits,
      approvalCount: approvalCount ?? this.approvalCount,
      approvedCount: approvedCount ?? this.approvedCount,
      auditCount: auditCount ?? this.auditCount,
      helperFanout: helperFanout ?? this.helperFanout,
      success: success ?? this.success,
      selectedToolSetJson: selectedToolSetJson ?? this.selectedToolSetJson,
      memorySourcesJson: memorySourcesJson ?? this.memorySourcesJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (startedAt.present) {
      map['started_at'] = Variable<int>(startedAt.value);
    }
    if (finishedAt.present) {
      map['finished_at'] = Variable<int>(finishedAt.value);
    }
    if (model.present) {
      map['model'] = Variable<String>(model.value);
    }
    if (helperModel.present) {
      map['helper_model'] = Variable<String>(helperModel.value);
    }
    if (auditModel.present) {
      map['audit_model'] = Variable<String>(auditModel.value);
    }
    if (promptTokens.present) {
      map['prompt_tokens'] = Variable<int>(promptTokens.value);
    }
    if (completionTokens.present) {
      map['completion_tokens'] = Variable<int>(completionTokens.value);
    }
    if (totalTokens.present) {
      map['total_tokens'] = Variable<int>(totalTokens.value);
    }
    if (elapsedMs.present) {
      map['elapsed_ms'] = Variable<int>(elapsedMs.value);
    }
    if (toolCalls.present) {
      map['tool_calls'] = Variable<int>(toolCalls.value);
    }
    if (cacheHits.present) {
      map['cache_hits'] = Variable<int>(cacheHits.value);
    }
    if (dedupBlockedCalls.present) {
      map['dedup_blocked_calls'] = Variable<int>(dedupBlockedCalls.value);
    }
    if (ragHits.present) {
      map['rag_hits'] = Variable<int>(ragHits.value);
    }
    if (approvalCount.present) {
      map['approval_count'] = Variable<int>(approvalCount.value);
    }
    if (approvedCount.present) {
      map['approved_count'] = Variable<int>(approvedCount.value);
    }
    if (auditCount.present) {
      map['audit_count'] = Variable<int>(auditCount.value);
    }
    if (helperFanout.present) {
      map['helper_fanout'] = Variable<int>(helperFanout.value);
    }
    if (success.present) {
      map['success'] = Variable<bool>(success.value);
    }
    if (selectedToolSetJson.present) {
      map['selected_tool_set_json'] =
          Variable<String>(selectedToolSetJson.value);
    }
    if (memorySourcesJson.present) {
      map['memory_sources_json'] = Variable<String>(memorySourcesJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AgentRunMetricsTableCompanion(')
          ..write('id: $id, ')
          ..write('startedAt: $startedAt, ')
          ..write('finishedAt: $finishedAt, ')
          ..write('model: $model, ')
          ..write('helperModel: $helperModel, ')
          ..write('auditModel: $auditModel, ')
          ..write('promptTokens: $promptTokens, ')
          ..write('completionTokens: $completionTokens, ')
          ..write('totalTokens: $totalTokens, ')
          ..write('elapsedMs: $elapsedMs, ')
          ..write('toolCalls: $toolCalls, ')
          ..write('cacheHits: $cacheHits, ')
          ..write('dedupBlockedCalls: $dedupBlockedCalls, ')
          ..write('ragHits: $ragHits, ')
          ..write('approvalCount: $approvalCount, ')
          ..write('approvedCount: $approvedCount, ')
          ..write('auditCount: $auditCount, ')
          ..write('helperFanout: $helperFanout, ')
          ..write('success: $success, ')
          ..write('selectedToolSetJson: $selectedToolSetJson, ')
          ..write('memorySourcesJson: $memorySourcesJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TerminalHistoryRecordsTable extends TerminalHistoryRecords
    with TableInfo<$TerminalHistoryRecordsTable, TerminalHistoryRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TerminalHistoryRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sessionIdMeta =
      const VerificationMeta('sessionId');
  @override
  late final GeneratedColumn<String> sessionId = GeneratedColumn<String>(
      'session_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _connectionIdMeta =
      const VerificationMeta('connectionId');
  @override
  late final GeneratedColumn<String> connectionId = GeneratedColumn<String>(
      'connection_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _connectionNameMeta =
      const VerificationMeta('connectionName');
  @override
  late final GeneratedColumn<String> connectionName = GeneratedColumn<String>(
      'connection_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _displayNameMeta =
      const VerificationMeta('displayName');
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
      'display_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _tmuxSessionNameMeta =
      const VerificationMeta('tmuxSessionName');
  @override
  late final GeneratedColumn<String> tmuxSessionName = GeneratedColumn<String>(
      'tmux_session_name', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
      'state', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _errorMessageMeta =
      const VerificationMeta('errorMessage');
  @override
  late final GeneratedColumn<String> errorMessage = GeneratedColumn<String>(
      'error_message', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
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
        updatedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'terminal_history_records';
  @override
  VerificationContext validateIntegrity(
      Insertable<TerminalHistoryRecord> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('session_id')) {
      context.handle(_sessionIdMeta,
          sessionId.isAcceptableOrUnknown(data['session_id']!, _sessionIdMeta));
    } else if (isInserting) {
      context.missing(_sessionIdMeta);
    }
    if (data.containsKey('connection_id')) {
      context.handle(
          _connectionIdMeta,
          connectionId.isAcceptableOrUnknown(
              data['connection_id']!, _connectionIdMeta));
    } else if (isInserting) {
      context.missing(_connectionIdMeta);
    }
    if (data.containsKey('connection_name')) {
      context.handle(
          _connectionNameMeta,
          connectionName.isAcceptableOrUnknown(
              data['connection_name']!, _connectionNameMeta));
    } else if (isInserting) {
      context.missing(_connectionNameMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
          _displayNameMeta,
          displayName.isAcceptableOrUnknown(
              data['display_name']!, _displayNameMeta));
    } else if (isInserting) {
      context.missing(_displayNameMeta);
    }
    if (data.containsKey('tmux_session_name')) {
      context.handle(
          _tmuxSessionNameMeta,
          tmuxSessionName.isAcceptableOrUnknown(
              data['tmux_session_name']!, _tmuxSessionNameMeta));
    }
    if (data.containsKey('state')) {
      context.handle(
          _stateMeta, state.isAcceptableOrUnknown(data['state']!, _stateMeta));
    } else if (isInserting) {
      context.missing(_stateMeta);
    }
    if (data.containsKey('error_message')) {
      context.handle(
          _errorMessageMeta,
          errorMessage.isAcceptableOrUnknown(
              data['error_message']!, _errorMessageMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
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
      sessionId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}session_id'])!,
      connectionId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}connection_id'])!,
      connectionName: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}connection_name'])!,
      displayName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}display_name'])!,
      tmuxSessionName: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}tmux_session_name']),
      state: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}state'])!,
      errorMessage: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}error_message']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
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
  const TerminalHistoryRecord(
      {required this.sessionId,
      required this.connectionId,
      required this.connectionName,
      required this.displayName,
      this.tmuxSessionName,
      required this.state,
      this.errorMessage,
      required this.createdAt,
      required this.updatedAt});
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

  factory TerminalHistoryRecord.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
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

  TerminalHistoryRecord copyWith(
          {String? sessionId,
          String? connectionId,
          String? connectionName,
          String? displayName,
          Value<String?> tmuxSessionName = const Value.absent(),
          String? state,
          Value<String?> errorMessage = const Value.absent(),
          int? createdAt,
          int? updatedAt}) =>
      TerminalHistoryRecord(
        sessionId: sessionId ?? this.sessionId,
        connectionId: connectionId ?? this.connectionId,
        connectionName: connectionName ?? this.connectionName,
        displayName: displayName ?? this.displayName,
        tmuxSessionName: tmuxSessionName.present
            ? tmuxSessionName.value
            : this.tmuxSessionName,
        state: state ?? this.state,
        errorMessage:
            errorMessage.present ? errorMessage.value : this.errorMessage,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  TerminalHistoryRecord copyWithCompanion(
      TerminalHistoryRecordsCompanion data) {
    return TerminalHistoryRecord(
      sessionId: data.sessionId.present ? data.sessionId.value : this.sessionId,
      connectionId: data.connectionId.present
          ? data.connectionId.value
          : this.connectionId,
      connectionName: data.connectionName.present
          ? data.connectionName.value
          : this.connectionName,
      displayName:
          data.displayName.present ? data.displayName.value : this.displayName,
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
  int get hashCode => Object.hash(sessionId, connectionId, connectionName,
      displayName, tmuxSessionName, state, errorMessage, createdAt, updatedAt);
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
  })  : sessionId = Value(sessionId),
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

  TerminalHistoryRecordsCompanion copyWith(
      {Value<String>? sessionId,
      Value<String>? connectionId,
      Value<String>? connectionName,
      Value<String>? displayName,
      Value<String?>? tmuxSessionName,
      Value<String>? state,
      Value<String?>? errorMessage,
      Value<int>? createdAt,
      Value<int>? updatedAt,
      Value<int>? rowid}) {
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
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _descriptionMeta =
      const VerificationMeta('description');
  @override
  late final GeneratedColumn<String> description = GeneratedColumn<String>(
      'description', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _contentJsonMeta =
      const VerificationMeta('contentJson');
  @override
  late final GeneratedColumn<String> contentJson = GeneratedColumn<String>(
      'content_json', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, name, description, contentJson, createdAt, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'playbooks';
  @override
  VerificationContext validateIntegrity(Insertable<Playbook> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('description')) {
      context.handle(
          _descriptionMeta,
          description.isAcceptableOrUnknown(
              data['description']!, _descriptionMeta));
    }
    if (data.containsKey('content_json')) {
      context.handle(
          _contentJsonMeta,
          contentJson.isAcceptableOrUnknown(
              data['content_json']!, _contentJsonMeta));
    } else if (isInserting) {
      context.missing(_contentJsonMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
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
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      description: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}description'])!,
      contentJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}content_json'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
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
  const Playbook(
      {required this.id,
      required this.name,
      required this.description,
      required this.contentJson,
      required this.createdAt,
      required this.updatedAt});
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

  factory Playbook.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
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

  Playbook copyWith(
          {String? id,
          String? name,
          String? description,
          String? contentJson,
          int? createdAt,
          int? updatedAt}) =>
      Playbook(
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
      description:
          data.description.present ? data.description.value : this.description,
      contentJson:
          data.contentJson.present ? data.contentJson.value : this.contentJson,
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
  })  : id = Value(id),
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

  PlaybooksCompanion copyWith(
      {Value<String>? id,
      Value<String>? name,
      Value<String>? description,
      Value<String>? contentJson,
      Value<int>? createdAt,
      Value<int>? updatedAt,
      Value<int>? rowid}) {
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
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _playbookIdMeta =
      const VerificationMeta('playbookId');
  @override
  late final GeneratedColumn<String> playbookId = GeneratedColumn<String>(
      'playbook_id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES playbooks (id) ON DELETE CASCADE'));
  static const VerificationMeta _connectionIdMeta =
      const VerificationMeta('connectionId');
  @override
  late final GeneratedColumn<String> connectionId = GeneratedColumn<String>(
      'connection_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
      'status', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _startedAtMeta =
      const VerificationMeta('startedAt');
  @override
  late final GeneratedColumn<int> startedAt = GeneratedColumn<int>(
      'started_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _finishedAtMeta =
      const VerificationMeta('finishedAt');
  @override
  late final GeneratedColumn<int> finishedAt = GeneratedColumn<int>(
      'finished_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _summaryMeta =
      const VerificationMeta('summary');
  @override
  late final GeneratedColumn<String> summary = GeneratedColumn<String>(
      'summary', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _errorMessageMeta =
      const VerificationMeta('errorMessage');
  @override
  late final GeneratedColumn<String> errorMessage = GeneratedColumn<String>(
      'error_message', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        playbookId,
        connectionId,
        status,
        startedAt,
        finishedAt,
        summary,
        errorMessage
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'playbook_runs';
  @override
  VerificationContext validateIntegrity(Insertable<PlaybookRun> instance,
      {bool isInserting = false}) {
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
          playbookId.isAcceptableOrUnknown(
              data['playbook_id']!, _playbookIdMeta));
    } else if (isInserting) {
      context.missing(_playbookIdMeta);
    }
    if (data.containsKey('connection_id')) {
      context.handle(
          _connectionIdMeta,
          connectionId.isAcceptableOrUnknown(
              data['connection_id']!, _connectionIdMeta));
    }
    if (data.containsKey('status')) {
      context.handle(_statusMeta,
          status.isAcceptableOrUnknown(data['status']!, _statusMeta));
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('started_at')) {
      context.handle(_startedAtMeta,
          startedAt.isAcceptableOrUnknown(data['started_at']!, _startedAtMeta));
    } else if (isInserting) {
      context.missing(_startedAtMeta);
    }
    if (data.containsKey('finished_at')) {
      context.handle(
          _finishedAtMeta,
          finishedAt.isAcceptableOrUnknown(
              data['finished_at']!, _finishedAtMeta));
    }
    if (data.containsKey('summary')) {
      context.handle(_summaryMeta,
          summary.isAcceptableOrUnknown(data['summary']!, _summaryMeta));
    }
    if (data.containsKey('error_message')) {
      context.handle(
          _errorMessageMeta,
          errorMessage.isAcceptableOrUnknown(
              data['error_message']!, _errorMessageMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PlaybookRun map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlaybookRun(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      playbookId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}playbook_id'])!,
      connectionId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}connection_id']),
      status: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}status'])!,
      startedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}started_at'])!,
      finishedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}finished_at']),
      summary: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}summary'])!,
      errorMessage: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}error_message']),
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
  const PlaybookRun(
      {required this.id,
      required this.playbookId,
      this.connectionId,
      required this.status,
      required this.startedAt,
      this.finishedAt,
      required this.summary,
      this.errorMessage});
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

  factory PlaybookRun.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
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

  PlaybookRun copyWith(
          {String? id,
          String? playbookId,
          Value<String?> connectionId = const Value.absent(),
          String? status,
          int? startedAt,
          Value<int?> finishedAt = const Value.absent(),
          String? summary,
          Value<String?> errorMessage = const Value.absent()}) =>
      PlaybookRun(
        id: id ?? this.id,
        playbookId: playbookId ?? this.playbookId,
        connectionId:
            connectionId.present ? connectionId.value : this.connectionId,
        status: status ?? this.status,
        startedAt: startedAt ?? this.startedAt,
        finishedAt: finishedAt.present ? finishedAt.value : this.finishedAt,
        summary: summary ?? this.summary,
        errorMessage:
            errorMessage.present ? errorMessage.value : this.errorMessage,
      );
  PlaybookRun copyWithCompanion(PlaybookRunsCompanion data) {
    return PlaybookRun(
      id: data.id.present ? data.id.value : this.id,
      playbookId:
          data.playbookId.present ? data.playbookId.value : this.playbookId,
      connectionId: data.connectionId.present
          ? data.connectionId.value
          : this.connectionId,
      status: data.status.present ? data.status.value : this.status,
      startedAt: data.startedAt.present ? data.startedAt.value : this.startedAt,
      finishedAt:
          data.finishedAt.present ? data.finishedAt.value : this.finishedAt,
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
  int get hashCode => Object.hash(id, playbookId, connectionId, status,
      startedAt, finishedAt, summary, errorMessage);
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
  })  : id = Value(id),
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

  PlaybookRunsCompanion copyWith(
      {Value<String>? id,
      Value<String>? playbookId,
      Value<String?>? connectionId,
      Value<String>? status,
      Value<int>? startedAt,
      Value<int?>? finishedAt,
      Value<String>? summary,
      Value<String?>? errorMessage,
      Value<int>? rowid}) {
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
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _runIdMeta = const VerificationMeta('runId');
  @override
  late final GeneratedColumn<String> runId = GeneratedColumn<String>(
      'run_id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES playbook_runs (id) ON DELETE CASCADE'));
  static const VerificationMeta _stepIndexMeta =
      const VerificationMeta('stepIndex');
  @override
  late final GeneratedColumn<int> stepIndex = GeneratedColumn<int>(
      'step_index', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _commandMeta =
      const VerificationMeta('command');
  @override
  late final GeneratedColumn<String> command = GeneratedColumn<String>(
      'command', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
      'status', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _stdoutPreviewMeta =
      const VerificationMeta('stdoutPreview');
  @override
  late final GeneratedColumn<String> stdoutPreview = GeneratedColumn<String>(
      'stdout_preview', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _stderrPreviewMeta =
      const VerificationMeta('stderrPreview');
  @override
  late final GeneratedColumn<String> stderrPreview = GeneratedColumn<String>(
      'stderr_preview', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _exitCodeMeta =
      const VerificationMeta('exitCode');
  @override
  late final GeneratedColumn<int> exitCode = GeneratedColumn<int>(
      'exit_code', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
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
        exitCode
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'playbook_run_steps';
  @override
  VerificationContext validateIntegrity(Insertable<PlaybookRunStep> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('run_id')) {
      context.handle(
          _runIdMeta, runId.isAcceptableOrUnknown(data['run_id']!, _runIdMeta));
    } else if (isInserting) {
      context.missing(_runIdMeta);
    }
    if (data.containsKey('step_index')) {
      context.handle(_stepIndexMeta,
          stepIndex.isAcceptableOrUnknown(data['step_index']!, _stepIndexMeta));
    } else if (isInserting) {
      context.missing(_stepIndexMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('command')) {
      context.handle(_commandMeta,
          command.isAcceptableOrUnknown(data['command']!, _commandMeta));
    } else if (isInserting) {
      context.missing(_commandMeta);
    }
    if (data.containsKey('status')) {
      context.handle(_statusMeta,
          status.isAcceptableOrUnknown(data['status']!, _statusMeta));
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('stdout_preview')) {
      context.handle(
          _stdoutPreviewMeta,
          stdoutPreview.isAcceptableOrUnknown(
              data['stdout_preview']!, _stdoutPreviewMeta));
    }
    if (data.containsKey('stderr_preview')) {
      context.handle(
          _stderrPreviewMeta,
          stderrPreview.isAcceptableOrUnknown(
              data['stderr_preview']!, _stderrPreviewMeta));
    }
    if (data.containsKey('exit_code')) {
      context.handle(_exitCodeMeta,
          exitCode.isAcceptableOrUnknown(data['exit_code']!, _exitCodeMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PlaybookRunStep map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlaybookRunStep(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      runId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}run_id'])!,
      stepIndex: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}step_index'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      command: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}command'])!,
      status: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}status'])!,
      stdoutPreview: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}stdout_preview']),
      stderrPreview: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}stderr_preview']),
      exitCode: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}exit_code']),
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
  const PlaybookRunStep(
      {required this.id,
      required this.runId,
      required this.stepIndex,
      required this.name,
      required this.command,
      required this.status,
      this.stdoutPreview,
      this.stderrPreview,
      this.exitCode});
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

  factory PlaybookRunStep.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
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

  PlaybookRunStep copyWith(
          {String? id,
          String? runId,
          int? stepIndex,
          String? name,
          String? command,
          String? status,
          Value<String?> stdoutPreview = const Value.absent(),
          Value<String?> stderrPreview = const Value.absent(),
          Value<int?> exitCode = const Value.absent()}) =>
      PlaybookRunStep(
        id: id ?? this.id,
        runId: runId ?? this.runId,
        stepIndex: stepIndex ?? this.stepIndex,
        name: name ?? this.name,
        command: command ?? this.command,
        status: status ?? this.status,
        stdoutPreview:
            stdoutPreview.present ? stdoutPreview.value : this.stdoutPreview,
        stderrPreview:
            stderrPreview.present ? stderrPreview.value : this.stderrPreview,
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
  int get hashCode => Object.hash(id, runId, stepIndex, name, command, status,
      stdoutPreview, stderrPreview, exitCode);
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
  })  : id = Value(id),
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

  PlaybookRunStepsCompanion copyWith(
      {Value<String>? id,
      Value<String>? runId,
      Value<int>? stepIndex,
      Value<String>? name,
      Value<String>? command,
      Value<String>? status,
      Value<String?>? stdoutPreview,
      Value<String?>? stderrPreview,
      Value<int?>? exitCode,
      Value<int>? rowid}) {
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
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _connectionIdMeta =
      const VerificationMeta('connectionId');
  @override
  late final GeneratedColumn<String> connectionId = GeneratedColumn<String>(
      'connection_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
      'path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _visitedAtMeta =
      const VerificationMeta('visitedAt');
  @override
  late final GeneratedColumn<int> visitedAt = GeneratedColumn<int>(
      'visited_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [id, connectionId, path, visitedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sftp_recent_paths';
  @override
  VerificationContext validateIntegrity(Insertable<SftpRecentPath> instance,
      {bool isInserting = false}) {
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
              data['connection_id']!, _connectionIdMeta));
    } else if (isInserting) {
      context.missing(_connectionIdMeta);
    }
    if (data.containsKey('path')) {
      context.handle(
          _pathMeta, path.isAcceptableOrUnknown(data['path']!, _pathMeta));
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('visited_at')) {
      context.handle(_visitedAtMeta,
          visitedAt.isAcceptableOrUnknown(data['visited_at']!, _visitedAtMeta));
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
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      connectionId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}connection_id'])!,
      path: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}path'])!,
      visitedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}visited_at'])!,
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
  const SftpRecentPath(
      {required this.id,
      required this.connectionId,
      required this.path,
      required this.visitedAt});
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

  factory SftpRecentPath.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
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

  SftpRecentPath copyWith(
          {String? id, String? connectionId, String? path, int? visitedAt}) =>
      SftpRecentPath(
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
  })  : id = Value(id),
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

  SftpRecentPathsCompanion copyWith(
      {Value<String>? id,
      Value<String>? connectionId,
      Value<String>? path,
      Value<int>? visitedAt,
      Value<int>? rowid}) {
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
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _connectionIdMeta =
      const VerificationMeta('connectionId');
  @override
  late final GeneratedColumn<String> connectionId = GeneratedColumn<String>(
      'connection_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
      'path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, connectionId, path, name, createdAt, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sftp_favorite_paths';
  @override
  VerificationContext validateIntegrity(Insertable<SftpFavoritePath> instance,
      {bool isInserting = false}) {
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
              data['connection_id']!, _connectionIdMeta));
    } else if (isInserting) {
      context.missing(_connectionIdMeta);
    }
    if (data.containsKey('path')) {
      context.handle(
          _pathMeta, path.isAcceptableOrUnknown(data['path']!, _pathMeta));
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
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
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      connectionId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}connection_id'])!,
      path: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}path'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
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
  const SftpFavoritePath(
      {required this.id,
      required this.connectionId,
      required this.path,
      required this.name,
      required this.createdAt,
      required this.updatedAt});
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

  factory SftpFavoritePath.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
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

  SftpFavoritePath copyWith(
          {String? id,
          String? connectionId,
          String? path,
          String? name,
          int? createdAt,
          int? updatedAt}) =>
      SftpFavoritePath(
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
  })  : id = Value(id),
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

  SftpFavoritePathsCompanion copyWith(
      {Value<String>? id,
      Value<String>? connectionId,
      Value<String>? path,
      Value<String>? name,
      Value<int>? createdAt,
      Value<int>? updatedAt,
      Value<int>? rowid}) {
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

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $MigrationMetaTable migrationMeta = $MigrationMetaTable(this);
  late final $AiChatsTable aiChats = $AiChatsTable(this);
  late final $AiChatMessagesTable aiChatMessages = $AiChatMessagesTable(this);
  late final $AgentRunMetricsTableTable agentRunMetricsTable =
      $AgentRunMetricsTableTable(this);
  late final $TerminalHistoryRecordsTable terminalHistoryRecords =
      $TerminalHistoryRecordsTable(this);
  late final $PlaybooksTable playbooks = $PlaybooksTable(this);
  late final $PlaybookRunsTable playbookRuns = $PlaybookRunsTable(this);
  late final $PlaybookRunStepsTable playbookRunSteps =
      $PlaybookRunStepsTable(this);
  late final $SftpRecentPathsTable sftpRecentPaths =
      $SftpRecentPathsTable(this);
  late final $SftpFavoritePathsTable sftpFavoritePaths =
      $SftpFavoritePathsTable(this);
  late final MigrationMetaDao migrationMetaDao =
      MigrationMetaDao(this as AppDatabase);
  late final AiChatDao aiChatDao = AiChatDao(this as AppDatabase);
  late final AgentMetricsDao agentMetricsDao =
      AgentMetricsDao(this as AppDatabase);
  late final TerminalHistoryDao terminalHistoryDao =
      TerminalHistoryDao(this as AppDatabase);
  late final PlaybookDao playbookDao = PlaybookDao(this as AppDatabase);
  late final SftpHistoryDao sftpHistoryDao =
      SftpHistoryDao(this as AppDatabase);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        migrationMeta,
        aiChats,
        aiChatMessages,
        agentRunMetricsTable,
        terminalHistoryRecords,
        playbooks,
        playbookRuns,
        playbookRunSteps,
        sftpRecentPaths,
        sftpFavoritePaths
      ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules(
        [
          WritePropagation(
            on: TableUpdateQuery.onTableName('ai_chats',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('ai_chat_messages', kind: UpdateKind.delete),
            ],
          ),
          WritePropagation(
            on: TableUpdateQuery.onTableName('playbooks',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('playbook_runs', kind: UpdateKind.delete),
            ],
          ),
          WritePropagation(
            on: TableUpdateQuery.onTableName('playbook_runs',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('playbook_run_steps', kind: UpdateKind.delete),
            ],
          ),
        ],
      );
}

typedef $$MigrationMetaTableCreateCompanionBuilder = MigrationMetaCompanion
    Function({
  required String key,
  required String value,
  required int updatedAt,
  Value<int> rowid,
});
typedef $$MigrationMetaTableUpdateCompanionBuilder = MigrationMetaCompanion
    Function({
  Value<String> key,
  Value<String> value,
  Value<int> updatedAt,
  Value<int> rowid,
});

class $$MigrationMetaTableFilterComposer
    extends Composer<_$AppDatabase, $MigrationMetaTable> {
  $$MigrationMetaTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$MigrationMetaTableOrderingComposer
    extends Composer<_$AppDatabase, $MigrationMetaTable> {
  $$MigrationMetaTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$MigrationMetaTableAnnotationComposer
    extends Composer<_$AppDatabase, $MigrationMetaTable> {
  $$MigrationMetaTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$MigrationMetaTableTableManager extends RootTableManager<
    _$AppDatabase,
    $MigrationMetaTable,
    MigrationMetaData,
    $$MigrationMetaTableFilterComposer,
    $$MigrationMetaTableOrderingComposer,
    $$MigrationMetaTableAnnotationComposer,
    $$MigrationMetaTableCreateCompanionBuilder,
    $$MigrationMetaTableUpdateCompanionBuilder,
    (
      MigrationMetaData,
      BaseReferences<_$AppDatabase, $MigrationMetaTable, MigrationMetaData>
    ),
    MigrationMetaData,
    PrefetchHooks Function()> {
  $$MigrationMetaTableTableManager(_$AppDatabase db, $MigrationMetaTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MigrationMetaTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MigrationMetaTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MigrationMetaTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> updatedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              MigrationMetaCompanion(
            key: key,
            value: value,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String key,
            required String value,
            required int updatedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              MigrationMetaCompanion.insert(
            key: key,
            value: value,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$MigrationMetaTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $MigrationMetaTable,
    MigrationMetaData,
    $$MigrationMetaTableFilterComposer,
    $$MigrationMetaTableOrderingComposer,
    $$MigrationMetaTableAnnotationComposer,
    $$MigrationMetaTableCreateCompanionBuilder,
    $$MigrationMetaTableUpdateCompanionBuilder,
    (
      MigrationMetaData,
      BaseReferences<_$AppDatabase, $MigrationMetaTable, MigrationMetaData>
    ),
    MigrationMetaData,
    PrefetchHooks Function()>;
typedef $$AiChatsTableCreateCompanionBuilder = AiChatsCompanion Function({
  required String id,
  required String title,
  required String model,
  required int createdAt,
  required int updatedAt,
  Value<bool> planMode,
  Value<int?> approvedPlanAssistantCreatedAt,
  Value<int?> approvedPlanApprovedAt,
  Value<int> rowid,
});
typedef $$AiChatsTableUpdateCompanionBuilder = AiChatsCompanion Function({
  Value<String> id,
  Value<String> title,
  Value<String> model,
  Value<int> createdAt,
  Value<int> updatedAt,
  Value<bool> planMode,
  Value<int?> approvedPlanAssistantCreatedAt,
  Value<int?> approvedPlanApprovedAt,
  Value<int> rowid,
});

final class $$AiChatsTableReferences
    extends BaseReferences<_$AppDatabase, $AiChatsTable, AiChat> {
  $$AiChatsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$AiChatMessagesTable, List<AiChatMessage>>
      _aiChatMessagesRefsTable(_$AppDatabase db) =>
          MultiTypedResultKey.fromTable(db.aiChatMessages,
              aliasName: 'ai_chats__id__ai_chat_messages__chat_id');

  $$AiChatMessagesTableProcessedTableManager get aiChatMessagesRefs {
    final manager = $$AiChatMessagesTableTableManager($_db, $_db.aiChatMessages)
        .filter((f) => f.chatId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_aiChatMessagesRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$AiChatsTableFilterComposer
    extends Composer<_$AppDatabase, $AiChatsTable> {
  $$AiChatsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get model => $composableBuilder(
      column: $table.model, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get planMode => $composableBuilder(
      column: $table.planMode, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get approvedPlanAssistantCreatedAt => $composableBuilder(
      column: $table.approvedPlanAssistantCreatedAt,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get approvedPlanApprovedAt => $composableBuilder(
      column: $table.approvedPlanApprovedAt,
      builder: (column) => ColumnFilters(column));

  Expression<bool> aiChatMessagesRefs(
      Expression<bool> Function($$AiChatMessagesTableFilterComposer f) f) {
    final $$AiChatMessagesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.aiChatMessages,
        getReferencedColumn: (t) => t.chatId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$AiChatMessagesTableFilterComposer(
              $db: $db,
              $table: $db.aiChatMessages,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$AiChatsTableOrderingComposer
    extends Composer<_$AppDatabase, $AiChatsTable> {
  $$AiChatsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get model => $composableBuilder(
      column: $table.model, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get planMode => $composableBuilder(
      column: $table.planMode, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get approvedPlanAssistantCreatedAt => $composableBuilder(
      column: $table.approvedPlanAssistantCreatedAt,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get approvedPlanApprovedAt => $composableBuilder(
      column: $table.approvedPlanApprovedAt,
      builder: (column) => ColumnOrderings(column));
}

class $$AiChatsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AiChatsTable> {
  $$AiChatsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get model =>
      $composableBuilder(column: $table.model, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<bool> get planMode =>
      $composableBuilder(column: $table.planMode, builder: (column) => column);

  GeneratedColumn<int> get approvedPlanAssistantCreatedAt => $composableBuilder(
      column: $table.approvedPlanAssistantCreatedAt,
      builder: (column) => column);

  GeneratedColumn<int> get approvedPlanApprovedAt => $composableBuilder(
      column: $table.approvedPlanApprovedAt, builder: (column) => column);

  Expression<T> aiChatMessagesRefs<T extends Object>(
      Expression<T> Function($$AiChatMessagesTableAnnotationComposer a) f) {
    final $$AiChatMessagesTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.aiChatMessages,
        getReferencedColumn: (t) => t.chatId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$AiChatMessagesTableAnnotationComposer(
              $db: $db,
              $table: $db.aiChatMessages,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$AiChatsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $AiChatsTable,
    AiChat,
    $$AiChatsTableFilterComposer,
    $$AiChatsTableOrderingComposer,
    $$AiChatsTableAnnotationComposer,
    $$AiChatsTableCreateCompanionBuilder,
    $$AiChatsTableUpdateCompanionBuilder,
    (AiChat, $$AiChatsTableReferences),
    AiChat,
    PrefetchHooks Function({bool aiChatMessagesRefs})> {
  $$AiChatsTableTableManager(_$AppDatabase db, $AiChatsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AiChatsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AiChatsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AiChatsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String> model = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
            Value<int> updatedAt = const Value.absent(),
            Value<bool> planMode = const Value.absent(),
            Value<int?> approvedPlanAssistantCreatedAt = const Value.absent(),
            Value<int?> approvedPlanApprovedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              AiChatsCompanion(
            id: id,
            title: title,
            model: model,
            createdAt: createdAt,
            updatedAt: updatedAt,
            planMode: planMode,
            approvedPlanAssistantCreatedAt: approvedPlanAssistantCreatedAt,
            approvedPlanApprovedAt: approvedPlanApprovedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String title,
            required String model,
            required int createdAt,
            required int updatedAt,
            Value<bool> planMode = const Value.absent(),
            Value<int?> approvedPlanAssistantCreatedAt = const Value.absent(),
            Value<int?> approvedPlanApprovedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              AiChatsCompanion.insert(
            id: id,
            title: title,
            model: model,
            createdAt: createdAt,
            updatedAt: updatedAt,
            planMode: planMode,
            approvedPlanAssistantCreatedAt: approvedPlanAssistantCreatedAt,
            approvedPlanApprovedAt: approvedPlanApprovedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$AiChatsTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: ({aiChatMessagesRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (aiChatMessagesRefs) db.aiChatMessages
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (aiChatMessagesRefs)
                    await $_getPrefetchedData<AiChat, $AiChatsTable,
                            AiChatMessage>(
                        currentTable: table,
                        referencedTable: $$AiChatsTableReferences
                            ._aiChatMessagesRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$AiChatsTableReferences(db, table, p0)
                                .aiChatMessagesRefs,
                        referencedItemsForCurrentItem: (item,
                                referencedItems) =>
                            referencedItems.where((e) => e.chatId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$AiChatsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $AiChatsTable,
    AiChat,
    $$AiChatsTableFilterComposer,
    $$AiChatsTableOrderingComposer,
    $$AiChatsTableAnnotationComposer,
    $$AiChatsTableCreateCompanionBuilder,
    $$AiChatsTableUpdateCompanionBuilder,
    (AiChat, $$AiChatsTableReferences),
    AiChat,
    PrefetchHooks Function({bool aiChatMessagesRefs})>;
typedef $$AiChatMessagesTableCreateCompanionBuilder = AiChatMessagesCompanion
    Function({
  required String id,
  required String chatId,
  required String role,
  required String textContent,
  Value<String?> contextText,
  required int createdAt,
  Value<int?> promptTokens,
  Value<int?> completionTokens,
  Value<int?> totalTokens,
  Value<int?> elapsedMs,
  Value<bool?> tokenUsageEstimated,
  Value<int?> promptCacheHitTokens,
  Value<int?> promptCacheMissTokens,
  Value<int?> reasoningTokens,
  Value<String> attachmentsJson,
  Value<String> tracesJson,
  Value<String> todoStepsJson,
  Value<int> rowid,
});
typedef $$AiChatMessagesTableUpdateCompanionBuilder = AiChatMessagesCompanion
    Function({
  Value<String> id,
  Value<String> chatId,
  Value<String> role,
  Value<String> textContent,
  Value<String?> contextText,
  Value<int> createdAt,
  Value<int?> promptTokens,
  Value<int?> completionTokens,
  Value<int?> totalTokens,
  Value<int?> elapsedMs,
  Value<bool?> tokenUsageEstimated,
  Value<int?> promptCacheHitTokens,
  Value<int?> promptCacheMissTokens,
  Value<int?> reasoningTokens,
  Value<String> attachmentsJson,
  Value<String> tracesJson,
  Value<String> todoStepsJson,
  Value<int> rowid,
});

final class $$AiChatMessagesTableReferences
    extends BaseReferences<_$AppDatabase, $AiChatMessagesTable, AiChatMessage> {
  $$AiChatMessagesTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $AiChatsTable _chatIdTable(_$AppDatabase db) =>
      db.aiChats.createAlias('ai_chat_messages__chat_id__ai_chats__id');

  $$AiChatsTableProcessedTableManager get chatId {
    final $_column = $_itemColumn<String>('chat_id')!;

    final manager = $$AiChatsTableTableManager($_db, $_db.aiChats)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_chatIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$AiChatMessagesTableFilterComposer
    extends Composer<_$AppDatabase, $AiChatMessagesTable> {
  $$AiChatMessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get role => $composableBuilder(
      column: $table.role, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get textContent => $composableBuilder(
      column: $table.textContent, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get contextText => $composableBuilder(
      column: $table.contextText, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get promptTokens => $composableBuilder(
      column: $table.promptTokens, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get completionTokens => $composableBuilder(
      column: $table.completionTokens,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get totalTokens => $composableBuilder(
      column: $table.totalTokens, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get elapsedMs => $composableBuilder(
      column: $table.elapsedMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get tokenUsageEstimated => $composableBuilder(
      column: $table.tokenUsageEstimated,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get promptCacheHitTokens => $composableBuilder(
      column: $table.promptCacheHitTokens,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get promptCacheMissTokens => $composableBuilder(
      column: $table.promptCacheMissTokens,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get reasoningTokens => $composableBuilder(
      column: $table.reasoningTokens,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get attachmentsJson => $composableBuilder(
      column: $table.attachmentsJson,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get tracesJson => $composableBuilder(
      column: $table.tracesJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get todoStepsJson => $composableBuilder(
      column: $table.todoStepsJson, builder: (column) => ColumnFilters(column));

  $$AiChatsTableFilterComposer get chatId {
    final $$AiChatsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.chatId,
        referencedTable: $db.aiChats,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$AiChatsTableFilterComposer(
              $db: $db,
              $table: $db.aiChats,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$AiChatMessagesTableOrderingComposer
    extends Composer<_$AppDatabase, $AiChatMessagesTable> {
  $$AiChatMessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get role => $composableBuilder(
      column: $table.role, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get textContent => $composableBuilder(
      column: $table.textContent, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get contextText => $composableBuilder(
      column: $table.contextText, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get promptTokens => $composableBuilder(
      column: $table.promptTokens,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get completionTokens => $composableBuilder(
      column: $table.completionTokens,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get totalTokens => $composableBuilder(
      column: $table.totalTokens, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get elapsedMs => $composableBuilder(
      column: $table.elapsedMs, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get tokenUsageEstimated => $composableBuilder(
      column: $table.tokenUsageEstimated,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get promptCacheHitTokens => $composableBuilder(
      column: $table.promptCacheHitTokens,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get promptCacheMissTokens => $composableBuilder(
      column: $table.promptCacheMissTokens,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get reasoningTokens => $composableBuilder(
      column: $table.reasoningTokens,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get attachmentsJson => $composableBuilder(
      column: $table.attachmentsJson,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get tracesJson => $composableBuilder(
      column: $table.tracesJson, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get todoStepsJson => $composableBuilder(
      column: $table.todoStepsJson,
      builder: (column) => ColumnOrderings(column));

  $$AiChatsTableOrderingComposer get chatId {
    final $$AiChatsTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.chatId,
        referencedTable: $db.aiChats,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$AiChatsTableOrderingComposer(
              $db: $db,
              $table: $db.aiChats,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$AiChatMessagesTableAnnotationComposer
    extends Composer<_$AppDatabase, $AiChatMessagesTable> {
  $$AiChatMessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get role =>
      $composableBuilder(column: $table.role, builder: (column) => column);

  GeneratedColumn<String> get textContent => $composableBuilder(
      column: $table.textContent, builder: (column) => column);

  GeneratedColumn<String> get contextText => $composableBuilder(
      column: $table.contextText, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get promptTokens => $composableBuilder(
      column: $table.promptTokens, builder: (column) => column);

  GeneratedColumn<int> get completionTokens => $composableBuilder(
      column: $table.completionTokens, builder: (column) => column);

  GeneratedColumn<int> get totalTokens => $composableBuilder(
      column: $table.totalTokens, builder: (column) => column);

  GeneratedColumn<int> get elapsedMs =>
      $composableBuilder(column: $table.elapsedMs, builder: (column) => column);

  GeneratedColumn<bool> get tokenUsageEstimated => $composableBuilder(
      column: $table.tokenUsageEstimated, builder: (column) => column);

  GeneratedColumn<int> get promptCacheHitTokens => $composableBuilder(
      column: $table.promptCacheHitTokens, builder: (column) => column);

  GeneratedColumn<int> get promptCacheMissTokens => $composableBuilder(
      column: $table.promptCacheMissTokens, builder: (column) => column);

  GeneratedColumn<int> get reasoningTokens => $composableBuilder(
      column: $table.reasoningTokens, builder: (column) => column);

  GeneratedColumn<String> get attachmentsJson => $composableBuilder(
      column: $table.attachmentsJson, builder: (column) => column);

  GeneratedColumn<String> get tracesJson => $composableBuilder(
      column: $table.tracesJson, builder: (column) => column);

  GeneratedColumn<String> get todoStepsJson => $composableBuilder(
      column: $table.todoStepsJson, builder: (column) => column);

  $$AiChatsTableAnnotationComposer get chatId {
    final $$AiChatsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.chatId,
        referencedTable: $db.aiChats,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$AiChatsTableAnnotationComposer(
              $db: $db,
              $table: $db.aiChats,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$AiChatMessagesTableTableManager extends RootTableManager<
    _$AppDatabase,
    $AiChatMessagesTable,
    AiChatMessage,
    $$AiChatMessagesTableFilterComposer,
    $$AiChatMessagesTableOrderingComposer,
    $$AiChatMessagesTableAnnotationComposer,
    $$AiChatMessagesTableCreateCompanionBuilder,
    $$AiChatMessagesTableUpdateCompanionBuilder,
    (AiChatMessage, $$AiChatMessagesTableReferences),
    AiChatMessage,
    PrefetchHooks Function({bool chatId})> {
  $$AiChatMessagesTableTableManager(
      _$AppDatabase db, $AiChatMessagesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AiChatMessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AiChatMessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AiChatMessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> chatId = const Value.absent(),
            Value<String> role = const Value.absent(),
            Value<String> textContent = const Value.absent(),
            Value<String?> contextText = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
            Value<int?> promptTokens = const Value.absent(),
            Value<int?> completionTokens = const Value.absent(),
            Value<int?> totalTokens = const Value.absent(),
            Value<int?> elapsedMs = const Value.absent(),
            Value<bool?> tokenUsageEstimated = const Value.absent(),
            Value<int?> promptCacheHitTokens = const Value.absent(),
            Value<int?> promptCacheMissTokens = const Value.absent(),
            Value<int?> reasoningTokens = const Value.absent(),
            Value<String> attachmentsJson = const Value.absent(),
            Value<String> tracesJson = const Value.absent(),
            Value<String> todoStepsJson = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              AiChatMessagesCompanion(
            id: id,
            chatId: chatId,
            role: role,
            textContent: textContent,
            contextText: contextText,
            createdAt: createdAt,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            elapsedMs: elapsedMs,
            tokenUsageEstimated: tokenUsageEstimated,
            promptCacheHitTokens: promptCacheHitTokens,
            promptCacheMissTokens: promptCacheMissTokens,
            reasoningTokens: reasoningTokens,
            attachmentsJson: attachmentsJson,
            tracesJson: tracesJson,
            todoStepsJson: todoStepsJson,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String chatId,
            required String role,
            required String textContent,
            Value<String?> contextText = const Value.absent(),
            required int createdAt,
            Value<int?> promptTokens = const Value.absent(),
            Value<int?> completionTokens = const Value.absent(),
            Value<int?> totalTokens = const Value.absent(),
            Value<int?> elapsedMs = const Value.absent(),
            Value<bool?> tokenUsageEstimated = const Value.absent(),
            Value<int?> promptCacheHitTokens = const Value.absent(),
            Value<int?> promptCacheMissTokens = const Value.absent(),
            Value<int?> reasoningTokens = const Value.absent(),
            Value<String> attachmentsJson = const Value.absent(),
            Value<String> tracesJson = const Value.absent(),
            Value<String> todoStepsJson = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              AiChatMessagesCompanion.insert(
            id: id,
            chatId: chatId,
            role: role,
            textContent: textContent,
            contextText: contextText,
            createdAt: createdAt,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            elapsedMs: elapsedMs,
            tokenUsageEstimated: tokenUsageEstimated,
            promptCacheHitTokens: promptCacheHitTokens,
            promptCacheMissTokens: promptCacheMissTokens,
            reasoningTokens: reasoningTokens,
            attachmentsJson: attachmentsJson,
            tracesJson: tracesJson,
            todoStepsJson: todoStepsJson,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$AiChatMessagesTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({chatId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
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
                      dynamic>>(state) {
                if (chatId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.chatId,
                    referencedTable:
                        $$AiChatMessagesTableReferences._chatIdTable(db),
                    referencedColumn:
                        $$AiChatMessagesTableReferences._chatIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$AiChatMessagesTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $AiChatMessagesTable,
    AiChatMessage,
    $$AiChatMessagesTableFilterComposer,
    $$AiChatMessagesTableOrderingComposer,
    $$AiChatMessagesTableAnnotationComposer,
    $$AiChatMessagesTableCreateCompanionBuilder,
    $$AiChatMessagesTableUpdateCompanionBuilder,
    (AiChatMessage, $$AiChatMessagesTableReferences),
    AiChatMessage,
    PrefetchHooks Function({bool chatId})>;
typedef $$AgentRunMetricsTableTableCreateCompanionBuilder
    = AgentRunMetricsTableCompanion Function({
  required String id,
  required int startedAt,
  required int finishedAt,
  required String model,
  Value<String> helperModel,
  Value<String> auditModel,
  Value<int> promptTokens,
  Value<int> completionTokens,
  Value<int> totalTokens,
  Value<int> elapsedMs,
  Value<int> toolCalls,
  Value<int> cacheHits,
  Value<int> dedupBlockedCalls,
  Value<int> ragHits,
  Value<int> approvalCount,
  Value<int> approvedCount,
  Value<int> auditCount,
  Value<int> helperFanout,
  Value<bool> success,
  Value<String> selectedToolSetJson,
  Value<String> memorySourcesJson,
  Value<int> rowid,
});
typedef $$AgentRunMetricsTableTableUpdateCompanionBuilder
    = AgentRunMetricsTableCompanion Function({
  Value<String> id,
  Value<int> startedAt,
  Value<int> finishedAt,
  Value<String> model,
  Value<String> helperModel,
  Value<String> auditModel,
  Value<int> promptTokens,
  Value<int> completionTokens,
  Value<int> totalTokens,
  Value<int> elapsedMs,
  Value<int> toolCalls,
  Value<int> cacheHits,
  Value<int> dedupBlockedCalls,
  Value<int> ragHits,
  Value<int> approvalCount,
  Value<int> approvedCount,
  Value<int> auditCount,
  Value<int> helperFanout,
  Value<bool> success,
  Value<String> selectedToolSetJson,
  Value<String> memorySourcesJson,
  Value<int> rowid,
});

class $$AgentRunMetricsTableTableFilterComposer
    extends Composer<_$AppDatabase, $AgentRunMetricsTableTable> {
  $$AgentRunMetricsTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get startedAt => $composableBuilder(
      column: $table.startedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get finishedAt => $composableBuilder(
      column: $table.finishedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get model => $composableBuilder(
      column: $table.model, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get helperModel => $composableBuilder(
      column: $table.helperModel, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get auditModel => $composableBuilder(
      column: $table.auditModel, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get promptTokens => $composableBuilder(
      column: $table.promptTokens, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get completionTokens => $composableBuilder(
      column: $table.completionTokens,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get totalTokens => $composableBuilder(
      column: $table.totalTokens, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get elapsedMs => $composableBuilder(
      column: $table.elapsedMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get toolCalls => $composableBuilder(
      column: $table.toolCalls, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get cacheHits => $composableBuilder(
      column: $table.cacheHits, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get dedupBlockedCalls => $composableBuilder(
      column: $table.dedupBlockedCalls,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get ragHits => $composableBuilder(
      column: $table.ragHits, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get approvalCount => $composableBuilder(
      column: $table.approvalCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get approvedCount => $composableBuilder(
      column: $table.approvedCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get auditCount => $composableBuilder(
      column: $table.auditCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get helperFanout => $composableBuilder(
      column: $table.helperFanout, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get success => $composableBuilder(
      column: $table.success, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get selectedToolSetJson => $composableBuilder(
      column: $table.selectedToolSetJson,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get memorySourcesJson => $composableBuilder(
      column: $table.memorySourcesJson,
      builder: (column) => ColumnFilters(column));
}

class $$AgentRunMetricsTableTableOrderingComposer
    extends Composer<_$AppDatabase, $AgentRunMetricsTableTable> {
  $$AgentRunMetricsTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get startedAt => $composableBuilder(
      column: $table.startedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get finishedAt => $composableBuilder(
      column: $table.finishedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get model => $composableBuilder(
      column: $table.model, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get helperModel => $composableBuilder(
      column: $table.helperModel, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get auditModel => $composableBuilder(
      column: $table.auditModel, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get promptTokens => $composableBuilder(
      column: $table.promptTokens,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get completionTokens => $composableBuilder(
      column: $table.completionTokens,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get totalTokens => $composableBuilder(
      column: $table.totalTokens, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get elapsedMs => $composableBuilder(
      column: $table.elapsedMs, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get toolCalls => $composableBuilder(
      column: $table.toolCalls, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get cacheHits => $composableBuilder(
      column: $table.cacheHits, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get dedupBlockedCalls => $composableBuilder(
      column: $table.dedupBlockedCalls,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get ragHits => $composableBuilder(
      column: $table.ragHits, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get approvalCount => $composableBuilder(
      column: $table.approvalCount,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get approvedCount => $composableBuilder(
      column: $table.approvedCount,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get auditCount => $composableBuilder(
      column: $table.auditCount, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get helperFanout => $composableBuilder(
      column: $table.helperFanout,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get success => $composableBuilder(
      column: $table.success, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get selectedToolSetJson => $composableBuilder(
      column: $table.selectedToolSetJson,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get memorySourcesJson => $composableBuilder(
      column: $table.memorySourcesJson,
      builder: (column) => ColumnOrderings(column));
}

class $$AgentRunMetricsTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $AgentRunMetricsTableTable> {
  $$AgentRunMetricsTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get startedAt =>
      $composableBuilder(column: $table.startedAt, builder: (column) => column);

  GeneratedColumn<int> get finishedAt => $composableBuilder(
      column: $table.finishedAt, builder: (column) => column);

  GeneratedColumn<String> get model =>
      $composableBuilder(column: $table.model, builder: (column) => column);

  GeneratedColumn<String> get helperModel => $composableBuilder(
      column: $table.helperModel, builder: (column) => column);

  GeneratedColumn<String> get auditModel => $composableBuilder(
      column: $table.auditModel, builder: (column) => column);

  GeneratedColumn<int> get promptTokens => $composableBuilder(
      column: $table.promptTokens, builder: (column) => column);

  GeneratedColumn<int> get completionTokens => $composableBuilder(
      column: $table.completionTokens, builder: (column) => column);

  GeneratedColumn<int> get totalTokens => $composableBuilder(
      column: $table.totalTokens, builder: (column) => column);

  GeneratedColumn<int> get elapsedMs =>
      $composableBuilder(column: $table.elapsedMs, builder: (column) => column);

  GeneratedColumn<int> get toolCalls =>
      $composableBuilder(column: $table.toolCalls, builder: (column) => column);

  GeneratedColumn<int> get cacheHits =>
      $composableBuilder(column: $table.cacheHits, builder: (column) => column);

  GeneratedColumn<int> get dedupBlockedCalls => $composableBuilder(
      column: $table.dedupBlockedCalls, builder: (column) => column);

  GeneratedColumn<int> get ragHits =>
      $composableBuilder(column: $table.ragHits, builder: (column) => column);

  GeneratedColumn<int> get approvalCount => $composableBuilder(
      column: $table.approvalCount, builder: (column) => column);

  GeneratedColumn<int> get approvedCount => $composableBuilder(
      column: $table.approvedCount, builder: (column) => column);

  GeneratedColumn<int> get auditCount => $composableBuilder(
      column: $table.auditCount, builder: (column) => column);

  GeneratedColumn<int> get helperFanout => $composableBuilder(
      column: $table.helperFanout, builder: (column) => column);

  GeneratedColumn<bool> get success =>
      $composableBuilder(column: $table.success, builder: (column) => column);

  GeneratedColumn<String> get selectedToolSetJson => $composableBuilder(
      column: $table.selectedToolSetJson, builder: (column) => column);

  GeneratedColumn<String> get memorySourcesJson => $composableBuilder(
      column: $table.memorySourcesJson, builder: (column) => column);
}

class $$AgentRunMetricsTableTableTableManager extends RootTableManager<
    _$AppDatabase,
    $AgentRunMetricsTableTable,
    AgentRunMetricRow,
    $$AgentRunMetricsTableTableFilterComposer,
    $$AgentRunMetricsTableTableOrderingComposer,
    $$AgentRunMetricsTableTableAnnotationComposer,
    $$AgentRunMetricsTableTableCreateCompanionBuilder,
    $$AgentRunMetricsTableTableUpdateCompanionBuilder,
    (
      AgentRunMetricRow,
      BaseReferences<_$AppDatabase, $AgentRunMetricsTableTable,
          AgentRunMetricRow>
    ),
    AgentRunMetricRow,
    PrefetchHooks Function()> {
  $$AgentRunMetricsTableTableTableManager(
      _$AppDatabase db, $AgentRunMetricsTableTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AgentRunMetricsTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AgentRunMetricsTableTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AgentRunMetricsTableTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<int> startedAt = const Value.absent(),
            Value<int> finishedAt = const Value.absent(),
            Value<String> model = const Value.absent(),
            Value<String> helperModel = const Value.absent(),
            Value<String> auditModel = const Value.absent(),
            Value<int> promptTokens = const Value.absent(),
            Value<int> completionTokens = const Value.absent(),
            Value<int> totalTokens = const Value.absent(),
            Value<int> elapsedMs = const Value.absent(),
            Value<int> toolCalls = const Value.absent(),
            Value<int> cacheHits = const Value.absent(),
            Value<int> dedupBlockedCalls = const Value.absent(),
            Value<int> ragHits = const Value.absent(),
            Value<int> approvalCount = const Value.absent(),
            Value<int> approvedCount = const Value.absent(),
            Value<int> auditCount = const Value.absent(),
            Value<int> helperFanout = const Value.absent(),
            Value<bool> success = const Value.absent(),
            Value<String> selectedToolSetJson = const Value.absent(),
            Value<String> memorySourcesJson = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              AgentRunMetricsTableCompanion(
            id: id,
            startedAt: startedAt,
            finishedAt: finishedAt,
            model: model,
            helperModel: helperModel,
            auditModel: auditModel,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            elapsedMs: elapsedMs,
            toolCalls: toolCalls,
            cacheHits: cacheHits,
            dedupBlockedCalls: dedupBlockedCalls,
            ragHits: ragHits,
            approvalCount: approvalCount,
            approvedCount: approvedCount,
            auditCount: auditCount,
            helperFanout: helperFanout,
            success: success,
            selectedToolSetJson: selectedToolSetJson,
            memorySourcesJson: memorySourcesJson,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required int startedAt,
            required int finishedAt,
            required String model,
            Value<String> helperModel = const Value.absent(),
            Value<String> auditModel = const Value.absent(),
            Value<int> promptTokens = const Value.absent(),
            Value<int> completionTokens = const Value.absent(),
            Value<int> totalTokens = const Value.absent(),
            Value<int> elapsedMs = const Value.absent(),
            Value<int> toolCalls = const Value.absent(),
            Value<int> cacheHits = const Value.absent(),
            Value<int> dedupBlockedCalls = const Value.absent(),
            Value<int> ragHits = const Value.absent(),
            Value<int> approvalCount = const Value.absent(),
            Value<int> approvedCount = const Value.absent(),
            Value<int> auditCount = const Value.absent(),
            Value<int> helperFanout = const Value.absent(),
            Value<bool> success = const Value.absent(),
            Value<String> selectedToolSetJson = const Value.absent(),
            Value<String> memorySourcesJson = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              AgentRunMetricsTableCompanion.insert(
            id: id,
            startedAt: startedAt,
            finishedAt: finishedAt,
            model: model,
            helperModel: helperModel,
            auditModel: auditModel,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            elapsedMs: elapsedMs,
            toolCalls: toolCalls,
            cacheHits: cacheHits,
            dedupBlockedCalls: dedupBlockedCalls,
            ragHits: ragHits,
            approvalCount: approvalCount,
            approvedCount: approvedCount,
            auditCount: auditCount,
            helperFanout: helperFanout,
            success: success,
            selectedToolSetJson: selectedToolSetJson,
            memorySourcesJson: memorySourcesJson,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$AgentRunMetricsTableTableProcessedTableManager
    = ProcessedTableManager<
        _$AppDatabase,
        $AgentRunMetricsTableTable,
        AgentRunMetricRow,
        $$AgentRunMetricsTableTableFilterComposer,
        $$AgentRunMetricsTableTableOrderingComposer,
        $$AgentRunMetricsTableTableAnnotationComposer,
        $$AgentRunMetricsTableTableCreateCompanionBuilder,
        $$AgentRunMetricsTableTableUpdateCompanionBuilder,
        (
          AgentRunMetricRow,
          BaseReferences<_$AppDatabase, $AgentRunMetricsTableTable,
              AgentRunMetricRow>
        ),
        AgentRunMetricRow,
        PrefetchHooks Function()>;
typedef $$TerminalHistoryRecordsTableCreateCompanionBuilder
    = TerminalHistoryRecordsCompanion Function({
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
typedef $$TerminalHistoryRecordsTableUpdateCompanionBuilder
    = TerminalHistoryRecordsCompanion Function({
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
      column: $table.sessionId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get connectionId => $composableBuilder(
      column: $table.connectionId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get connectionName => $composableBuilder(
      column: $table.connectionName,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get displayName => $composableBuilder(
      column: $table.displayName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get tmuxSessionName => $composableBuilder(
      column: $table.tmuxSessionName,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get state => $composableBuilder(
      column: $table.state, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get errorMessage => $composableBuilder(
      column: $table.errorMessage, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
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
      column: $table.sessionId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get connectionId => $composableBuilder(
      column: $table.connectionId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get connectionName => $composableBuilder(
      column: $table.connectionName,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get displayName => $composableBuilder(
      column: $table.displayName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get tmuxSessionName => $composableBuilder(
      column: $table.tmuxSessionName,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get state => $composableBuilder(
      column: $table.state, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get errorMessage => $composableBuilder(
      column: $table.errorMessage,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
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
      column: $table.connectionId, builder: (column) => column);

  GeneratedColumn<String> get connectionName => $composableBuilder(
      column: $table.connectionName, builder: (column) => column);

  GeneratedColumn<String> get displayName => $composableBuilder(
      column: $table.displayName, builder: (column) => column);

  GeneratedColumn<String> get tmuxSessionName => $composableBuilder(
      column: $table.tmuxSessionName, builder: (column) => column);

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<String> get errorMessage => $composableBuilder(
      column: $table.errorMessage, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$TerminalHistoryRecordsTableTableManager extends RootTableManager<
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
      BaseReferences<_$AppDatabase, $TerminalHistoryRecordsTable,
          TerminalHistoryRecord>
    ),
    TerminalHistoryRecord,
    PrefetchHooks Function()> {
  $$TerminalHistoryRecordsTableTableManager(
      _$AppDatabase db, $TerminalHistoryRecordsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TerminalHistoryRecordsTableFilterComposer(
                  $db: db, $table: table),
          createOrderingComposer: () =>
              $$TerminalHistoryRecordsTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TerminalHistoryRecordsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
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
          }) =>
              TerminalHistoryRecordsCompanion(
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
          createCompanionCallback: ({
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
          }) =>
              TerminalHistoryRecordsCompanion.insert(
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
        ));
}

typedef $$TerminalHistoryRecordsTableProcessedTableManager
    = ProcessedTableManager<
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
          BaseReferences<_$AppDatabase, $TerminalHistoryRecordsTable,
              TerminalHistoryRecord>
        ),
        TerminalHistoryRecord,
        PrefetchHooks Function()>;
typedef $$PlaybooksTableCreateCompanionBuilder = PlaybooksCompanion Function({
  required String id,
  required String name,
  Value<String> description,
  required String contentJson,
  required int createdAt,
  required int updatedAt,
  Value<int> rowid,
});
typedef $$PlaybooksTableUpdateCompanionBuilder = PlaybooksCompanion Function({
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
      _playbookRunsRefsTable(_$AppDatabase db) =>
          MultiTypedResultKey.fromTable(db.playbookRuns,
              aliasName: 'playbooks__id__playbook_runs__playbook_id');

  $$PlaybookRunsTableProcessedTableManager get playbookRunsRefs {
    final manager = $$PlaybookRunsTableTableManager($_db, $_db.playbookRuns)
        .filter((f) => f.playbookId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_playbookRunsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
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
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get description => $composableBuilder(
      column: $table.description, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get contentJson => $composableBuilder(
      column: $table.contentJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  Expression<bool> playbookRunsRefs(
      Expression<bool> Function($$PlaybookRunsTableFilterComposer f) f) {
    final $$PlaybookRunsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.playbookRuns,
        getReferencedColumn: (t) => t.playbookId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlaybookRunsTableFilterComposer(
              $db: $db,
              $table: $db.playbookRuns,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
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
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get description => $composableBuilder(
      column: $table.description, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get contentJson => $composableBuilder(
      column: $table.contentJson, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
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
      column: $table.description, builder: (column) => column);

  GeneratedColumn<String> get contentJson => $composableBuilder(
      column: $table.contentJson, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  Expression<T> playbookRunsRefs<T extends Object>(
      Expression<T> Function($$PlaybookRunsTableAnnotationComposer a) f) {
    final $$PlaybookRunsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.playbookRuns,
        getReferencedColumn: (t) => t.playbookId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlaybookRunsTableAnnotationComposer(
              $db: $db,
              $table: $db.playbookRuns,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$PlaybooksTableTableManager extends RootTableManager<
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
    PrefetchHooks Function({bool playbookRunsRefs})> {
  $$PlaybooksTableTableManager(_$AppDatabase db, $PlaybooksTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlaybooksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlaybooksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlaybooksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<String> description = const Value.absent(),
            Value<String> contentJson = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
            Value<int> updatedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              PlaybooksCompanion(
            id: id,
            name: name,
            description: description,
            contentJson: contentJson,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String name,
            Value<String> description = const Value.absent(),
            required String contentJson,
            required int createdAt,
            required int updatedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              PlaybooksCompanion.insert(
            id: id,
            name: name,
            description: description,
            contentJson: contentJson,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$PlaybooksTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({playbookRunsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (playbookRunsRefs) db.playbookRuns],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (playbookRunsRefs)
                    await $_getPrefetchedData<Playbook, $PlaybooksTable,
                            PlaybookRun>(
                        currentTable: table,
                        referencedTable: $$PlaybooksTableReferences
                            ._playbookRunsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$PlaybooksTableReferences(db, table, p0)
                                .playbookRunsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.playbookId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$PlaybooksTableProcessedTableManager = ProcessedTableManager<
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
    PrefetchHooks Function({bool playbookRunsRefs})>;
typedef $$PlaybookRunsTableCreateCompanionBuilder = PlaybookRunsCompanion
    Function({
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
typedef $$PlaybookRunsTableUpdateCompanionBuilder = PlaybookRunsCompanion
    Function({
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

    final manager = $$PlaybooksTableTableManager($_db, $_db.playbooks)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_playbookIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static MultiTypedResultKey<$PlaybookRunStepsTable, List<PlaybookRunStep>>
      _playbookRunStepsRefsTable(_$AppDatabase db) =>
          MultiTypedResultKey.fromTable(db.playbookRunSteps,
              aliasName: 'playbook_runs__id__playbook_run_steps__run_id');

  $$PlaybookRunStepsTableProcessedTableManager get playbookRunStepsRefs {
    final manager =
        $$PlaybookRunStepsTableTableManager($_db, $_db.playbookRunSteps)
            .filter((f) => f.runId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache =
        $_typedResult.readTableOrNull(_playbookRunStepsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
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
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get connectionId => $composableBuilder(
      column: $table.connectionId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get startedAt => $composableBuilder(
      column: $table.startedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get finishedAt => $composableBuilder(
      column: $table.finishedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get summary => $composableBuilder(
      column: $table.summary, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get errorMessage => $composableBuilder(
      column: $table.errorMessage, builder: (column) => ColumnFilters(column));

  $$PlaybooksTableFilterComposer get playbookId {
    final $$PlaybooksTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.playbookId,
        referencedTable: $db.playbooks,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlaybooksTableFilterComposer(
              $db: $db,
              $table: $db.playbooks,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  Expression<bool> playbookRunStepsRefs(
      Expression<bool> Function($$PlaybookRunStepsTableFilterComposer f) f) {
    final $$PlaybookRunStepsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.playbookRunSteps,
        getReferencedColumn: (t) => t.runId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlaybookRunStepsTableFilterComposer(
              $db: $db,
              $table: $db.playbookRunSteps,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
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
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get connectionId => $composableBuilder(
      column: $table.connectionId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get startedAt => $composableBuilder(
      column: $table.startedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get finishedAt => $composableBuilder(
      column: $table.finishedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get summary => $composableBuilder(
      column: $table.summary, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get errorMessage => $composableBuilder(
      column: $table.errorMessage,
      builder: (column) => ColumnOrderings(column));

  $$PlaybooksTableOrderingComposer get playbookId {
    final $$PlaybooksTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.playbookId,
        referencedTable: $db.playbooks,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlaybooksTableOrderingComposer(
              $db: $db,
              $table: $db.playbooks,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
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
      column: $table.connectionId, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get startedAt =>
      $composableBuilder(column: $table.startedAt, builder: (column) => column);

  GeneratedColumn<int> get finishedAt => $composableBuilder(
      column: $table.finishedAt, builder: (column) => column);

  GeneratedColumn<String> get summary =>
      $composableBuilder(column: $table.summary, builder: (column) => column);

  GeneratedColumn<String> get errorMessage => $composableBuilder(
      column: $table.errorMessage, builder: (column) => column);

  $$PlaybooksTableAnnotationComposer get playbookId {
    final $$PlaybooksTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.playbookId,
        referencedTable: $db.playbooks,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlaybooksTableAnnotationComposer(
              $db: $db,
              $table: $db.playbooks,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  Expression<T> playbookRunStepsRefs<T extends Object>(
      Expression<T> Function($$PlaybookRunStepsTableAnnotationComposer a) f) {
    final $$PlaybookRunStepsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.playbookRunSteps,
        getReferencedColumn: (t) => t.runId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlaybookRunStepsTableAnnotationComposer(
              $db: $db,
              $table: $db.playbookRunSteps,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$PlaybookRunsTableTableManager extends RootTableManager<
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
    PrefetchHooks Function({bool playbookId, bool playbookRunStepsRefs})> {
  $$PlaybookRunsTableTableManager(_$AppDatabase db, $PlaybookRunsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlaybookRunsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlaybookRunsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlaybookRunsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> playbookId = const Value.absent(),
            Value<String?> connectionId = const Value.absent(),
            Value<String> status = const Value.absent(),
            Value<int> startedAt = const Value.absent(),
            Value<int?> finishedAt = const Value.absent(),
            Value<String> summary = const Value.absent(),
            Value<String?> errorMessage = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              PlaybookRunsCompanion(
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
          createCompanionCallback: ({
            required String id,
            required String playbookId,
            Value<String?> connectionId = const Value.absent(),
            required String status,
            required int startedAt,
            Value<int?> finishedAt = const Value.absent(),
            Value<String> summary = const Value.absent(),
            Value<String?> errorMessage = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              PlaybookRunsCompanion.insert(
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
              .map((e) => (
                    e.readTable(table),
                    $$PlaybookRunsTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: (
              {playbookId = false, playbookRunStepsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (playbookRunStepsRefs) db.playbookRunSteps
              ],
              addJoins: <
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
                      dynamic>>(state) {
                if (playbookId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.playbookId,
                    referencedTable:
                        $$PlaybookRunsTableReferences._playbookIdTable(db),
                    referencedColumn:
                        $$PlaybookRunsTableReferences._playbookIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [
                  if (playbookRunStepsRefs)
                    await $_getPrefetchedData<PlaybookRun, $PlaybookRunsTable,
                            PlaybookRunStep>(
                        currentTable: table,
                        referencedTable: $$PlaybookRunsTableReferences
                            ._playbookRunStepsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$PlaybookRunsTableReferences(db, table, p0)
                                .playbookRunStepsRefs,
                        referencedItemsForCurrentItem: (item,
                                referencedItems) =>
                            referencedItems.where((e) => e.runId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$PlaybookRunsTableProcessedTableManager = ProcessedTableManager<
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
    PrefetchHooks Function({bool playbookId, bool playbookRunStepsRefs})>;
typedef $$PlaybookRunStepsTableCreateCompanionBuilder
    = PlaybookRunStepsCompanion Function({
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
typedef $$PlaybookRunStepsTableUpdateCompanionBuilder
    = PlaybookRunStepsCompanion Function({
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

final class $$PlaybookRunStepsTableReferences extends BaseReferences<
    _$AppDatabase, $PlaybookRunStepsTable, PlaybookRunStep> {
  $$PlaybookRunStepsTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $PlaybookRunsTable _runIdTable(_$AppDatabase db) => db.playbookRuns
      .createAlias('playbook_run_steps__run_id__playbook_runs__id');

  $$PlaybookRunsTableProcessedTableManager get runId {
    final $_column = $_itemColumn<String>('run_id')!;

    final manager = $$PlaybookRunsTableTableManager($_db, $_db.playbookRuns)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_runIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
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
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get stepIndex => $composableBuilder(
      column: $table.stepIndex, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get command => $composableBuilder(
      column: $table.command, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get stdoutPreview => $composableBuilder(
      column: $table.stdoutPreview, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get stderrPreview => $composableBuilder(
      column: $table.stderrPreview, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get exitCode => $composableBuilder(
      column: $table.exitCode, builder: (column) => ColumnFilters(column));

  $$PlaybookRunsTableFilterComposer get runId {
    final $$PlaybookRunsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.runId,
        referencedTable: $db.playbookRuns,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlaybookRunsTableFilterComposer(
              $db: $db,
              $table: $db.playbookRuns,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
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
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get stepIndex => $composableBuilder(
      column: $table.stepIndex, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get command => $composableBuilder(
      column: $table.command, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get stdoutPreview => $composableBuilder(
      column: $table.stdoutPreview,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get stderrPreview => $composableBuilder(
      column: $table.stderrPreview,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get exitCode => $composableBuilder(
      column: $table.exitCode, builder: (column) => ColumnOrderings(column));

  $$PlaybookRunsTableOrderingComposer get runId {
    final $$PlaybookRunsTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.runId,
        referencedTable: $db.playbookRuns,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlaybookRunsTableOrderingComposer(
              $db: $db,
              $table: $db.playbookRuns,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
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
      column: $table.stdoutPreview, builder: (column) => column);

  GeneratedColumn<String> get stderrPreview => $composableBuilder(
      column: $table.stderrPreview, builder: (column) => column);

  GeneratedColumn<int> get exitCode =>
      $composableBuilder(column: $table.exitCode, builder: (column) => column);

  $$PlaybookRunsTableAnnotationComposer get runId {
    final $$PlaybookRunsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.runId,
        referencedTable: $db.playbookRuns,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlaybookRunsTableAnnotationComposer(
              $db: $db,
              $table: $db.playbookRuns,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$PlaybookRunStepsTableTableManager extends RootTableManager<
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
    PrefetchHooks Function({bool runId})> {
  $$PlaybookRunStepsTableTableManager(
      _$AppDatabase db, $PlaybookRunStepsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlaybookRunStepsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlaybookRunStepsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlaybookRunStepsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
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
          }) =>
              PlaybookRunStepsCompanion(
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
          createCompanionCallback: ({
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
          }) =>
              PlaybookRunStepsCompanion.insert(
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
              .map((e) => (
                    e.readTable(table),
                    $$PlaybookRunStepsTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({runId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
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
                      dynamic>>(state) {
                if (runId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.runId,
                    referencedTable:
                        $$PlaybookRunStepsTableReferences._runIdTable(db),
                    referencedColumn:
                        $$PlaybookRunStepsTableReferences._runIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$PlaybookRunStepsTableProcessedTableManager = ProcessedTableManager<
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
    PrefetchHooks Function({bool runId})>;
typedef $$SftpRecentPathsTableCreateCompanionBuilder = SftpRecentPathsCompanion
    Function({
  required String id,
  required String connectionId,
  required String path,
  required int visitedAt,
  Value<int> rowid,
});
typedef $$SftpRecentPathsTableUpdateCompanionBuilder = SftpRecentPathsCompanion
    Function({
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
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get connectionId => $composableBuilder(
      column: $table.connectionId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get path => $composableBuilder(
      column: $table.path, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get visitedAt => $composableBuilder(
      column: $table.visitedAt, builder: (column) => ColumnFilters(column));
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
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get connectionId => $composableBuilder(
      column: $table.connectionId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get path => $composableBuilder(
      column: $table.path, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get visitedAt => $composableBuilder(
      column: $table.visitedAt, builder: (column) => ColumnOrderings(column));
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
      column: $table.connectionId, builder: (column) => column);

  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<int> get visitedAt =>
      $composableBuilder(column: $table.visitedAt, builder: (column) => column);
}

class $$SftpRecentPathsTableTableManager extends RootTableManager<
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
      BaseReferences<_$AppDatabase, $SftpRecentPathsTable, SftpRecentPath>
    ),
    SftpRecentPath,
    PrefetchHooks Function()> {
  $$SftpRecentPathsTableTableManager(
      _$AppDatabase db, $SftpRecentPathsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SftpRecentPathsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SftpRecentPathsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SftpRecentPathsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> connectionId = const Value.absent(),
            Value<String> path = const Value.absent(),
            Value<int> visitedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SftpRecentPathsCompanion(
            id: id,
            connectionId: connectionId,
            path: path,
            visitedAt: visitedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String connectionId,
            required String path,
            required int visitedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              SftpRecentPathsCompanion.insert(
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
        ));
}

typedef $$SftpRecentPathsTableProcessedTableManager = ProcessedTableManager<
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
      BaseReferences<_$AppDatabase, $SftpRecentPathsTable, SftpRecentPath>
    ),
    SftpRecentPath,
    PrefetchHooks Function()>;
typedef $$SftpFavoritePathsTableCreateCompanionBuilder
    = SftpFavoritePathsCompanion Function({
  required String id,
  required String connectionId,
  required String path,
  required String name,
  required int createdAt,
  required int updatedAt,
  Value<int> rowid,
});
typedef $$SftpFavoritePathsTableUpdateCompanionBuilder
    = SftpFavoritePathsCompanion Function({
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
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get connectionId => $composableBuilder(
      column: $table.connectionId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get path => $composableBuilder(
      column: $table.path, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
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
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get connectionId => $composableBuilder(
      column: $table.connectionId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get path => $composableBuilder(
      column: $table.path, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
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
      column: $table.connectionId, builder: (column) => column);

  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$SftpFavoritePathsTableTableManager extends RootTableManager<
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
      BaseReferences<_$AppDatabase, $SftpFavoritePathsTable, SftpFavoritePath>
    ),
    SftpFavoritePath,
    PrefetchHooks Function()> {
  $$SftpFavoritePathsTableTableManager(
      _$AppDatabase db, $SftpFavoritePathsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SftpFavoritePathsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SftpFavoritePathsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SftpFavoritePathsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> connectionId = const Value.absent(),
            Value<String> path = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
            Value<int> updatedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SftpFavoritePathsCompanion(
            id: id,
            connectionId: connectionId,
            path: path,
            name: name,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String connectionId,
            required String path,
            required String name,
            required int createdAt,
            required int updatedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              SftpFavoritePathsCompanion.insert(
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
        ));
}

typedef $$SftpFavoritePathsTableProcessedTableManager = ProcessedTableManager<
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
      BaseReferences<_$AppDatabase, $SftpFavoritePathsTable, SftpFavoritePath>
    ),
    SftpFavoritePath,
    PrefetchHooks Function()>;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$MigrationMetaTableTableManager get migrationMeta =>
      $$MigrationMetaTableTableManager(_db, _db.migrationMeta);
  $$AiChatsTableTableManager get aiChats =>
      $$AiChatsTableTableManager(_db, _db.aiChats);
  $$AiChatMessagesTableTableManager get aiChatMessages =>
      $$AiChatMessagesTableTableManager(_db, _db.aiChatMessages);
  $$AgentRunMetricsTableTableTableManager get agentRunMetricsTable =>
      $$AgentRunMetricsTableTableTableManager(_db, _db.agentRunMetricsTable);
  $$TerminalHistoryRecordsTableTableManager get terminalHistoryRecords =>
      $$TerminalHistoryRecordsTableTableManager(
          _db, _db.terminalHistoryRecords);
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
}

mixin _$MigrationMetaDaoMixin on DatabaseAccessor<AppDatabase> {
  $MigrationMetaTable get migrationMeta => attachedDatabase.migrationMeta;
  MigrationMetaDaoManager get managers => MigrationMetaDaoManager(this);
}

class MigrationMetaDaoManager {
  final _$MigrationMetaDaoMixin _db;
  MigrationMetaDaoManager(this._db);
  $$MigrationMetaTableTableManager get migrationMeta =>
      $$MigrationMetaTableTableManager(_db.attachedDatabase, _db.migrationMeta);
}

mixin _$AiChatDaoMixin on DatabaseAccessor<AppDatabase> {
  $AiChatsTable get aiChats => attachedDatabase.aiChats;
  $AiChatMessagesTable get aiChatMessages => attachedDatabase.aiChatMessages;
  AiChatDaoManager get managers => AiChatDaoManager(this);
}

class AiChatDaoManager {
  final _$AiChatDaoMixin _db;
  AiChatDaoManager(this._db);
  $$AiChatsTableTableManager get aiChats =>
      $$AiChatsTableTableManager(_db.attachedDatabase, _db.aiChats);
  $$AiChatMessagesTableTableManager get aiChatMessages =>
      $$AiChatMessagesTableTableManager(
          _db.attachedDatabase, _db.aiChatMessages);
}

mixin _$AgentMetricsDaoMixin on DatabaseAccessor<AppDatabase> {
  $AgentRunMetricsTableTable get agentRunMetricsTable =>
      attachedDatabase.agentRunMetricsTable;
  AgentMetricsDaoManager get managers => AgentMetricsDaoManager(this);
}

class AgentMetricsDaoManager {
  final _$AgentMetricsDaoMixin _db;
  AgentMetricsDaoManager(this._db);
  $$AgentRunMetricsTableTableTableManager get agentRunMetricsTable =>
      $$AgentRunMetricsTableTableTableManager(
          _db.attachedDatabase, _db.agentRunMetricsTable);
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
          _db.attachedDatabase, _db.terminalHistoryRecords);
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
          _db.attachedDatabase, _db.playbookRunSteps);
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
          _db.attachedDatabase, _db.sftpRecentPaths);
  $$SftpFavoritePathsTableTableManager get sftpFavoritePaths =>
      $$SftpFavoritePathsTableTableManager(
          _db.attachedDatabase, _db.sftpFavoritePaths);
}
