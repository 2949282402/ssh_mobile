part of '../../services/storage_service.dart';

extension DriftAiChatRepositoryOps on StorageService {
  Future<List<AiChatRecord>> _loadDriftAiChats() async {
    final database = _database;
    if (!_driftAiChatsActive || database == null) return const [];
    final rows = await database.aiChatDao.loadChats();
    final chats = rows.map(_aiChatFromDrift).toList(growable: false);
    return _aiChatsCache = List.unmodifiable(chats);
  }

  Future<void> _saveDriftAiChat(AiChatRecord chat) async {
    final database = _database;
    if (!_driftAiChatsActive || database == null) return;
    await database.aiChatDao.saveChat(
      _aiChatToCompanion(chat),
      _aiChatMessagesToCompanions(chat),
    );
    final chats = upsertAiChatRecordsByUpdatedAt(
      _aiChatsCache ?? const <AiChatRecord>[],
      chat,
      limit: 80,
    );
    _aiChatsCache = List.unmodifiable(chats);
  }

  Future<void> _deleteDriftAiChat(String id) async {
    final database = _database;
    if (!_driftAiChatsActive || database == null) return;
    await database.aiChatDao.deleteChat(id);
    final cached = _aiChatsCache;
    if (cached != null) {
      _aiChatsCache = List.unmodifiable(
        cached.where((item) => item.id != id).toList(growable: false),
      );
    }
  }

  Future<void> _replaceDriftAiChats(List<AiChatRecord> chats) async {
    final database = _database;
    if (!_driftReady || database == null) return;
    final ordered = [...chats]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final companions = ordered.map(_aiChatToCompanion).toList(growable: false);
    final messagesByChatId = <String, List<db.AiChatMessagesCompanion>>{};
    for (final chat in ordered) {
      messagesByChatId[chat.id] = _aiChatMessagesToCompanions(chat);
    }
    await database.aiChatDao.replaceAllChats(companions, messagesByChatId);
    _aiChatsCache = List.unmodifiable(ordered);
  }

  db.AiChatsCompanion _aiChatToCompanion(AiChatRecord chat) {
    return db.AiChatsCompanion(
      id: drift.Value(chat.id),
      title: drift.Value(chat.title),
      model: drift.Value(chat.model),
      createdAt: drift.Value(_toDbMillis(chat.createdAt)),
      updatedAt: drift.Value(_toDbMillis(chat.updatedAt)),
      planMode: drift.Value(chat.planMode),
      approvedPlanAssistantCreatedAt: drift.Value(chat.approvedPlan == null
          ? null
          : _toDbMillis(chat.approvedPlan!.assistantCreatedAt)),
      approvedPlanApprovedAt: drift.Value(chat.approvedPlan == null
          ? null
          : _toDbMillis(chat.approvedPlan!.approvedAt)),
    );
  }

  List<db.AiChatMessagesCompanion> _aiChatMessagesToCompanions(
    AiChatRecord chat,
  ) {
    return [
      for (var index = 0; index < chat.messages.length; index++)
        _aiChatMessageToCompanion(chat.id, chat.messages[index], index),
    ];
  }

  db.AiChatMessagesCompanion _aiChatMessageToCompanion(
    String chatId,
    AiChatMessageRecord message,
    int index,
  ) {
    return db.AiChatMessagesCompanion(
      id: drift.Value(_messageId(chatId, message, index)),
      chatId: drift.Value(chatId),
      role: drift.Value(message.role),
      textContent: drift.Value(message.text),
      contextText: drift.Value(message.contextText),
      createdAt: drift.Value(_toDbMillis(message.createdAt)),
      promptTokens: drift.Value(message.promptTokens),
      completionTokens: drift.Value(message.completionTokens),
      totalTokens: drift.Value(message.totalTokens),
      elapsedMs: drift.Value(message.elapsedMs),
      tokenUsageEstimated: drift.Value(message.tokenUsageEstimated),
      promptCacheHitTokens: drift.Value(message.promptCacheHitTokens),
      promptCacheMissTokens: drift.Value(message.promptCacheMissTokens),
      reasoningTokens: drift.Value(message.reasoningTokens),
      attachmentsJson: drift.Value(
        _encodeJsonList(message.attachments.map((item) => item.toJson())),
      ),
      tracesJson: drift.Value(
        _encodeJsonList(message.traces.map((item) => item.toJson())),
      ),
      todoStepsJson: drift.Value(
        _encodeJsonList(message.todoSteps.map((item) => item.toJson())),
      ),
    );
  }

  AiChatRecord _aiChatFromDrift(db.AiChatWithMessages row) {
    final approvedAssistant = row.chat.approvedPlanAssistantCreatedAt;
    final approvedAt = row.chat.approvedPlanApprovedAt;
    return AiChatRecord(
      id: row.chat.id,
      title: row.chat.title,
      model: row.chat.model,
      messages: row.messages.map(_aiChatMessageFromDrift).toList(),
      createdAt: _fromDbMillis(row.chat.createdAt),
      updatedAt: _fromDbMillis(row.chat.updatedAt),
      planMode: row.chat.planMode,
      approvedPlan: approvedAssistant == null || approvedAt == null
          ? null
          : AiApprovedPlanRef(
              assistantCreatedAt: _fromDbMillis(approvedAssistant),
              approvedAt: _fromDbMillis(approvedAt),
            ),
    );
  }

  AiChatMessageRecord _aiChatMessageFromDrift(db.AiChatMessage row) {
    return AiChatMessageRecord(
      role: row.role,
      text: row.textContent,
      contextText: row.contextText,
      attachments:
          _decodeJsonList(row.attachmentsJson, AiChatAttachment.fromJson),
      traces: _decodeJsonList(row.tracesJson, AiMessageTrace.fromJson),
      createdAt: _fromDbMillis(row.createdAt),
      promptTokens: row.promptTokens,
      completionTokens: row.completionTokens,
      totalTokens: row.totalTokens,
      elapsedMs: row.elapsedMs,
      tokenUsageEstimated: row.tokenUsageEstimated,
      promptCacheHitTokens: row.promptCacheHitTokens,
      promptCacheMissTokens: row.promptCacheMissTokens,
      reasoningTokens: row.reasoningTokens,
      todoSteps: _decodeJsonList(row.todoStepsJson, AiTodoStep.fromJson),
    );
  }

  String _messageId(String chatId, AiChatMessageRecord message, int index) {
    final ordinal = index.toString().padLeft(6, '0');
    return '$chatId:${message.createdAt.microsecondsSinceEpoch}:$ordinal';
  }
}
