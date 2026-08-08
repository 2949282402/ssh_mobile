// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ai_database.dart';

// ignore_for_file: type=lint
class $AiChatsTable extends AiChats with TableInfo<$AiChatsTable, AiChat> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AiChatsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _modelMeta = const VerificationMeta('model');
  @override
  late final GeneratedColumn<String> model = GeneratedColumn<String>(
    'model',
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
  static const VerificationMeta _planModeMeta = const VerificationMeta(
    'planMode',
  );
  @override
  late final GeneratedColumn<bool> planMode = GeneratedColumn<bool>(
    'plan_mode',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("plan_mode" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _approvedPlanAssistantCreatedAtMeta =
      const VerificationMeta('approvedPlanAssistantCreatedAt');
  @override
  late final GeneratedColumn<int> approvedPlanAssistantCreatedAt =
      GeneratedColumn<int>(
        'approved_plan_assistant_created_at',
        aliasedName,
        true,
        type: DriftSqlType.int,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _approvedPlanApprovedAtMeta =
      const VerificationMeta('approvedPlanApprovedAt');
  @override
  late final GeneratedColumn<int> approvedPlanApprovedAt = GeneratedColumn<int>(
    'approved_plan_approved_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    model,
    createdAt,
    updatedAt,
    planMode,
    approvedPlanAssistantCreatedAt,
    approvedPlanApprovedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ai_chats';
  @override
  VerificationContext validateIntegrity(
    Insertable<AiChat> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('model')) {
      context.handle(
        _modelMeta,
        model.isAcceptableOrUnknown(data['model']!, _modelMeta),
      );
    } else if (isInserting) {
      context.missing(_modelMeta);
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
    if (data.containsKey('plan_mode')) {
      context.handle(
        _planModeMeta,
        planMode.isAcceptableOrUnknown(data['plan_mode']!, _planModeMeta),
      );
    }
    if (data.containsKey('approved_plan_assistant_created_at')) {
      context.handle(
        _approvedPlanAssistantCreatedAtMeta,
        approvedPlanAssistantCreatedAt.isAcceptableOrUnknown(
          data['approved_plan_assistant_created_at']!,
          _approvedPlanAssistantCreatedAtMeta,
        ),
      );
    }
    if (data.containsKey('approved_plan_approved_at')) {
      context.handle(
        _approvedPlanApprovedAtMeta,
        approvedPlanApprovedAt.isAcceptableOrUnknown(
          data['approved_plan_approved_at']!,
          _approvedPlanApprovedAtMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AiChat map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AiChat(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      model: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}model'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      planMode: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}plan_mode'],
      )!,
      approvedPlanAssistantCreatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}approved_plan_assistant_created_at'],
      ),
      approvedPlanApprovedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}approved_plan_approved_at'],
      ),
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
  const AiChat({
    required this.id,
    required this.title,
    required this.model,
    required this.createdAt,
    required this.updatedAt,
    required this.planMode,
    this.approvedPlanAssistantCreatedAt,
    this.approvedPlanApprovedAt,
  });
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
      map['approved_plan_assistant_created_at'] = Variable<int>(
        approvedPlanAssistantCreatedAt,
      );
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

  factory AiChat.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AiChat(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      model: serializer.fromJson<String>(json['model']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      planMode: serializer.fromJson<bool>(json['planMode']),
      approvedPlanAssistantCreatedAt: serializer.fromJson<int?>(
        json['approvedPlanAssistantCreatedAt'],
      ),
      approvedPlanApprovedAt: serializer.fromJson<int?>(
        json['approvedPlanApprovedAt'],
      ),
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
      'approvedPlanAssistantCreatedAt': serializer.toJson<int?>(
        approvedPlanAssistantCreatedAt,
      ),
      'approvedPlanApprovedAt': serializer.toJson<int?>(approvedPlanApprovedAt),
    };
  }

  AiChat copyWith({
    String? id,
    String? title,
    String? model,
    int? createdAt,
    int? updatedAt,
    bool? planMode,
    Value<int?> approvedPlanAssistantCreatedAt = const Value.absent(),
    Value<int?> approvedPlanApprovedAt = const Value.absent(),
  }) => AiChat(
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
            'approvedPlanAssistantCreatedAt: $approvedPlanAssistantCreatedAt, ',
          )
          ..write('approvedPlanApprovedAt: $approvedPlanApprovedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    model,
    createdAt,
    updatedAt,
    planMode,
    approvedPlanAssistantCreatedAt,
    approvedPlanApprovedAt,
  );
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
  }) : id = Value(id),
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

  AiChatsCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<String>? model,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<bool>? planMode,
    Value<int?>? approvedPlanAssistantCreatedAt,
    Value<int?>? approvedPlanApprovedAt,
    Value<int>? rowid,
  }) {
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
      map['approved_plan_assistant_created_at'] = Variable<int>(
        approvedPlanAssistantCreatedAt.value,
      );
    }
    if (approvedPlanApprovedAt.present) {
      map['approved_plan_approved_at'] = Variable<int>(
        approvedPlanApprovedAt.value,
      );
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
            'approvedPlanAssistantCreatedAt: $approvedPlanAssistantCreatedAt, ',
          )
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
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _chatIdMeta = const VerificationMeta('chatId');
  @override
  late final GeneratedColumn<String> chatId = GeneratedColumn<String>(
    'chat_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES ai_chats (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _roleMeta = const VerificationMeta('role');
  @override
  late final GeneratedColumn<String> role = GeneratedColumn<String>(
    'role',
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
    'text',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contextTextMeta = const VerificationMeta(
    'contextText',
  );
  @override
  late final GeneratedColumn<String> contextText = GeneratedColumn<String>(
    'context_text',
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
  static const VerificationMeta _promptTokensMeta = const VerificationMeta(
    'promptTokens',
  );
  @override
  late final GeneratedColumn<int> promptTokens = GeneratedColumn<int>(
    'prompt_tokens',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _completionTokensMeta = const VerificationMeta(
    'completionTokens',
  );
  @override
  late final GeneratedColumn<int> completionTokens = GeneratedColumn<int>(
    'completion_tokens',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _totalTokensMeta = const VerificationMeta(
    'totalTokens',
  );
  @override
  late final GeneratedColumn<int> totalTokens = GeneratedColumn<int>(
    'total_tokens',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _elapsedMsMeta = const VerificationMeta(
    'elapsedMs',
  );
  @override
  late final GeneratedColumn<int> elapsedMs = GeneratedColumn<int>(
    'elapsed_ms',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _tokenUsageEstimatedMeta =
      const VerificationMeta('tokenUsageEstimated');
  @override
  late final GeneratedColumn<bool> tokenUsageEstimated = GeneratedColumn<bool>(
    'token_usage_estimated',
    aliasedName,
    true,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("token_usage_estimated" IN (0, 1))',
    ),
  );
  static const VerificationMeta _promptCacheHitTokensMeta =
      const VerificationMeta('promptCacheHitTokens');
  @override
  late final GeneratedColumn<int> promptCacheHitTokens = GeneratedColumn<int>(
    'prompt_cache_hit_tokens',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _promptCacheMissTokensMeta =
      const VerificationMeta('promptCacheMissTokens');
  @override
  late final GeneratedColumn<int> promptCacheMissTokens = GeneratedColumn<int>(
    'prompt_cache_miss_tokens',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _reasoningTokensMeta = const VerificationMeta(
    'reasoningTokens',
  );
  @override
  late final GeneratedColumn<int> reasoningTokens = GeneratedColumn<int>(
    'reasoning_tokens',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _agentRunIdMeta = const VerificationMeta(
    'agentRunId',
  );
  @override
  late final GeneratedColumn<String> agentRunId = GeneratedColumn<String>(
    'agent_run_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _attachmentsJsonMeta = const VerificationMeta(
    'attachmentsJson',
  );
  @override
  late final GeneratedColumn<String> attachmentsJson = GeneratedColumn<String>(
    'attachments_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _tracesJsonMeta = const VerificationMeta(
    'tracesJson',
  );
  @override
  late final GeneratedColumn<String> tracesJson = GeneratedColumn<String>(
    'traces_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _todoStepsJsonMeta = const VerificationMeta(
    'todoStepsJson',
  );
  @override
  late final GeneratedColumn<String> todoStepsJson = GeneratedColumn<String>(
    'todo_steps_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
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
    agentRunId,
    attachmentsJson,
    tracesJson,
    todoStepsJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ai_chat_messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<AiChatMessage> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('chat_id')) {
      context.handle(
        _chatIdMeta,
        chatId.isAcceptableOrUnknown(data['chat_id']!, _chatIdMeta),
      );
    } else if (isInserting) {
      context.missing(_chatIdMeta);
    }
    if (data.containsKey('role')) {
      context.handle(
        _roleMeta,
        role.isAcceptableOrUnknown(data['role']!, _roleMeta),
      );
    } else if (isInserting) {
      context.missing(_roleMeta);
    }
    if (data.containsKey('text')) {
      context.handle(
        _textContentMeta,
        textContent.isAcceptableOrUnknown(data['text']!, _textContentMeta),
      );
    } else if (isInserting) {
      context.missing(_textContentMeta);
    }
    if (data.containsKey('context_text')) {
      context.handle(
        _contextTextMeta,
        contextText.isAcceptableOrUnknown(
          data['context_text']!,
          _contextTextMeta,
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
    if (data.containsKey('prompt_tokens')) {
      context.handle(
        _promptTokensMeta,
        promptTokens.isAcceptableOrUnknown(
          data['prompt_tokens']!,
          _promptTokensMeta,
        ),
      );
    }
    if (data.containsKey('completion_tokens')) {
      context.handle(
        _completionTokensMeta,
        completionTokens.isAcceptableOrUnknown(
          data['completion_tokens']!,
          _completionTokensMeta,
        ),
      );
    }
    if (data.containsKey('total_tokens')) {
      context.handle(
        _totalTokensMeta,
        totalTokens.isAcceptableOrUnknown(
          data['total_tokens']!,
          _totalTokensMeta,
        ),
      );
    }
    if (data.containsKey('elapsed_ms')) {
      context.handle(
        _elapsedMsMeta,
        elapsedMs.isAcceptableOrUnknown(data['elapsed_ms']!, _elapsedMsMeta),
      );
    }
    if (data.containsKey('token_usage_estimated')) {
      context.handle(
        _tokenUsageEstimatedMeta,
        tokenUsageEstimated.isAcceptableOrUnknown(
          data['token_usage_estimated']!,
          _tokenUsageEstimatedMeta,
        ),
      );
    }
    if (data.containsKey('prompt_cache_hit_tokens')) {
      context.handle(
        _promptCacheHitTokensMeta,
        promptCacheHitTokens.isAcceptableOrUnknown(
          data['prompt_cache_hit_tokens']!,
          _promptCacheHitTokensMeta,
        ),
      );
    }
    if (data.containsKey('prompt_cache_miss_tokens')) {
      context.handle(
        _promptCacheMissTokensMeta,
        promptCacheMissTokens.isAcceptableOrUnknown(
          data['prompt_cache_miss_tokens']!,
          _promptCacheMissTokensMeta,
        ),
      );
    }
    if (data.containsKey('reasoning_tokens')) {
      context.handle(
        _reasoningTokensMeta,
        reasoningTokens.isAcceptableOrUnknown(
          data['reasoning_tokens']!,
          _reasoningTokensMeta,
        ),
      );
    }
    if (data.containsKey('agent_run_id')) {
      context.handle(
        _agentRunIdMeta,
        agentRunId.isAcceptableOrUnknown(
          data['agent_run_id']!,
          _agentRunIdMeta,
        ),
      );
    }
    if (data.containsKey('attachments_json')) {
      context.handle(
        _attachmentsJsonMeta,
        attachmentsJson.isAcceptableOrUnknown(
          data['attachments_json']!,
          _attachmentsJsonMeta,
        ),
      );
    }
    if (data.containsKey('traces_json')) {
      context.handle(
        _tracesJsonMeta,
        tracesJson.isAcceptableOrUnknown(data['traces_json']!, _tracesJsonMeta),
      );
    }
    if (data.containsKey('todo_steps_json')) {
      context.handle(
        _todoStepsJsonMeta,
        todoStepsJson.isAcceptableOrUnknown(
          data['todo_steps_json']!,
          _todoStepsJsonMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AiChatMessage map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AiChatMessage(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      chatId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}chat_id'],
      )!,
      role: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}role'],
      )!,
      textContent: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}text'],
      )!,
      contextText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}context_text'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      promptTokens: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}prompt_tokens'],
      ),
      completionTokens: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}completion_tokens'],
      ),
      totalTokens: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}total_tokens'],
      ),
      elapsedMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}elapsed_ms'],
      ),
      tokenUsageEstimated: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}token_usage_estimated'],
      ),
      promptCacheHitTokens: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}prompt_cache_hit_tokens'],
      ),
      promptCacheMissTokens: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}prompt_cache_miss_tokens'],
      ),
      reasoningTokens: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}reasoning_tokens'],
      ),
      agentRunId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}agent_run_id'],
      ),
      attachmentsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}attachments_json'],
      )!,
      tracesJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}traces_json'],
      )!,
      todoStepsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}todo_steps_json'],
      )!,
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
  final String? agentRunId;
  final String attachmentsJson;
  final String tracesJson;
  final String todoStepsJson;
  const AiChatMessage({
    required this.id,
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
    this.agentRunId,
    required this.attachmentsJson,
    required this.tracesJson,
    required this.todoStepsJson,
  });
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
    if (!nullToAbsent || agentRunId != null) {
      map['agent_run_id'] = Variable<String>(agentRunId);
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
      agentRunId: agentRunId == null && nullToAbsent
          ? const Value.absent()
          : Value(agentRunId),
      attachmentsJson: Value(attachmentsJson),
      tracesJson: Value(tracesJson),
      todoStepsJson: Value(todoStepsJson),
    );
  }

  factory AiChatMessage.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
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
      tokenUsageEstimated: serializer.fromJson<bool?>(
        json['tokenUsageEstimated'],
      ),
      promptCacheHitTokens: serializer.fromJson<int?>(
        json['promptCacheHitTokens'],
      ),
      promptCacheMissTokens: serializer.fromJson<int?>(
        json['promptCacheMissTokens'],
      ),
      reasoningTokens: serializer.fromJson<int?>(json['reasoningTokens']),
      agentRunId: serializer.fromJson<String?>(json['agentRunId']),
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
      'agentRunId': serializer.toJson<String?>(agentRunId),
      'attachmentsJson': serializer.toJson<String>(attachmentsJson),
      'tracesJson': serializer.toJson<String>(tracesJson),
      'todoStepsJson': serializer.toJson<String>(todoStepsJson),
    };
  }

  AiChatMessage copyWith({
    String? id,
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
    Value<String?> agentRunId = const Value.absent(),
    String? attachmentsJson,
    String? tracesJson,
    String? todoStepsJson,
  }) => AiChatMessage(
    id: id ?? this.id,
    chatId: chatId ?? this.chatId,
    role: role ?? this.role,
    textContent: textContent ?? this.textContent,
    contextText: contextText.present ? contextText.value : this.contextText,
    createdAt: createdAt ?? this.createdAt,
    promptTokens: promptTokens.present ? promptTokens.value : this.promptTokens,
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
    agentRunId: agentRunId.present ? agentRunId.value : this.agentRunId,
    attachmentsJson: attachmentsJson ?? this.attachmentsJson,
    tracesJson: tracesJson ?? this.tracesJson,
    todoStepsJson: todoStepsJson ?? this.todoStepsJson,
  );
  AiChatMessage copyWithCompanion(AiChatMessagesCompanion data) {
    return AiChatMessage(
      id: data.id.present ? data.id.value : this.id,
      chatId: data.chatId.present ? data.chatId.value : this.chatId,
      role: data.role.present ? data.role.value : this.role,
      textContent: data.textContent.present
          ? data.textContent.value
          : this.textContent,
      contextText: data.contextText.present
          ? data.contextText.value
          : this.contextText,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      promptTokens: data.promptTokens.present
          ? data.promptTokens.value
          : this.promptTokens,
      completionTokens: data.completionTokens.present
          ? data.completionTokens.value
          : this.completionTokens,
      totalTokens: data.totalTokens.present
          ? data.totalTokens.value
          : this.totalTokens,
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
      agentRunId: data.agentRunId.present
          ? data.agentRunId.value
          : this.agentRunId,
      attachmentsJson: data.attachmentsJson.present
          ? data.attachmentsJson.value
          : this.attachmentsJson,
      tracesJson: data.tracesJson.present
          ? data.tracesJson.value
          : this.tracesJson,
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
          ..write('agentRunId: $agentRunId, ')
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
    agentRunId,
    attachmentsJson,
    tracesJson,
    todoStepsJson,
  );
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
          other.agentRunId == this.agentRunId &&
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
  final Value<String?> agentRunId;
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
    this.agentRunId = const Value.absent(),
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
    this.agentRunId = const Value.absent(),
    this.attachmentsJson = const Value.absent(),
    this.tracesJson = const Value.absent(),
    this.todoStepsJson = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
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
    Expression<String>? agentRunId,
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
      if (agentRunId != null) 'agent_run_id': agentRunId,
      if (attachmentsJson != null) 'attachments_json': attachmentsJson,
      if (tracesJson != null) 'traces_json': tracesJson,
      if (todoStepsJson != null) 'todo_steps_json': todoStepsJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AiChatMessagesCompanion copyWith({
    Value<String>? id,
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
    Value<String?>? agentRunId,
    Value<String>? attachmentsJson,
    Value<String>? tracesJson,
    Value<String>? todoStepsJson,
    Value<int>? rowid,
  }) {
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
      agentRunId: agentRunId ?? this.agentRunId,
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
      map['prompt_cache_hit_tokens'] = Variable<int>(
        promptCacheHitTokens.value,
      );
    }
    if (promptCacheMissTokens.present) {
      map['prompt_cache_miss_tokens'] = Variable<int>(
        promptCacheMissTokens.value,
      );
    }
    if (reasoningTokens.present) {
      map['reasoning_tokens'] = Variable<int>(reasoningTokens.value);
    }
    if (agentRunId.present) {
      map['agent_run_id'] = Variable<String>(agentRunId.value);
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
          ..write('agentRunId: $agentRunId, ')
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
    'id',
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
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _modelMeta = const VerificationMeta('model');
  @override
  late final GeneratedColumn<String> model = GeneratedColumn<String>(
    'model',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _helperModelMeta = const VerificationMeta(
    'helperModel',
  );
  @override
  late final GeneratedColumn<String> helperModel = GeneratedColumn<String>(
    'helper_model',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _auditModelMeta = const VerificationMeta(
    'auditModel',
  );
  @override
  late final GeneratedColumn<String> auditModel = GeneratedColumn<String>(
    'audit_model',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _promptTokensMeta = const VerificationMeta(
    'promptTokens',
  );
  @override
  late final GeneratedColumn<int> promptTokens = GeneratedColumn<int>(
    'prompt_tokens',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _completionTokensMeta = const VerificationMeta(
    'completionTokens',
  );
  @override
  late final GeneratedColumn<int> completionTokens = GeneratedColumn<int>(
    'completion_tokens',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _totalTokensMeta = const VerificationMeta(
    'totalTokens',
  );
  @override
  late final GeneratedColumn<int> totalTokens = GeneratedColumn<int>(
    'total_tokens',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _elapsedMsMeta = const VerificationMeta(
    'elapsedMs',
  );
  @override
  late final GeneratedColumn<int> elapsedMs = GeneratedColumn<int>(
    'elapsed_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _toolCallsMeta = const VerificationMeta(
    'toolCalls',
  );
  @override
  late final GeneratedColumn<int> toolCalls = GeneratedColumn<int>(
    'tool_calls',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _cacheHitsMeta = const VerificationMeta(
    'cacheHits',
  );
  @override
  late final GeneratedColumn<int> cacheHits = GeneratedColumn<int>(
    'cache_hits',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _dedupBlockedCallsMeta = const VerificationMeta(
    'dedupBlockedCalls',
  );
  @override
  late final GeneratedColumn<int> dedupBlockedCalls = GeneratedColumn<int>(
    'dedup_blocked_calls',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _ragHitsMeta = const VerificationMeta(
    'ragHits',
  );
  @override
  late final GeneratedColumn<int> ragHits = GeneratedColumn<int>(
    'rag_hits',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _approvalCountMeta = const VerificationMeta(
    'approvalCount',
  );
  @override
  late final GeneratedColumn<int> approvalCount = GeneratedColumn<int>(
    'approval_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _approvedCountMeta = const VerificationMeta(
    'approvedCount',
  );
  @override
  late final GeneratedColumn<int> approvedCount = GeneratedColumn<int>(
    'approved_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _auditCountMeta = const VerificationMeta(
    'auditCount',
  );
  @override
  late final GeneratedColumn<int> auditCount = GeneratedColumn<int>(
    'audit_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _helperFanoutMeta = const VerificationMeta(
    'helperFanout',
  );
  @override
  late final GeneratedColumn<int> helperFanout = GeneratedColumn<int>(
    'helper_fanout',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _successMeta = const VerificationMeta(
    'success',
  );
  @override
  late final GeneratedColumn<bool> success = GeneratedColumn<bool>(
    'success',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("success" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _selectedToolSetJsonMeta =
      const VerificationMeta('selectedToolSetJson');
  @override
  late final GeneratedColumn<String> selectedToolSetJson =
      GeneratedColumn<String>(
        'selected_tool_set_json',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant('[]'),
      );
  static const VerificationMeta _memorySourcesJsonMeta = const VerificationMeta(
    'memorySourcesJson',
  );
  @override
  late final GeneratedColumn<String> memorySourcesJson =
      GeneratedColumn<String>(
        'memory_sources_json',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant('[]'),
      );
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
    memorySourcesJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'agent_run_metrics';
  @override
  VerificationContext validateIntegrity(
    Insertable<AgentRunMetricRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
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
    } else if (isInserting) {
      context.missing(_finishedAtMeta);
    }
    if (data.containsKey('model')) {
      context.handle(
        _modelMeta,
        model.isAcceptableOrUnknown(data['model']!, _modelMeta),
      );
    } else if (isInserting) {
      context.missing(_modelMeta);
    }
    if (data.containsKey('helper_model')) {
      context.handle(
        _helperModelMeta,
        helperModel.isAcceptableOrUnknown(
          data['helper_model']!,
          _helperModelMeta,
        ),
      );
    }
    if (data.containsKey('audit_model')) {
      context.handle(
        _auditModelMeta,
        auditModel.isAcceptableOrUnknown(data['audit_model']!, _auditModelMeta),
      );
    }
    if (data.containsKey('prompt_tokens')) {
      context.handle(
        _promptTokensMeta,
        promptTokens.isAcceptableOrUnknown(
          data['prompt_tokens']!,
          _promptTokensMeta,
        ),
      );
    }
    if (data.containsKey('completion_tokens')) {
      context.handle(
        _completionTokensMeta,
        completionTokens.isAcceptableOrUnknown(
          data['completion_tokens']!,
          _completionTokensMeta,
        ),
      );
    }
    if (data.containsKey('total_tokens')) {
      context.handle(
        _totalTokensMeta,
        totalTokens.isAcceptableOrUnknown(
          data['total_tokens']!,
          _totalTokensMeta,
        ),
      );
    }
    if (data.containsKey('elapsed_ms')) {
      context.handle(
        _elapsedMsMeta,
        elapsedMs.isAcceptableOrUnknown(data['elapsed_ms']!, _elapsedMsMeta),
      );
    }
    if (data.containsKey('tool_calls')) {
      context.handle(
        _toolCallsMeta,
        toolCalls.isAcceptableOrUnknown(data['tool_calls']!, _toolCallsMeta),
      );
    }
    if (data.containsKey('cache_hits')) {
      context.handle(
        _cacheHitsMeta,
        cacheHits.isAcceptableOrUnknown(data['cache_hits']!, _cacheHitsMeta),
      );
    }
    if (data.containsKey('dedup_blocked_calls')) {
      context.handle(
        _dedupBlockedCallsMeta,
        dedupBlockedCalls.isAcceptableOrUnknown(
          data['dedup_blocked_calls']!,
          _dedupBlockedCallsMeta,
        ),
      );
    }
    if (data.containsKey('rag_hits')) {
      context.handle(
        _ragHitsMeta,
        ragHits.isAcceptableOrUnknown(data['rag_hits']!, _ragHitsMeta),
      );
    }
    if (data.containsKey('approval_count')) {
      context.handle(
        _approvalCountMeta,
        approvalCount.isAcceptableOrUnknown(
          data['approval_count']!,
          _approvalCountMeta,
        ),
      );
    }
    if (data.containsKey('approved_count')) {
      context.handle(
        _approvedCountMeta,
        approvedCount.isAcceptableOrUnknown(
          data['approved_count']!,
          _approvedCountMeta,
        ),
      );
    }
    if (data.containsKey('audit_count')) {
      context.handle(
        _auditCountMeta,
        auditCount.isAcceptableOrUnknown(data['audit_count']!, _auditCountMeta),
      );
    }
    if (data.containsKey('helper_fanout')) {
      context.handle(
        _helperFanoutMeta,
        helperFanout.isAcceptableOrUnknown(
          data['helper_fanout']!,
          _helperFanoutMeta,
        ),
      );
    }
    if (data.containsKey('success')) {
      context.handle(
        _successMeta,
        success.isAcceptableOrUnknown(data['success']!, _successMeta),
      );
    }
    if (data.containsKey('selected_tool_set_json')) {
      context.handle(
        _selectedToolSetJsonMeta,
        selectedToolSetJson.isAcceptableOrUnknown(
          data['selected_tool_set_json']!,
          _selectedToolSetJsonMeta,
        ),
      );
    }
    if (data.containsKey('memory_sources_json')) {
      context.handle(
        _memorySourcesJsonMeta,
        memorySourcesJson.isAcceptableOrUnknown(
          data['memory_sources_json']!,
          _memorySourcesJsonMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AgentRunMetricRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AgentRunMetricRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      startedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}started_at'],
      )!,
      finishedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}finished_at'],
      )!,
      model: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}model'],
      )!,
      helperModel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}helper_model'],
      )!,
      auditModel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}audit_model'],
      )!,
      promptTokens: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}prompt_tokens'],
      )!,
      completionTokens: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}completion_tokens'],
      )!,
      totalTokens: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}total_tokens'],
      )!,
      elapsedMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}elapsed_ms'],
      )!,
      toolCalls: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}tool_calls'],
      )!,
      cacheHits: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}cache_hits'],
      )!,
      dedupBlockedCalls: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}dedup_blocked_calls'],
      )!,
      ragHits: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}rag_hits'],
      )!,
      approvalCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}approval_count'],
      )!,
      approvedCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}approved_count'],
      )!,
      auditCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}audit_count'],
      )!,
      helperFanout: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}helper_fanout'],
      )!,
      success: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}success'],
      )!,
      selectedToolSetJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}selected_tool_set_json'],
      )!,
      memorySourcesJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}memory_sources_json'],
      )!,
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
  const AgentRunMetricRow({
    required this.id,
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
    required this.memorySourcesJson,
  });
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

  factory AgentRunMetricRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
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
      selectedToolSetJson: serializer.fromJson<String>(
        json['selectedToolSetJson'],
      ),
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

  AgentRunMetricRow copyWith({
    String? id,
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
    String? memorySourcesJson,
  }) => AgentRunMetricRow(
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
      finishedAt: data.finishedAt.present
          ? data.finishedAt.value
          : this.finishedAt,
      model: data.model.present ? data.model.value : this.model,
      helperModel: data.helperModel.present
          ? data.helperModel.value
          : this.helperModel,
      auditModel: data.auditModel.present
          ? data.auditModel.value
          : this.auditModel,
      promptTokens: data.promptTokens.present
          ? data.promptTokens.value
          : this.promptTokens,
      completionTokens: data.completionTokens.present
          ? data.completionTokens.value
          : this.completionTokens,
      totalTokens: data.totalTokens.present
          ? data.totalTokens.value
          : this.totalTokens,
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
      auditCount: data.auditCount.present
          ? data.auditCount.value
          : this.auditCount,
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
    memorySourcesJson,
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
  }) : id = Value(id),
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

  AgentRunMetricsTableCompanion copyWith({
    Value<String>? id,
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
    Value<int>? rowid,
  }) {
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
      map['selected_tool_set_json'] = Variable<String>(
        selectedToolSetJson.value,
      );
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

class $AgentTraceEventsTableTable extends AgentTraceEventsTable
    with TableInfo<$AgentTraceEventsTableTable, AgentTraceEventRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AgentTraceEventsTableTable(this.attachedDatabase, [this._alias]);
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
  );
  static const VerificationMeta _chatIdMeta = const VerificationMeta('chatId');
  @override
  late final GeneratedColumn<String> chatId = GeneratedColumn<String>(
    'chat_id',
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
  static const VerificationMeta _sequenceMeta = const VerificationMeta(
    'sequence',
  );
  @override
  late final GeneratedColumn<int> sequence = GeneratedColumn<int>(
    'sequence',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
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
  static const VerificationMeta _toolNameMeta = const VerificationMeta(
    'toolName',
  );
  @override
  late final GeneratedColumn<String> toolName = GeneratedColumn<String>(
    'tool_name',
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
    requiredDuringInsert: false,
    defaultValue: const Constant('info'),
  );
  static const VerificationMeta _durationMsMeta = const VerificationMeta(
    'durationMs',
  );
  @override
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
    'duration_ms',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _parentEventIdMeta = const VerificationMeta(
    'parentEventId',
  );
  @override
  late final GeneratedColumn<String> parentEventId = GeneratedColumn<String>(
    'parent_event_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    runId,
    chatId,
    createdAt,
    sequence,
    kind,
    title,
    contentJson,
    toolName,
    status,
    durationMs,
    parentEventId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'agent_trace_events';
  @override
  VerificationContext validateIntegrity(
    Insertable<AgentTraceEventRow> instance, {
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
    if (data.containsKey('chat_id')) {
      context.handle(
        _chatIdMeta,
        chatId.isAcceptableOrUnknown(data['chat_id']!, _chatIdMeta),
      );
    } else if (isInserting) {
      context.missing(_chatIdMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('sequence')) {
      context.handle(
        _sequenceMeta,
        sequence.isAcceptableOrUnknown(data['sequence']!, _sequenceMeta),
      );
    } else if (isInserting) {
      context.missing(_sequenceMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
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
    if (data.containsKey('tool_name')) {
      context.handle(
        _toolNameMeta,
        toolName.isAcceptableOrUnknown(data['tool_name']!, _toolNameMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('duration_ms')) {
      context.handle(
        _durationMsMeta,
        durationMs.isAcceptableOrUnknown(data['duration_ms']!, _durationMsMeta),
      );
    }
    if (data.containsKey('parent_event_id')) {
      context.handle(
        _parentEventIdMeta,
        parentEventId.isAcceptableOrUnknown(
          data['parent_event_id']!,
          _parentEventIdMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AgentTraceEventRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AgentTraceEventRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      runId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}run_id'],
      )!,
      chatId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}chat_id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      sequence: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sequence'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      contentJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_json'],
      )!,
      toolName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tool_name'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      durationMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_ms'],
      ),
      parentEventId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}parent_event_id'],
      ),
    );
  }

  @override
  $AgentTraceEventsTableTable createAlias(String alias) {
    return $AgentTraceEventsTableTable(attachedDatabase, alias);
  }
}

class AgentTraceEventRow extends DataClass
    implements Insertable<AgentTraceEventRow> {
  final String id;
  final String runId;
  final String chatId;
  final int createdAt;
  final int sequence;
  final String kind;
  final String title;
  final String contentJson;
  final String? toolName;
  final String status;
  final int? durationMs;
  final String? parentEventId;
  const AgentTraceEventRow({
    required this.id,
    required this.runId,
    required this.chatId,
    required this.createdAt,
    required this.sequence,
    required this.kind,
    required this.title,
    required this.contentJson,
    this.toolName,
    required this.status,
    this.durationMs,
    this.parentEventId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['run_id'] = Variable<String>(runId);
    map['chat_id'] = Variable<String>(chatId);
    map['created_at'] = Variable<int>(createdAt);
    map['sequence'] = Variable<int>(sequence);
    map['kind'] = Variable<String>(kind);
    map['title'] = Variable<String>(title);
    map['content_json'] = Variable<String>(contentJson);
    if (!nullToAbsent || toolName != null) {
      map['tool_name'] = Variable<String>(toolName);
    }
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || durationMs != null) {
      map['duration_ms'] = Variable<int>(durationMs);
    }
    if (!nullToAbsent || parentEventId != null) {
      map['parent_event_id'] = Variable<String>(parentEventId);
    }
    return map;
  }

  AgentTraceEventsTableCompanion toCompanion(bool nullToAbsent) {
    return AgentTraceEventsTableCompanion(
      id: Value(id),
      runId: Value(runId),
      chatId: Value(chatId),
      createdAt: Value(createdAt),
      sequence: Value(sequence),
      kind: Value(kind),
      title: Value(title),
      contentJson: Value(contentJson),
      toolName: toolName == null && nullToAbsent
          ? const Value.absent()
          : Value(toolName),
      status: Value(status),
      durationMs: durationMs == null && nullToAbsent
          ? const Value.absent()
          : Value(durationMs),
      parentEventId: parentEventId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentEventId),
    );
  }

  factory AgentTraceEventRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AgentTraceEventRow(
      id: serializer.fromJson<String>(json['id']),
      runId: serializer.fromJson<String>(json['runId']),
      chatId: serializer.fromJson<String>(json['chatId']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      sequence: serializer.fromJson<int>(json['sequence']),
      kind: serializer.fromJson<String>(json['kind']),
      title: serializer.fromJson<String>(json['title']),
      contentJson: serializer.fromJson<String>(json['contentJson']),
      toolName: serializer.fromJson<String?>(json['toolName']),
      status: serializer.fromJson<String>(json['status']),
      durationMs: serializer.fromJson<int?>(json['durationMs']),
      parentEventId: serializer.fromJson<String?>(json['parentEventId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'runId': serializer.toJson<String>(runId),
      'chatId': serializer.toJson<String>(chatId),
      'createdAt': serializer.toJson<int>(createdAt),
      'sequence': serializer.toJson<int>(sequence),
      'kind': serializer.toJson<String>(kind),
      'title': serializer.toJson<String>(title),
      'contentJson': serializer.toJson<String>(contentJson),
      'toolName': serializer.toJson<String?>(toolName),
      'status': serializer.toJson<String>(status),
      'durationMs': serializer.toJson<int?>(durationMs),
      'parentEventId': serializer.toJson<String?>(parentEventId),
    };
  }

  AgentTraceEventRow copyWith({
    String? id,
    String? runId,
    String? chatId,
    int? createdAt,
    int? sequence,
    String? kind,
    String? title,
    String? contentJson,
    Value<String?> toolName = const Value.absent(),
    String? status,
    Value<int?> durationMs = const Value.absent(),
    Value<String?> parentEventId = const Value.absent(),
  }) => AgentTraceEventRow(
    id: id ?? this.id,
    runId: runId ?? this.runId,
    chatId: chatId ?? this.chatId,
    createdAt: createdAt ?? this.createdAt,
    sequence: sequence ?? this.sequence,
    kind: kind ?? this.kind,
    title: title ?? this.title,
    contentJson: contentJson ?? this.contentJson,
    toolName: toolName.present ? toolName.value : this.toolName,
    status: status ?? this.status,
    durationMs: durationMs.present ? durationMs.value : this.durationMs,
    parentEventId: parentEventId.present
        ? parentEventId.value
        : this.parentEventId,
  );
  AgentTraceEventRow copyWithCompanion(AgentTraceEventsTableCompanion data) {
    return AgentTraceEventRow(
      id: data.id.present ? data.id.value : this.id,
      runId: data.runId.present ? data.runId.value : this.runId,
      chatId: data.chatId.present ? data.chatId.value : this.chatId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      sequence: data.sequence.present ? data.sequence.value : this.sequence,
      kind: data.kind.present ? data.kind.value : this.kind,
      title: data.title.present ? data.title.value : this.title,
      contentJson: data.contentJson.present
          ? data.contentJson.value
          : this.contentJson,
      toolName: data.toolName.present ? data.toolName.value : this.toolName,
      status: data.status.present ? data.status.value : this.status,
      durationMs: data.durationMs.present
          ? data.durationMs.value
          : this.durationMs,
      parentEventId: data.parentEventId.present
          ? data.parentEventId.value
          : this.parentEventId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AgentTraceEventRow(')
          ..write('id: $id, ')
          ..write('runId: $runId, ')
          ..write('chatId: $chatId, ')
          ..write('createdAt: $createdAt, ')
          ..write('sequence: $sequence, ')
          ..write('kind: $kind, ')
          ..write('title: $title, ')
          ..write('contentJson: $contentJson, ')
          ..write('toolName: $toolName, ')
          ..write('status: $status, ')
          ..write('durationMs: $durationMs, ')
          ..write('parentEventId: $parentEventId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    runId,
    chatId,
    createdAt,
    sequence,
    kind,
    title,
    contentJson,
    toolName,
    status,
    durationMs,
    parentEventId,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AgentTraceEventRow &&
          other.id == this.id &&
          other.runId == this.runId &&
          other.chatId == this.chatId &&
          other.createdAt == this.createdAt &&
          other.sequence == this.sequence &&
          other.kind == this.kind &&
          other.title == this.title &&
          other.contentJson == this.contentJson &&
          other.toolName == this.toolName &&
          other.status == this.status &&
          other.durationMs == this.durationMs &&
          other.parentEventId == this.parentEventId);
}

class AgentTraceEventsTableCompanion
    extends UpdateCompanion<AgentTraceEventRow> {
  final Value<String> id;
  final Value<String> runId;
  final Value<String> chatId;
  final Value<int> createdAt;
  final Value<int> sequence;
  final Value<String> kind;
  final Value<String> title;
  final Value<String> contentJson;
  final Value<String?> toolName;
  final Value<String> status;
  final Value<int?> durationMs;
  final Value<String?> parentEventId;
  final Value<int> rowid;
  const AgentTraceEventsTableCompanion({
    this.id = const Value.absent(),
    this.runId = const Value.absent(),
    this.chatId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.sequence = const Value.absent(),
    this.kind = const Value.absent(),
    this.title = const Value.absent(),
    this.contentJson = const Value.absent(),
    this.toolName = const Value.absent(),
    this.status = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.parentEventId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AgentTraceEventsTableCompanion.insert({
    required String id,
    required String runId,
    required String chatId,
    required int createdAt,
    required int sequence,
    required String kind,
    required String title,
    required String contentJson,
    this.toolName = const Value.absent(),
    this.status = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.parentEventId = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       runId = Value(runId),
       chatId = Value(chatId),
       createdAt = Value(createdAt),
       sequence = Value(sequence),
       kind = Value(kind),
       title = Value(title),
       contentJson = Value(contentJson);
  static Insertable<AgentTraceEventRow> custom({
    Expression<String>? id,
    Expression<String>? runId,
    Expression<String>? chatId,
    Expression<int>? createdAt,
    Expression<int>? sequence,
    Expression<String>? kind,
    Expression<String>? title,
    Expression<String>? contentJson,
    Expression<String>? toolName,
    Expression<String>? status,
    Expression<int>? durationMs,
    Expression<String>? parentEventId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (runId != null) 'run_id': runId,
      if (chatId != null) 'chat_id': chatId,
      if (createdAt != null) 'created_at': createdAt,
      if (sequence != null) 'sequence': sequence,
      if (kind != null) 'kind': kind,
      if (title != null) 'title': title,
      if (contentJson != null) 'content_json': contentJson,
      if (toolName != null) 'tool_name': toolName,
      if (status != null) 'status': status,
      if (durationMs != null) 'duration_ms': durationMs,
      if (parentEventId != null) 'parent_event_id': parentEventId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AgentTraceEventsTableCompanion copyWith({
    Value<String>? id,
    Value<String>? runId,
    Value<String>? chatId,
    Value<int>? createdAt,
    Value<int>? sequence,
    Value<String>? kind,
    Value<String>? title,
    Value<String>? contentJson,
    Value<String?>? toolName,
    Value<String>? status,
    Value<int?>? durationMs,
    Value<String?>? parentEventId,
    Value<int>? rowid,
  }) {
    return AgentTraceEventsTableCompanion(
      id: id ?? this.id,
      runId: runId ?? this.runId,
      chatId: chatId ?? this.chatId,
      createdAt: createdAt ?? this.createdAt,
      sequence: sequence ?? this.sequence,
      kind: kind ?? this.kind,
      title: title ?? this.title,
      contentJson: contentJson ?? this.contentJson,
      toolName: toolName ?? this.toolName,
      status: status ?? this.status,
      durationMs: durationMs ?? this.durationMs,
      parentEventId: parentEventId ?? this.parentEventId,
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
    if (chatId.present) {
      map['chat_id'] = Variable<String>(chatId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (sequence.present) {
      map['sequence'] = Variable<int>(sequence.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (contentJson.present) {
      map['content_json'] = Variable<String>(contentJson.value);
    }
    if (toolName.present) {
      map['tool_name'] = Variable<String>(toolName.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (durationMs.present) {
      map['duration_ms'] = Variable<int>(durationMs.value);
    }
    if (parentEventId.present) {
      map['parent_event_id'] = Variable<String>(parentEventId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AgentTraceEventsTableCompanion(')
          ..write('id: $id, ')
          ..write('runId: $runId, ')
          ..write('chatId: $chatId, ')
          ..write('createdAt: $createdAt, ')
          ..write('sequence: $sequence, ')
          ..write('kind: $kind, ')
          ..write('title: $title, ')
          ..write('contentJson: $contentJson, ')
          ..write('toolName: $toolName, ')
          ..write('status: $status, ')
          ..write('durationMs: $durationMs, ')
          ..write('parentEventId: $parentEventId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AiDatabase extends GeneratedDatabase {
  _$AiDatabase(QueryExecutor e) : super(e);
  $AiDatabaseManager get managers => $AiDatabaseManager(this);
  late final $AiChatsTable aiChats = $AiChatsTable(this);
  late final $AiChatMessagesTable aiChatMessages = $AiChatMessagesTable(this);
  late final $AgentRunMetricsTableTable agentRunMetricsTable =
      $AgentRunMetricsTableTable(this);
  late final $AgentTraceEventsTableTable agentTraceEventsTable =
      $AgentTraceEventsTableTable(this);
  late final AiChatDao aiChatDao = AiChatDao(this as AiDatabase);
  late final AgentMetricsDao agentMetricsDao = AgentMetricsDao(
    this as AiDatabase,
  );
  late final AgentTraceDao agentTraceDao = AgentTraceDao(this as AiDatabase);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    aiChats,
    aiChatMessages,
    agentRunMetricsTable,
    agentTraceEventsTable,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'ai_chats',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('ai_chat_messages', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$AiChatsTableCreateCompanionBuilder =
    AiChatsCompanion Function({
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
typedef $$AiChatsTableUpdateCompanionBuilder =
    AiChatsCompanion Function({
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
    extends BaseReferences<_$AiDatabase, $AiChatsTable, AiChat> {
  $$AiChatsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$AiChatMessagesTable, List<AiChatMessage>>
  _aiChatMessagesRefsTable(_$AiDatabase db) => MultiTypedResultKey.fromTable(
    db.aiChatMessages,
    aliasName: 'ai_chats__id__ai_chat_messages__chat_id',
  );

  $$AiChatMessagesTableProcessedTableManager get aiChatMessagesRefs {
    final manager = $$AiChatMessagesTableTableManager(
      $_db,
      $_db.aiChatMessages,
    ).filter((f) => f.chatId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_aiChatMessagesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$AiChatsTableFilterComposer
    extends Composer<_$AiDatabase, $AiChatsTable> {
  $$AiChatsTableFilterComposer({
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

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get model => $composableBuilder(
    column: $table.model,
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

  ColumnFilters<bool> get planMode => $composableBuilder(
    column: $table.planMode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get approvedPlanAssistantCreatedAt => $composableBuilder(
    column: $table.approvedPlanAssistantCreatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get approvedPlanApprovedAt => $composableBuilder(
    column: $table.approvedPlanApprovedAt,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> aiChatMessagesRefs(
    Expression<bool> Function($$AiChatMessagesTableFilterComposer f) f,
  ) {
    final $$AiChatMessagesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.aiChatMessages,
      getReferencedColumn: (t) => t.chatId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AiChatMessagesTableFilterComposer(
            $db: $db,
            $table: $db.aiChatMessages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$AiChatsTableOrderingComposer
    extends Composer<_$AiDatabase, $AiChatsTable> {
  $$AiChatsTableOrderingComposer({
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

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get model => $composableBuilder(
    column: $table.model,
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

  ColumnOrderings<bool> get planMode => $composableBuilder(
    column: $table.planMode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get approvedPlanAssistantCreatedAt => $composableBuilder(
    column: $table.approvedPlanAssistantCreatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get approvedPlanApprovedAt => $composableBuilder(
    column: $table.approvedPlanApprovedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AiChatsTableAnnotationComposer
    extends Composer<_$AiDatabase, $AiChatsTable> {
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
    builder: (column) => column,
  );

  GeneratedColumn<int> get approvedPlanApprovedAt => $composableBuilder(
    column: $table.approvedPlanApprovedAt,
    builder: (column) => column,
  );

  Expression<T> aiChatMessagesRefs<T extends Object>(
    Expression<T> Function($$AiChatMessagesTableAnnotationComposer a) f,
  ) {
    final $$AiChatMessagesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.aiChatMessages,
      getReferencedColumn: (t) => t.chatId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AiChatMessagesTableAnnotationComposer(
            $db: $db,
            $table: $db.aiChatMessages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$AiChatsTableTableManager
    extends
        RootTableManager<
          _$AiDatabase,
          $AiChatsTable,
          AiChat,
          $$AiChatsTableFilterComposer,
          $$AiChatsTableOrderingComposer,
          $$AiChatsTableAnnotationComposer,
          $$AiChatsTableCreateCompanionBuilder,
          $$AiChatsTableUpdateCompanionBuilder,
          (AiChat, $$AiChatsTableReferences),
          AiChat,
          PrefetchHooks Function({bool aiChatMessagesRefs})
        > {
  $$AiChatsTableTableManager(_$AiDatabase db, $AiChatsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AiChatsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AiChatsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AiChatsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> model = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<bool> planMode = const Value.absent(),
                Value<int?> approvedPlanAssistantCreatedAt =
                    const Value.absent(),
                Value<int?> approvedPlanApprovedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AiChatsCompanion(
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
          createCompanionCallback:
              ({
                required String id,
                required String title,
                required String model,
                required int createdAt,
                required int updatedAt,
                Value<bool> planMode = const Value.absent(),
                Value<int?> approvedPlanAssistantCreatedAt =
                    const Value.absent(),
                Value<int?> approvedPlanApprovedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AiChatsCompanion.insert(
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
              .map(
                (e) => (
                  e.readTable(table),
                  $$AiChatsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({aiChatMessagesRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (aiChatMessagesRefs) db.aiChatMessages,
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (aiChatMessagesRefs)
                    await $_getPrefetchedData<
                      AiChat,
                      $AiChatsTable,
                      AiChatMessage
                    >(
                      currentTable: table,
                      referencedTable: $$AiChatsTableReferences
                          ._aiChatMessagesRefsTable(db),
                      managerFromTypedResult: (p0) => $$AiChatsTableReferences(
                        db,
                        table,
                        p0,
                      ).aiChatMessagesRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.chatId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$AiChatsTableProcessedTableManager =
    ProcessedTableManager<
      _$AiDatabase,
      $AiChatsTable,
      AiChat,
      $$AiChatsTableFilterComposer,
      $$AiChatsTableOrderingComposer,
      $$AiChatsTableAnnotationComposer,
      $$AiChatsTableCreateCompanionBuilder,
      $$AiChatsTableUpdateCompanionBuilder,
      (AiChat, $$AiChatsTableReferences),
      AiChat,
      PrefetchHooks Function({bool aiChatMessagesRefs})
    >;
typedef $$AiChatMessagesTableCreateCompanionBuilder =
    AiChatMessagesCompanion Function({
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
      Value<String?> agentRunId,
      Value<String> attachmentsJson,
      Value<String> tracesJson,
      Value<String> todoStepsJson,
      Value<int> rowid,
    });
typedef $$AiChatMessagesTableUpdateCompanionBuilder =
    AiChatMessagesCompanion Function({
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
      Value<String?> agentRunId,
      Value<String> attachmentsJson,
      Value<String> tracesJson,
      Value<String> todoStepsJson,
      Value<int> rowid,
    });

final class $$AiChatMessagesTableReferences
    extends BaseReferences<_$AiDatabase, $AiChatMessagesTable, AiChatMessage> {
  $$AiChatMessagesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $AiChatsTable _chatIdTable(_$AiDatabase db) =>
      db.aiChats.createAlias('ai_chat_messages__chat_id__ai_chats__id');

  $$AiChatsTableProcessedTableManager get chatId {
    final $_column = $_itemColumn<String>('chat_id')!;

    final manager = $$AiChatsTableTableManager(
      $_db,
      $_db.aiChats,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_chatIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$AiChatMessagesTableFilterComposer
    extends Composer<_$AiDatabase, $AiChatMessagesTable> {
  $$AiChatMessagesTableFilterComposer({
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

  ColumnFilters<String> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get textContent => $composableBuilder(
    column: $table.textContent,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contextText => $composableBuilder(
    column: $table.contextText,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get promptTokens => $composableBuilder(
    column: $table.promptTokens,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get completionTokens => $composableBuilder(
    column: $table.completionTokens,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get totalTokens => $composableBuilder(
    column: $table.totalTokens,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get elapsedMs => $composableBuilder(
    column: $table.elapsedMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get tokenUsageEstimated => $composableBuilder(
    column: $table.tokenUsageEstimated,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get promptCacheHitTokens => $composableBuilder(
    column: $table.promptCacheHitTokens,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get promptCacheMissTokens => $composableBuilder(
    column: $table.promptCacheMissTokens,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get reasoningTokens => $composableBuilder(
    column: $table.reasoningTokens,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get agentRunId => $composableBuilder(
    column: $table.agentRunId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get attachmentsJson => $composableBuilder(
    column: $table.attachmentsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tracesJson => $composableBuilder(
    column: $table.tracesJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get todoStepsJson => $composableBuilder(
    column: $table.todoStepsJson,
    builder: (column) => ColumnFilters(column),
  );

  $$AiChatsTableFilterComposer get chatId {
    final $$AiChatsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.chatId,
      referencedTable: $db.aiChats,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AiChatsTableFilterComposer(
            $db: $db,
            $table: $db.aiChats,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$AiChatMessagesTableOrderingComposer
    extends Composer<_$AiDatabase, $AiChatMessagesTable> {
  $$AiChatMessagesTableOrderingComposer({
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

  ColumnOrderings<String> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get textContent => $composableBuilder(
    column: $table.textContent,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contextText => $composableBuilder(
    column: $table.contextText,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get promptTokens => $composableBuilder(
    column: $table.promptTokens,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get completionTokens => $composableBuilder(
    column: $table.completionTokens,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get totalTokens => $composableBuilder(
    column: $table.totalTokens,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get elapsedMs => $composableBuilder(
    column: $table.elapsedMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get tokenUsageEstimated => $composableBuilder(
    column: $table.tokenUsageEstimated,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get promptCacheHitTokens => $composableBuilder(
    column: $table.promptCacheHitTokens,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get promptCacheMissTokens => $composableBuilder(
    column: $table.promptCacheMissTokens,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get reasoningTokens => $composableBuilder(
    column: $table.reasoningTokens,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get agentRunId => $composableBuilder(
    column: $table.agentRunId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get attachmentsJson => $composableBuilder(
    column: $table.attachmentsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tracesJson => $composableBuilder(
    column: $table.tracesJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get todoStepsJson => $composableBuilder(
    column: $table.todoStepsJson,
    builder: (column) => ColumnOrderings(column),
  );

  $$AiChatsTableOrderingComposer get chatId {
    final $$AiChatsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.chatId,
      referencedTable: $db.aiChats,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AiChatsTableOrderingComposer(
            $db: $db,
            $table: $db.aiChats,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$AiChatMessagesTableAnnotationComposer
    extends Composer<_$AiDatabase, $AiChatMessagesTable> {
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
    column: $table.textContent,
    builder: (column) => column,
  );

  GeneratedColumn<String> get contextText => $composableBuilder(
    column: $table.contextText,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get promptTokens => $composableBuilder(
    column: $table.promptTokens,
    builder: (column) => column,
  );

  GeneratedColumn<int> get completionTokens => $composableBuilder(
    column: $table.completionTokens,
    builder: (column) => column,
  );

  GeneratedColumn<int> get totalTokens => $composableBuilder(
    column: $table.totalTokens,
    builder: (column) => column,
  );

  GeneratedColumn<int> get elapsedMs =>
      $composableBuilder(column: $table.elapsedMs, builder: (column) => column);

  GeneratedColumn<bool> get tokenUsageEstimated => $composableBuilder(
    column: $table.tokenUsageEstimated,
    builder: (column) => column,
  );

  GeneratedColumn<int> get promptCacheHitTokens => $composableBuilder(
    column: $table.promptCacheHitTokens,
    builder: (column) => column,
  );

  GeneratedColumn<int> get promptCacheMissTokens => $composableBuilder(
    column: $table.promptCacheMissTokens,
    builder: (column) => column,
  );

  GeneratedColumn<int> get reasoningTokens => $composableBuilder(
    column: $table.reasoningTokens,
    builder: (column) => column,
  );

  GeneratedColumn<String> get agentRunId => $composableBuilder(
    column: $table.agentRunId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get attachmentsJson => $composableBuilder(
    column: $table.attachmentsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get tracesJson => $composableBuilder(
    column: $table.tracesJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get todoStepsJson => $composableBuilder(
    column: $table.todoStepsJson,
    builder: (column) => column,
  );

  $$AiChatsTableAnnotationComposer get chatId {
    final $$AiChatsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.chatId,
      referencedTable: $db.aiChats,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AiChatsTableAnnotationComposer(
            $db: $db,
            $table: $db.aiChats,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$AiChatMessagesTableTableManager
    extends
        RootTableManager<
          _$AiDatabase,
          $AiChatMessagesTable,
          AiChatMessage,
          $$AiChatMessagesTableFilterComposer,
          $$AiChatMessagesTableOrderingComposer,
          $$AiChatMessagesTableAnnotationComposer,
          $$AiChatMessagesTableCreateCompanionBuilder,
          $$AiChatMessagesTableUpdateCompanionBuilder,
          (AiChatMessage, $$AiChatMessagesTableReferences),
          AiChatMessage,
          PrefetchHooks Function({bool chatId})
        > {
  $$AiChatMessagesTableTableManager(_$AiDatabase db, $AiChatMessagesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AiChatMessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AiChatMessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AiChatMessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
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
                Value<String?> agentRunId = const Value.absent(),
                Value<String> attachmentsJson = const Value.absent(),
                Value<String> tracesJson = const Value.absent(),
                Value<String> todoStepsJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AiChatMessagesCompanion(
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
                agentRunId: agentRunId,
                attachmentsJson: attachmentsJson,
                tracesJson: tracesJson,
                todoStepsJson: todoStepsJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
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
                Value<String?> agentRunId = const Value.absent(),
                Value<String> attachmentsJson = const Value.absent(),
                Value<String> tracesJson = const Value.absent(),
                Value<String> todoStepsJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AiChatMessagesCompanion.insert(
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
                agentRunId: agentRunId,
                attachmentsJson: attachmentsJson,
                tracesJson: tracesJson,
                todoStepsJson: todoStepsJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$AiChatMessagesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({chatId = false}) {
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
                    if (chatId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.chatId,
                                referencedTable: $$AiChatMessagesTableReferences
                                    ._chatIdTable(db),
                                referencedColumn:
                                    $$AiChatMessagesTableReferences
                                        ._chatIdTable(db)
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

typedef $$AiChatMessagesTableProcessedTableManager =
    ProcessedTableManager<
      _$AiDatabase,
      $AiChatMessagesTable,
      AiChatMessage,
      $$AiChatMessagesTableFilterComposer,
      $$AiChatMessagesTableOrderingComposer,
      $$AiChatMessagesTableAnnotationComposer,
      $$AiChatMessagesTableCreateCompanionBuilder,
      $$AiChatMessagesTableUpdateCompanionBuilder,
      (AiChatMessage, $$AiChatMessagesTableReferences),
      AiChatMessage,
      PrefetchHooks Function({bool chatId})
    >;
typedef $$AgentRunMetricsTableTableCreateCompanionBuilder =
    AgentRunMetricsTableCompanion Function({
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
typedef $$AgentRunMetricsTableTableUpdateCompanionBuilder =
    AgentRunMetricsTableCompanion Function({
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
    extends Composer<_$AiDatabase, $AgentRunMetricsTableTable> {
  $$AgentRunMetricsTableTableFilterComposer({
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

  ColumnFilters<int> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get model => $composableBuilder(
    column: $table.model,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get helperModel => $composableBuilder(
    column: $table.helperModel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get auditModel => $composableBuilder(
    column: $table.auditModel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get promptTokens => $composableBuilder(
    column: $table.promptTokens,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get completionTokens => $composableBuilder(
    column: $table.completionTokens,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get totalTokens => $composableBuilder(
    column: $table.totalTokens,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get elapsedMs => $composableBuilder(
    column: $table.elapsedMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get toolCalls => $composableBuilder(
    column: $table.toolCalls,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get cacheHits => $composableBuilder(
    column: $table.cacheHits,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get dedupBlockedCalls => $composableBuilder(
    column: $table.dedupBlockedCalls,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get ragHits => $composableBuilder(
    column: $table.ragHits,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get approvalCount => $composableBuilder(
    column: $table.approvalCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get approvedCount => $composableBuilder(
    column: $table.approvedCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get auditCount => $composableBuilder(
    column: $table.auditCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get helperFanout => $composableBuilder(
    column: $table.helperFanout,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get success => $composableBuilder(
    column: $table.success,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get selectedToolSetJson => $composableBuilder(
    column: $table.selectedToolSetJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get memorySourcesJson => $composableBuilder(
    column: $table.memorySourcesJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AgentRunMetricsTableTableOrderingComposer
    extends Composer<_$AiDatabase, $AgentRunMetricsTableTable> {
  $$AgentRunMetricsTableTableOrderingComposer({
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

  ColumnOrderings<int> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get model => $composableBuilder(
    column: $table.model,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get helperModel => $composableBuilder(
    column: $table.helperModel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get auditModel => $composableBuilder(
    column: $table.auditModel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get promptTokens => $composableBuilder(
    column: $table.promptTokens,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get completionTokens => $composableBuilder(
    column: $table.completionTokens,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get totalTokens => $composableBuilder(
    column: $table.totalTokens,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get elapsedMs => $composableBuilder(
    column: $table.elapsedMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get toolCalls => $composableBuilder(
    column: $table.toolCalls,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get cacheHits => $composableBuilder(
    column: $table.cacheHits,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get dedupBlockedCalls => $composableBuilder(
    column: $table.dedupBlockedCalls,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get ragHits => $composableBuilder(
    column: $table.ragHits,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get approvalCount => $composableBuilder(
    column: $table.approvalCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get approvedCount => $composableBuilder(
    column: $table.approvedCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get auditCount => $composableBuilder(
    column: $table.auditCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get helperFanout => $composableBuilder(
    column: $table.helperFanout,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get success => $composableBuilder(
    column: $table.success,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get selectedToolSetJson => $composableBuilder(
    column: $table.selectedToolSetJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get memorySourcesJson => $composableBuilder(
    column: $table.memorySourcesJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AgentRunMetricsTableTableAnnotationComposer
    extends Composer<_$AiDatabase, $AgentRunMetricsTableTable> {
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
    column: $table.finishedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get model =>
      $composableBuilder(column: $table.model, builder: (column) => column);

  GeneratedColumn<String> get helperModel => $composableBuilder(
    column: $table.helperModel,
    builder: (column) => column,
  );

  GeneratedColumn<String> get auditModel => $composableBuilder(
    column: $table.auditModel,
    builder: (column) => column,
  );

  GeneratedColumn<int> get promptTokens => $composableBuilder(
    column: $table.promptTokens,
    builder: (column) => column,
  );

  GeneratedColumn<int> get completionTokens => $composableBuilder(
    column: $table.completionTokens,
    builder: (column) => column,
  );

  GeneratedColumn<int> get totalTokens => $composableBuilder(
    column: $table.totalTokens,
    builder: (column) => column,
  );

  GeneratedColumn<int> get elapsedMs =>
      $composableBuilder(column: $table.elapsedMs, builder: (column) => column);

  GeneratedColumn<int> get toolCalls =>
      $composableBuilder(column: $table.toolCalls, builder: (column) => column);

  GeneratedColumn<int> get cacheHits =>
      $composableBuilder(column: $table.cacheHits, builder: (column) => column);

  GeneratedColumn<int> get dedupBlockedCalls => $composableBuilder(
    column: $table.dedupBlockedCalls,
    builder: (column) => column,
  );

  GeneratedColumn<int> get ragHits =>
      $composableBuilder(column: $table.ragHits, builder: (column) => column);

  GeneratedColumn<int> get approvalCount => $composableBuilder(
    column: $table.approvalCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get approvedCount => $composableBuilder(
    column: $table.approvedCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get auditCount => $composableBuilder(
    column: $table.auditCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get helperFanout => $composableBuilder(
    column: $table.helperFanout,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get success =>
      $composableBuilder(column: $table.success, builder: (column) => column);

  GeneratedColumn<String> get selectedToolSetJson => $composableBuilder(
    column: $table.selectedToolSetJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get memorySourcesJson => $composableBuilder(
    column: $table.memorySourcesJson,
    builder: (column) => column,
  );
}

class $$AgentRunMetricsTableTableTableManager
    extends
        RootTableManager<
          _$AiDatabase,
          $AgentRunMetricsTableTable,
          AgentRunMetricRow,
          $$AgentRunMetricsTableTableFilterComposer,
          $$AgentRunMetricsTableTableOrderingComposer,
          $$AgentRunMetricsTableTableAnnotationComposer,
          $$AgentRunMetricsTableTableCreateCompanionBuilder,
          $$AgentRunMetricsTableTableUpdateCompanionBuilder,
          (
            AgentRunMetricRow,
            BaseReferences<
              _$AiDatabase,
              $AgentRunMetricsTableTable,
              AgentRunMetricRow
            >,
          ),
          AgentRunMetricRow,
          PrefetchHooks Function()
        > {
  $$AgentRunMetricsTableTableTableManager(
    _$AiDatabase db,
    $AgentRunMetricsTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AgentRunMetricsTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AgentRunMetricsTableTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$AgentRunMetricsTableTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
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
              }) => AgentRunMetricsTableCompanion(
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
          createCompanionCallback:
              ({
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
              }) => AgentRunMetricsTableCompanion.insert(
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
        ),
      );
}

typedef $$AgentRunMetricsTableTableProcessedTableManager =
    ProcessedTableManager<
      _$AiDatabase,
      $AgentRunMetricsTableTable,
      AgentRunMetricRow,
      $$AgentRunMetricsTableTableFilterComposer,
      $$AgentRunMetricsTableTableOrderingComposer,
      $$AgentRunMetricsTableTableAnnotationComposer,
      $$AgentRunMetricsTableTableCreateCompanionBuilder,
      $$AgentRunMetricsTableTableUpdateCompanionBuilder,
      (
        AgentRunMetricRow,
        BaseReferences<
          _$AiDatabase,
          $AgentRunMetricsTableTable,
          AgentRunMetricRow
        >,
      ),
      AgentRunMetricRow,
      PrefetchHooks Function()
    >;
typedef $$AgentTraceEventsTableTableCreateCompanionBuilder =
    AgentTraceEventsTableCompanion Function({
      required String id,
      required String runId,
      required String chatId,
      required int createdAt,
      required int sequence,
      required String kind,
      required String title,
      required String contentJson,
      Value<String?> toolName,
      Value<String> status,
      Value<int?> durationMs,
      Value<String?> parentEventId,
      Value<int> rowid,
    });
typedef $$AgentTraceEventsTableTableUpdateCompanionBuilder =
    AgentTraceEventsTableCompanion Function({
      Value<String> id,
      Value<String> runId,
      Value<String> chatId,
      Value<int> createdAt,
      Value<int> sequence,
      Value<String> kind,
      Value<String> title,
      Value<String> contentJson,
      Value<String?> toolName,
      Value<String> status,
      Value<int?> durationMs,
      Value<String?> parentEventId,
      Value<int> rowid,
    });

class $$AgentTraceEventsTableTableFilterComposer
    extends Composer<_$AiDatabase, $AgentTraceEventsTableTable> {
  $$AgentTraceEventsTableTableFilterComposer({
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

  ColumnFilters<String> get runId => $composableBuilder(
    column: $table.runId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get chatId => $composableBuilder(
    column: $table.chatId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sequence => $composableBuilder(
    column: $table.sequence,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contentJson => $composableBuilder(
    column: $table.contentJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get toolName => $composableBuilder(
    column: $table.toolName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get parentEventId => $composableBuilder(
    column: $table.parentEventId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AgentTraceEventsTableTableOrderingComposer
    extends Composer<_$AiDatabase, $AgentTraceEventsTableTable> {
  $$AgentTraceEventsTableTableOrderingComposer({
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

  ColumnOrderings<String> get runId => $composableBuilder(
    column: $table.runId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get chatId => $composableBuilder(
    column: $table.chatId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sequence => $composableBuilder(
    column: $table.sequence,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contentJson => $composableBuilder(
    column: $table.contentJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get toolName => $composableBuilder(
    column: $table.toolName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get parentEventId => $composableBuilder(
    column: $table.parentEventId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AgentTraceEventsTableTableAnnotationComposer
    extends Composer<_$AiDatabase, $AgentTraceEventsTableTable> {
  $$AgentTraceEventsTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get runId =>
      $composableBuilder(column: $table.runId, builder: (column) => column);

  GeneratedColumn<String> get chatId =>
      $composableBuilder(column: $table.chatId, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get sequence =>
      $composableBuilder(column: $table.sequence, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get contentJson => $composableBuilder(
    column: $table.contentJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get toolName =>
      $composableBuilder(column: $table.toolName, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => column,
  );

  GeneratedColumn<String> get parentEventId => $composableBuilder(
    column: $table.parentEventId,
    builder: (column) => column,
  );
}

class $$AgentTraceEventsTableTableTableManager
    extends
        RootTableManager<
          _$AiDatabase,
          $AgentTraceEventsTableTable,
          AgentTraceEventRow,
          $$AgentTraceEventsTableTableFilterComposer,
          $$AgentTraceEventsTableTableOrderingComposer,
          $$AgentTraceEventsTableTableAnnotationComposer,
          $$AgentTraceEventsTableTableCreateCompanionBuilder,
          $$AgentTraceEventsTableTableUpdateCompanionBuilder,
          (
            AgentTraceEventRow,
            BaseReferences<
              _$AiDatabase,
              $AgentTraceEventsTableTable,
              AgentTraceEventRow
            >,
          ),
          AgentTraceEventRow,
          PrefetchHooks Function()
        > {
  $$AgentTraceEventsTableTableTableManager(
    _$AiDatabase db,
    $AgentTraceEventsTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AgentTraceEventsTableTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$AgentTraceEventsTableTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$AgentTraceEventsTableTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> runId = const Value.absent(),
                Value<String> chatId = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> sequence = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> contentJson = const Value.absent(),
                Value<String?> toolName = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int?> durationMs = const Value.absent(),
                Value<String?> parentEventId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AgentTraceEventsTableCompanion(
                id: id,
                runId: runId,
                chatId: chatId,
                createdAt: createdAt,
                sequence: sequence,
                kind: kind,
                title: title,
                contentJson: contentJson,
                toolName: toolName,
                status: status,
                durationMs: durationMs,
                parentEventId: parentEventId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String runId,
                required String chatId,
                required int createdAt,
                required int sequence,
                required String kind,
                required String title,
                required String contentJson,
                Value<String?> toolName = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int?> durationMs = const Value.absent(),
                Value<String?> parentEventId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AgentTraceEventsTableCompanion.insert(
                id: id,
                runId: runId,
                chatId: chatId,
                createdAt: createdAt,
                sequence: sequence,
                kind: kind,
                title: title,
                contentJson: contentJson,
                toolName: toolName,
                status: status,
                durationMs: durationMs,
                parentEventId: parentEventId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AgentTraceEventsTableTableProcessedTableManager =
    ProcessedTableManager<
      _$AiDatabase,
      $AgentTraceEventsTableTable,
      AgentTraceEventRow,
      $$AgentTraceEventsTableTableFilterComposer,
      $$AgentTraceEventsTableTableOrderingComposer,
      $$AgentTraceEventsTableTableAnnotationComposer,
      $$AgentTraceEventsTableTableCreateCompanionBuilder,
      $$AgentTraceEventsTableTableUpdateCompanionBuilder,
      (
        AgentTraceEventRow,
        BaseReferences<
          _$AiDatabase,
          $AgentTraceEventsTableTable,
          AgentTraceEventRow
        >,
      ),
      AgentTraceEventRow,
      PrefetchHooks Function()
    >;

class $AiDatabaseManager {
  final _$AiDatabase _db;
  $AiDatabaseManager(this._db);
  $$AiChatsTableTableManager get aiChats =>
      $$AiChatsTableTableManager(_db, _db.aiChats);
  $$AiChatMessagesTableTableManager get aiChatMessages =>
      $$AiChatMessagesTableTableManager(_db, _db.aiChatMessages);
  $$AgentRunMetricsTableTableTableManager get agentRunMetricsTable =>
      $$AgentRunMetricsTableTableTableManager(_db, _db.agentRunMetricsTable);
  $$AgentTraceEventsTableTableTableManager get agentTraceEventsTable =>
      $$AgentTraceEventsTableTableTableManager(_db, _db.agentTraceEventsTable);
}

mixin _$AiChatDaoMixin on DatabaseAccessor<AiDatabase> {
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
        _db.attachedDatabase,
        _db.aiChatMessages,
      );
}

mixin _$AgentMetricsDaoMixin on DatabaseAccessor<AiDatabase> {
  $AgentRunMetricsTableTable get agentRunMetricsTable =>
      attachedDatabase.agentRunMetricsTable;
  AgentMetricsDaoManager get managers => AgentMetricsDaoManager(this);
}

class AgentMetricsDaoManager {
  final _$AgentMetricsDaoMixin _db;
  AgentMetricsDaoManager(this._db);
  $$AgentRunMetricsTableTableTableManager get agentRunMetricsTable =>
      $$AgentRunMetricsTableTableTableManager(
        _db.attachedDatabase,
        _db.agentRunMetricsTable,
      );
}

mixin _$AgentTraceDaoMixin on DatabaseAccessor<AiDatabase> {
  $AgentTraceEventsTableTable get agentTraceEventsTable =>
      attachedDatabase.agentTraceEventsTable;
  AgentTraceDaoManager get managers => AgentTraceDaoManager(this);
}

class AgentTraceDaoManager {
  final _$AgentTraceDaoMixin _db;
  AgentTraceDaoManager(this._db);
  $$AgentTraceEventsTableTableTableManager get agentTraceEventsTable =>
      $$AgentTraceEventsTableTableTableManager(
        _db.attachedDatabase,
        _db.agentTraceEventsTable,
      );
}
