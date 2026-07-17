part of '../storage_service.dart';

const Uuid _traceUuid = Uuid();

/// 中央持久化服务。管理应用的所有数据持久化，采用分层存储策略：
///
/// | 数据类型 | 存储位置 | 加密方式 |
/// |---|---|---|
/// | SSH 密码、私钥、API Key | FlutterSecureStorage | 平台原生加密 |
/// | 主题、语言、字体、小设置 | SharedPreferences | 明文 |
/// | 未迁移的兼容数据 | SharedPreferences + DataProtection | AES-256-GCM |
/// | 增长型结构化数据 | Drift SQLite | metadata 明文，敏感正文字段级加密 |
///
/// 不要把凭据写入 Drift；AI message、tool trace、todoSteps 和 Playbook
/// content 等敏感正文不得以明文 Drift column 保存。生产环境数据库打开失败时
/// 不得 fallback 到内存数据库，调用方应退回旧 protected-pref 兼容路径。
///
/// 旧 protected-pref 写入仍使用 700ms 防抖；Drift-backed 数据通过 DAO
/// transaction 持久化。历史 Drift 明文敏感字段由
/// drift_sensitive_fields_encrypted_v1 启动迁移重加密。
abstract interface class ConnectionRepository {
  List<ConnectionConfig> get connections;
  Future<void> addConnection(ConnectionConfig config);
  Future<void> updateConnection(ConnectionConfig config);
  Future<void> deleteConnection(String id);
  Future<void> deleteConnections(List<String> ids);
  Future<void> reorderConnections(int oldIndex, int newIndex);
  ConnectionConfig? getConnection(String id);
  Future<String?> getPassword(String id);
  Future<String?> getPrivateKey(String id);
}

abstract interface class AiSettingsRepository {
  Future<AiConnectionSettings> loadAiConnectionSettings();
  Future<AiRuntimeConnectionSnapshot> loadAiRuntimeConnectionSnapshot();

  Future<void> saveAiConnectionSettings({
    required String baseUrl,
    required String model,
    String? helperModel,
    String? auditModel,
    String? modelFallbackPolicy,
    int? contextWindowTokens,
    int? timeoutSeconds,
    bool? deepSeekThinkingEnabled,
    String? deepSeekReasoningEffort,
    String? openAiReasoningEffort,
    bool? webSearchEnabled,
    int? webSearchMaxResults,
    String? webSearchEngine,
    bool? multiAgentEnabled,
    int? multiAgentMaxAgents,
    bool? postToolReviewEnabled,
    int? toolCallBudget,
    String? agentLoopMode,
    int? maxImageSizeBytes,
    int? maxFileSizeBytes,
    String? apiKey,
    String? selectedApiKeyId,
    bool clearApiKey,
    String? quarkSearchEndpoint,
    String? quarkApiKey,
    bool clearQuarkApiKey,
    bool? useCustomPrompts,
    String? customSystemPrompt,
    String? customPlannerPrompt,
    String? customOperatorPrompt,
    String? customExplorePrompt,
    String? customReviewerPrompt,
    String? customSummarizerPrompt,
    String? customCoordinatorPrompt,
    LlmApiFormat? apiFormat,
  });

  Future<String?> getAiApiKey();
  Future<String?> getQuarkApiKey();
  Future<void> saveQuarkApiKey(String key);
  Future<String?> getAliyunApiKey();
  Future<void> saveAliyunApiKey(String key);
  Future<String?> getSelectedAiApiKeyId();

  Future<List<String>> loadAiBaseUrlHistory();
  Future<List<String>> loadCachedAiModels({String? baseUrl});
  Future<void> removeAiBaseUrlHistoryEntry(String baseUrl);
  Future<void> removeAiApiKeyHistoryEntry(String id);
  Future<List<AiApiKeyHistoryEntry>> loadAiApiKeyHistory();
  Future<String?> getAiApiKeyById(String id);
  Future<void> saveCachedAiModels({
    required String baseUrl,
    required Iterable<String> models,
  });
  Future<void> clearCachedAiModels({String? baseUrl});
  Future<int> getAiRequestTimeoutSeconds();
  Future<void> selectAiApiKey(String id);
  Future<void> deleteAiApiKey(String id);

  bool get isSecretCacheEnabled;
  Future<void> setSecretCacheEnabled(bool enabled);
  Duration get secretCacheTtl;
  Future<void> setSecretCacheTtl(Duration ttl);
  void clearSecretCache();
}

abstract interface class AiChatRepository {
  Future<List<AiChatRecord>> loadAiChats();
  Future<void> saveAiChat(AiChatRecord chat);
  Future<void> deleteAiChat(String id);
}

abstract interface class AiSkillRepository {
  Future<List<AiSkillRecord>> loadAiSkills();
  Future<void> saveAiSkill(AiSkillRecord skill);
  Future<void> deleteAiSkill(String id);
}

abstract interface class AgentRunMetricsRepository {
  Future<List<AgentRunMetrics>> loadAgentRunMetrics();
  Future<void> saveAgentRunMetrics(AgentRunMetrics metrics);
}

abstract interface class AgentTraceRepository {
  Future<List<AgentTraceEvent>> loadAgentTraceEvents(String runId);
  Future<List<String>> loadRecentAgentTraceRunIdsForChat(
    String chatId, {
    int limit,
  });
  Future<void> saveAgentTraceEvent(AgentTraceEvent event);
  Future<void> saveAgentTraceEvents(List<AgentTraceEvent> events);
  Future<void> deleteAgentTraceEvents(String runId);
}

abstract interface class TerminalHistoryRepository {
  Future<List<TerminalHistoryRecord>> loadTerminalHistoryRecords();
  Future<void> saveTerminalHistoryRecord(TerminalHistoryRecord record);
  Future<void> removeTerminalHistoryRecord(String sessionId);
}

abstract interface class PlaybookRepository {
  Future<List<Playbook>> loadPlaybooks();
  Future<void> savePlaybook(Playbook playbook);
  Future<void> deletePlaybook(String id);
}

abstract interface class SftpPathHistoryRepository {
  Future<void> recordVisitedPath(String connectionId, String path);
  Future<List<SftpRecentPathRecord>> loadRecentPaths(
    String connectionId, {
    int limit,
  });
  Future<SftpFavoritePathRecord> addFavoritePath(
    String connectionId,
    String path,
    String name,
  );
  Future<void> removeFavoritePath(String id);
  Future<void> renameFavoritePath(String id, String name);
  Future<List<SftpFavoritePathRecord>> loadFavoritePaths(String connectionId);
  Future<SftpFavoritePathRecord?> findFavoritePath(
    String connectionId,
    String path,
  );
}

abstract interface class AppBackupRepository {
  Future<String> exportAppDataJson();
  Future<void> importAppDataJson(String jsonText);
}
