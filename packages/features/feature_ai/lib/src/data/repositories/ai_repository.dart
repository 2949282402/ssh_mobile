// AI Feature 的持久化边界。
//
// Repository 只负责 ai.db 中的聊天、Agent 指标和 trace；设置、技能和连接
// 目录仍通过 AiStoragePort 访问。数据库句柄由 AiModule 持有，Repository
// 不能自行关闭数据库，也不能在数据库失败时静默切换到内存实现。

import 'dart:convert';

import 'package:drift/drift.dart' as drift;

import '../../domain/ai_models.dart';
import '../database/ai_database.dart' as db;

/// AI 敏感正文的加解密能力；实现由 App Shell 的安全服务注入。
abstract interface class AiTextProtectionPort {
  Future<String> encrypt(String plainText);

  Future<String> decrypt(String storedText);
}

/// AI 数据库 Repository 公共契约。
abstract interface class AgentTraceRepository {
  Future<void> saveAgentTraceEvents(List<AgentTraceEvent> events);
}

/// AI 数据库 Repository 公共契约。
abstract interface class AiRepository implements AgentTraceRepository {
  Future<List<AiChatRecord>> loadChats();

  Future<void> saveChat(AiChatRecord chat);

  Future<void> deleteChat(String id);

  Future<void> replaceChats(List<AiChatRecord> chats);

  Future<List<AgentRunMetrics>> loadRunMetrics();

  Future<void> saveRunMetrics(AgentRunMetrics metrics);

  Future<void> replaceRunMetrics(List<AgentRunMetrics> metrics);

  Future<List<AgentTraceEvent>> loadTraceEvents(String runId);

  Future<List<String>> loadRecentTraceRunIdsForChat(String chatId, {int limit});

  Future<void> saveTraceEvent(AgentTraceEvent event);

  Future<void> saveTraceEvents(List<AgentTraceEvent> events);

  Future<void> deleteTraceEvents(String runId);

  @override
  Future<void> saveAgentTraceEvents(List<AgentTraceEvent> events);
}

/// 基于 Drift 的 AI Repository 实现。
final class DriftAiRepository implements AiRepository {
  DriftAiRepository(this._database, this._protection);

  final db.AiDatabase _database;
  final AiTextProtectionPort _protection;

  @override
  Future<List<AiChatRecord>> loadChats() async {
    final rows = await _database.aiChatDao.loadChats();
    return List.unmodifiable([for (final row in rows) await _chatFromRow(row)]);
  }

  @override
  Future<void> saveChat(AiChatRecord chat) async {
    await _database.aiChatDao.saveChat(
      _chatCompanion(chat),
      await _messageCompanions(chat),
    );
  }

  @override
  Future<void> deleteChat(String id) => _database.aiChatDao.deleteChat(id);

  @override
  Future<void> replaceChats(List<AiChatRecord> chats) async {
    final ordered = [...chats]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final retained = ordered.take(80).toList(growable: false);
    final messages = <String, List<db.AiChatMessagesCompanion>>{};
    for (final chat in retained) {
      messages[chat.id] = await _messageCompanions(chat);
    }
    await _database.aiChatDao.replaceAllChats(
      retained.map(_chatCompanion).toList(growable: false),
      messages,
    );
  }

  @override
  Future<List<AgentRunMetrics>> loadRunMetrics() async {
    final rows = await _database.agentMetricsDao.loadMetrics();
    return List.unmodifiable(rows.map(_metricsFromRow));
  }

  @override
  Future<void> saveRunMetrics(AgentRunMetrics metrics) =>
      _database.agentMetricsDao.saveMetric(_metricsCompanion(metrics));

  @override
  Future<void> replaceRunMetrics(List<AgentRunMetrics> metrics) =>
      _database.agentMetricsDao.replaceAllMetrics(
        metrics.map(_metricsCompanion).toList(growable: false),
      );

  @override
  Future<List<AgentTraceEvent>> loadTraceEvents(String runId) async {
    final rows = await _database.agentTraceDao.loadEventsForRun(runId.trim());
    return List.unmodifiable([
      for (final row in rows) await _traceFromRow(row),
    ]);
  }

  @override
  Future<List<String>> loadRecentTraceRunIdsForChat(
    String chatId, {
    int limit = 20,
  }) => _database.agentTraceDao.loadRecentRunIdsForChat(chatId, limit: limit);

  @override
  Future<void> saveTraceEvent(AgentTraceEvent event) =>
      saveTraceEvents([event]);

  @override
  Future<void> saveTraceEvents(List<AgentTraceEvent> events) async {
    final companions = <db.AgentTraceEventsTableCompanion>[];
    final runCounts = <String, int>{};
    for (final event in events) {
      final count = runCounts[event.runId] ?? 0;
      if (count >= agentTraceEventsPerRunLimit) continue;
      runCounts[event.runId] = count + 1;
      companions.add(await _traceCompanion(event));
    }
    await _database.agentTraceDao.saveEvents(companions);
  }

  @override
  Future<void> saveAgentTraceEvents(List<AgentTraceEvent> events) =>
      saveTraceEvents(events);

  @override
  Future<void> deleteTraceEvents(String runId) =>
      _database.agentTraceDao.deleteEventsForRun(runId.trim());

  db.AiChatsCompanion _chatCompanion(AiChatRecord chat) {
    return db.AiChatsCompanion(
      id: drift.Value(chat.id),
      title: drift.Value(chat.title),
      model: drift.Value(chat.model),
      createdAt: drift.Value(_toDbMillis(chat.createdAt)),
      updatedAt: drift.Value(_toDbMillis(chat.updatedAt)),
      planMode: drift.Value(chat.planMode),
      approvedPlanAssistantCreatedAt: drift.Value(
        chat.approvedPlan == null
            ? null
            : _toDbMillis(chat.approvedPlan!.assistantCreatedAt),
      ),
      approvedPlanApprovedAt: drift.Value(
        chat.approvedPlan == null
            ? null
            : _toDbMillis(chat.approvedPlan!.approvedAt),
      ),
    );
  }

  Future<List<db.AiChatMessagesCompanion>> _messageCompanions(
    AiChatRecord chat,
  ) async {
    final result = <db.AiChatMessagesCompanion>[];
    for (var index = 0; index < chat.messages.length; index++) {
      final message = chat.messages[index];
      result.add(
        db.AiChatMessagesCompanion(
          id: drift.Value(
            '${chat.id}:${message.createdAt.microsecondsSinceEpoch}:${index.toString().padLeft(6, '0')}',
          ),
          chatId: drift.Value(chat.id),
          role: drift.Value(message.role),
          textContent: drift.Value(await _protection.encrypt(message.text)),
          contextText: drift.Value(
            message.contextText == null
                ? null
                : await _protection.encrypt(message.contextText!),
          ),
          createdAt: drift.Value(_toDbMillis(message.createdAt)),
          promptTokens: drift.Value(message.promptTokens),
          completionTokens: drift.Value(message.completionTokens),
          totalTokens: drift.Value(message.totalTokens),
          elapsedMs: drift.Value(message.elapsedMs),
          tokenUsageEstimated: drift.Value(message.tokenUsageEstimated),
          promptCacheHitTokens: drift.Value(message.promptCacheHitTokens),
          promptCacheMissTokens: drift.Value(message.promptCacheMissTokens),
          reasoningTokens: drift.Value(message.reasoningTokens),
          agentRunId: drift.Value(message.agentRunId),
          attachmentsJson: drift.Value(
            await _protection.encrypt(
              jsonEncode(
                message.attachments.map((item) => item.toJson()).toList(),
              ),
            ),
          ),
          tracesJson: drift.Value(
            await _protection.encrypt(
              jsonEncode(message.traces.map((item) => item.toJson()).toList()),
            ),
          ),
          todoStepsJson: drift.Value(
            await _protection.encrypt(
              jsonEncode(
                message.todoSteps.map((item) => item.toJson()).toList(),
              ),
            ),
          ),
        ),
      );
    }
    return result;
  }

  Future<AiChatRecord> _chatFromRow(db.AiChatWithMessages row) async {
    final assistantAt = row.chat.approvedPlanAssistantCreatedAt;
    final approvedAt = row.chat.approvedPlanApprovedAt;
    return AiChatRecord(
      id: row.chat.id,
      title: row.chat.title,
      model: row.chat.model,
      messages: [
        for (final message in row.messages) await _messageFromRow(message),
      ],
      createdAt: _fromDbMillis(row.chat.createdAt),
      updatedAt: _fromDbMillis(row.chat.updatedAt),
      planMode: row.chat.planMode,
      approvedPlan: assistantAt == null || approvedAt == null
          ? null
          : AiApprovedPlanRef(
              assistantCreatedAt: _fromDbMillis(assistantAt),
              approvedAt: _fromDbMillis(approvedAt),
            ),
    );
  }

  Future<AiChatMessageRecord> _messageFromRow(db.AiChatMessage row) async {
    return AiChatMessageRecord(
      role: row.role,
      text: await _protection.decrypt(row.textContent),
      contextText: row.contextText == null
          ? null
          : await _protection.decrypt(row.contextText!),
      attachments: _decodeList(
        await _protection.decrypt(row.attachmentsJson),
        AiChatAttachment.fromJson,
      ),
      traces: _decodeList(
        await _protection.decrypt(row.tracesJson),
        AiMessageTrace.fromJson,
      ),
      createdAt: _fromDbMillis(row.createdAt),
      promptTokens: row.promptTokens,
      completionTokens: row.completionTokens,
      totalTokens: row.totalTokens,
      elapsedMs: row.elapsedMs,
      tokenUsageEstimated: row.tokenUsageEstimated,
      promptCacheHitTokens: row.promptCacheHitTokens,
      promptCacheMissTokens: row.promptCacheMissTokens,
      reasoningTokens: row.reasoningTokens,
      todoSteps: _decodeList(
        await _protection.decrypt(row.todoStepsJson),
        AiTodoStep.fromJson,
      ),
      agentRunId: row.agentRunId,
    );
  }

  db.AgentRunMetricsTableCompanion _metricsCompanion(AgentRunMetrics metric) =>
      db.AgentRunMetricsTableCompanion(
        id: drift.Value(metric.id),
        startedAt: drift.Value(_toDbMillis(metric.startedAt)),
        finishedAt: drift.Value(_toDbMillis(metric.finishedAt)),
        model: drift.Value(metric.model),
        helperModel: drift.Value(metric.helperModel),
        auditModel: drift.Value(metric.auditModel),
        promptTokens: drift.Value(metric.promptTokens),
        completionTokens: drift.Value(metric.completionTokens),
        totalTokens: drift.Value(metric.totalTokens),
        elapsedMs: drift.Value(metric.elapsedMs),
        toolCalls: drift.Value(metric.toolCalls),
        cacheHits: drift.Value(metric.cacheHits),
        dedupBlockedCalls: drift.Value(metric.dedupBlockedCalls),
        ragHits: drift.Value(metric.ragHits),
        approvalCount: drift.Value(metric.approvalCount),
        approvedCount: drift.Value(metric.approvedCount),
        auditCount: drift.Value(metric.auditCount),
        helperFanout: drift.Value(metric.helperFanout),
        success: drift.Value(metric.success),
        selectedToolSetJson: drift.Value(jsonEncode(metric.selectedToolSet)),
        memorySourcesJson: drift.Value(jsonEncode(metric.memorySources)),
      );

  AgentRunMetrics _metricsFromRow(db.AgentRunMetricRow row) => AgentRunMetrics(
    id: row.id,
    startedAt: _fromDbMillis(row.startedAt),
    finishedAt: _fromDbMillis(row.finishedAt),
    model: row.model,
    helperModel: row.helperModel,
    auditModel: row.auditModel,
    promptTokens: row.promptTokens,
    completionTokens: row.completionTokens,
    totalTokens: row.totalTokens,
    elapsedMs: row.elapsedMs,
    toolCalls: row.toolCalls,
    cacheHits: row.cacheHits,
    dedupBlockedCalls: row.dedupBlockedCalls,
    ragHits: row.ragHits,
    approvalCount: row.approvalCount,
    approvedCount: row.approvedCount,
    auditCount: row.auditCount,
    helperFanout: row.helperFanout,
    success: row.success,
    selectedToolSet: _decodeStringList(row.selectedToolSetJson),
    memorySources: _decodeStringList(row.memorySourcesJson),
  );

  Future<db.AgentTraceEventsTableCompanion> _traceCompanion(
    AgentTraceEvent event,
  ) async => db.AgentTraceEventsTableCompanion(
    id: drift.Value(event.id),
    runId: drift.Value(event.runId),
    chatId: drift.Value(event.chatId),
    createdAt: drift.Value(_toDbMillis(event.createdAt)),
    sequence: drift.Value(event.sequence),
    kind: drift.Value(event.kind),
    title: drift.Value(event.title),
    contentJson: drift.Value(
      await _protection.encrypt(
        jsonEncode({'content': event.content, 'truncated': event.truncated}),
      ),
    ),
    toolName: drift.Value(event.toolName),
    status: drift.Value(event.status),
    durationMs: drift.Value(event.durationMs),
    parentEventId: drift.Value(event.parentEventId),
  );

  Future<AgentTraceEvent> _traceFromRow(db.AgentTraceEventRow row) async {
    final decoded = jsonDecode(await _protection.decrypt(row.contentJson));
    final content = decoded is Map
        ? decoded['content'] as String? ?? ''
        : '$decoded';
    final truncated = decoded is Map && decoded['truncated'] == true;
    return AgentTraceEvent(
      id: row.id,
      runId: row.runId,
      chatId: row.chatId,
      createdAt: _fromDbMillis(row.createdAt),
      sequence: row.sequence,
      kind: row.kind,
      title: row.title,
      content: content,
      toolName: row.toolName,
      status: row.status,
      durationMs: row.durationMs,
      parentEventId: row.parentEventId,
      truncated: truncated,
    );
  }

  List<T> _decodeList<T>(
    String jsonText,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    final value = jsonDecode(jsonText);
    if (value is! List) return const [];
    return [
      for (final item in value)
        if (item is Map<String, dynamic>) fromJson(item),
    ];
  }

  List<String> _decodeStringList(String jsonText) {
    final value = jsonDecode(jsonText);
    if (value is! List) return const [];
    return value.map((item) => '$item').toList(growable: false);
  }

  int _toDbMillis(DateTime value) => value.toUtc().millisecondsSinceEpoch;

  DateTime _fromDbMillis(int value) =>
      DateTime.fromMillisecondsSinceEpoch(value, isUtc: true).toLocal();
}
