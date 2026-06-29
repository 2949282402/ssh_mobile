part of '../app_database.dart';

class AiChats extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get model => text()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  BoolColumn get planMode => boolean().withDefault(const Constant(false))();
  IntColumn get approvedPlanAssistantCreatedAt => integer().nullable()();
  IntColumn get approvedPlanApprovedAt => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  List<Index> get indexes => [
        Index(
          'idx_ai_chats_updated_at',
          'CREATE INDEX idx_ai_chats_updated_at '
              'ON ai_chats(updated_at DESC)',
        ),
      ];
}

class AiChatMessages extends Table {
  TextColumn get id => text()();
  TextColumn get chatId => text().references(
        AiChats,
        #id,
        onDelete: KeyAction.cascade,
      )();
  TextColumn get role => text()();
  TextColumn get textContent => text().named('text')();
  TextColumn get contextText => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get promptTokens => integer().nullable()();
  IntColumn get completionTokens => integer().nullable()();
  IntColumn get totalTokens => integer().nullable()();
  IntColumn get elapsedMs => integer().nullable()();
  BoolColumn get tokenUsageEstimated => boolean().nullable()();
  IntColumn get promptCacheHitTokens => integer().nullable()();
  IntColumn get promptCacheMissTokens => integer().nullable()();
  IntColumn get reasoningTokens => integer().nullable()();
  TextColumn get agentRunId => text().nullable()();
  TextColumn get attachmentsJson => text().withDefault(const Constant('[]'))();
  TextColumn get tracesJson => text().withDefault(const Constant('[]'))();
  TextColumn get todoStepsJson => text().withDefault(const Constant('[]'))();

  @override
  Set<Column<Object>> get primaryKey => {id};

  List<Index> get indexes => [
        Index(
          'idx_ai_chat_messages_chat_created',
          'CREATE INDEX idx_ai_chat_messages_chat_created '
              'ON ai_chat_messages(chat_id, created_at ASC)',
        ),
      ];
}
