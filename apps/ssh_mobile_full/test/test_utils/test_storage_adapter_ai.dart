part of 'test_storage_adapter.dart';

/// Owns AI persistence facade operations.
mixin _TestStorageAdapterAi on _TestStorageAdapterBase {
  Future<List<ai.AiChatRecord>> loadAiChats() => _delegate.loadAiChats();
  Future<void> saveAiChat(ai.AiChatRecord chat) => _delegate.saveAiChat(chat);
  Future<void> deleteAiChat(String id) => _delegate.deleteAiChat(id);
  Future<void> replaceAiChats(List<ai.AiChatRecord> chats) =>
      _delegate.replaceAiChats(chats);
  Future<List<ai.AiSkillRecord>> loadAiSkills() => _delegate.loadAiSkills();
  Future<void> saveAiSkill(ai.AiSkillRecord skill) =>
      _delegate.saveAiSkill(skill);
  Future<bool> saveAiSkillIfUnchanged(
    ai.AiSkillRecord expected,
    ai.AiSkillRecord next,
  ) => _delegate.saveAiSkillIfUnchanged(expected, next);
  Future<void> deleteAiSkill(String id) => _delegate.deleteAiSkill(id);
  Future<List<ai.AgentRunMetrics>> loadAgentRunMetrics() =>
      _delegate.loadAgentRunMetrics();
  Future<void> saveAgentRunMetrics(ai.AgentRunMetrics metrics) =>
      _delegate.saveAgentRunMetrics(metrics);
  Future<void> replaceAgentRunMetrics(List<ai.AgentRunMetrics> metrics) =>
      _delegate.replaceAgentRunMetrics(metrics);
  Future<List<ai.AgentTraceEvent>> loadAgentTraceEvents(String runId) =>
      _delegate.loadAgentTraceEvents(runId);
  Future<List<String>> loadRecentAgentTraceRunIdsForChat(
    String chatId, {
    int limit = 20,
  }) => _delegate.loadRecentAgentTraceRunIdsForChat(chatId, limit: limit);
  Future<void> saveAgentTraceEvent(ai.AgentTraceEvent event) =>
      _delegate.saveAgentTraceEvent(event);
  Future<void> saveAgentTraceEvents(List<ai.AgentTraceEvent> events) =>
      _delegate.saveAgentTraceEvents(events);
  Future<void> deleteAgentTraceEvents(String runId) =>
      _delegate.deleteAgentTraceEvents(runId);

  Future<ai.AiConnectionSettings> loadAiConnectionSettings() =>
      _delegate.loadAiConnectionSettings();

  /// 兼容旧测试的增量设置方法，底层转发到 AI Port 的明确方法。
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
    bool clearApiKey = false,
    String? quarkSearchEndpoint,
    String? quarkApiKey,
    bool clearQuarkApiKey = false,
    bool? useCustomPrompts,
    String? customSystemPrompt,
    String? customPlannerPrompt,
    String? customOperatorPrompt,
    String? customExplorePrompt,
    String? customReviewerPrompt,
    String? customSummarizerPrompt,
    String? customCoordinatorPrompt,
    ai.LlmApiFormat? apiFormat,
  }) => _delegate.saveAiConnectionSettingsLegacy(
    baseUrl: baseUrl,
    model: model,
    helperModel: helperModel,
    auditModel: auditModel,
    modelFallbackPolicy: modelFallbackPolicy,
    contextWindowTokens: contextWindowTokens,
    timeoutSeconds: timeoutSeconds,
    deepSeekThinkingEnabled: deepSeekThinkingEnabled,
    deepSeekReasoningEffort: deepSeekReasoningEffort,
    openAiReasoningEffort: openAiReasoningEffort,
    webSearchEnabled: webSearchEnabled,
    webSearchMaxResults: webSearchMaxResults,
    webSearchEngine: webSearchEngine,
    multiAgentEnabled: multiAgentEnabled,
    multiAgentMaxAgents: multiAgentMaxAgents,
    postToolReviewEnabled: postToolReviewEnabled,
    toolCallBudget: toolCallBudget,
    agentLoopMode: agentLoopMode,
    maxImageSizeBytes: maxImageSizeBytes,
    maxFileSizeBytes: maxFileSizeBytes,
    apiKey: apiKey,
    selectedApiKeyId: selectedApiKeyId,
    clearApiKey: clearApiKey,
    quarkSearchEndpoint: quarkSearchEndpoint,
    quarkApiKey: quarkApiKey,
    clearQuarkApiKey: clearQuarkApiKey,
    useCustomPrompts: useCustomPrompts,
    customSystemPrompt: customSystemPrompt,
    customPlannerPrompt: customPlannerPrompt,
    customOperatorPrompt: customOperatorPrompt,
    customExplorePrompt: customExplorePrompt,
    customReviewerPrompt: customReviewerPrompt,
    customSummarizerPrompt: customSummarizerPrompt,
    customCoordinatorPrompt: customCoordinatorPrompt,
    apiFormat: apiFormat,
  );

  Future<void> saveAiConnectionSettingsLegacy({
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
    bool clearApiKey = false,
    String? quarkSearchEndpoint,
    String? quarkApiKey,
    bool clearQuarkApiKey = false,
    bool? useCustomPrompts,
    String? customSystemPrompt,
    String? customPlannerPrompt,
    String? customOperatorPrompt,
    String? customExplorePrompt,
    String? customReviewerPrompt,
    String? customSummarizerPrompt,
    String? customCoordinatorPrompt,
    ai.LlmApiFormat? apiFormat,
  }) => saveAiConnectionSettings(
    baseUrl: baseUrl,
    model: model,
    helperModel: helperModel,
    auditModel: auditModel,
    modelFallbackPolicy: modelFallbackPolicy,
    contextWindowTokens: contextWindowTokens,
    timeoutSeconds: timeoutSeconds,
    deepSeekThinkingEnabled: deepSeekThinkingEnabled,
    deepSeekReasoningEffort: deepSeekReasoningEffort,
    openAiReasoningEffort: openAiReasoningEffort,
    webSearchEnabled: webSearchEnabled,
    webSearchMaxResults: webSearchMaxResults,
    webSearchEngine: webSearchEngine,
    multiAgentEnabled: multiAgentEnabled,
    multiAgentMaxAgents: multiAgentMaxAgents,
    postToolReviewEnabled: postToolReviewEnabled,
    toolCallBudget: toolCallBudget,
    agentLoopMode: agentLoopMode,
    maxImageSizeBytes: maxImageSizeBytes,
    maxFileSizeBytes: maxFileSizeBytes,
    apiKey: apiKey,
    selectedApiKeyId: selectedApiKeyId,
    clearApiKey: clearApiKey,
    quarkSearchEndpoint: quarkSearchEndpoint,
    quarkApiKey: quarkApiKey,
    clearQuarkApiKey: clearQuarkApiKey,
    useCustomPrompts: useCustomPrompts,
    customSystemPrompt: customSystemPrompt,
    customPlannerPrompt: customPlannerPrompt,
    customOperatorPrompt: customOperatorPrompt,
    customExplorePrompt: customExplorePrompt,
    customReviewerPrompt: customReviewerPrompt,
    customSummarizerPrompt: customSummarizerPrompt,
    customCoordinatorPrompt: customCoordinatorPrompt,
    apiFormat: apiFormat,
  );

  Future<ai.AiRuntimeConnectionSnapshot> loadAiRuntimeConnectionSnapshot() =>
      _delegate.loadAiRuntimeConnectionSnapshot();

  Future<String?> getAiApiKey() async {
    final value = await _delegate.getAiApiKey();
    return value.isEmpty ? null : value;
  }

  Future<String?> getAiApiKeyById(String id) => _delegate.getAiApiKeyById(id);
  Future<List<ai.AiApiKeyHistoryEntry>> loadAiApiKeyHistory() =>
      _delegate.loadAiApiKeyHistory();
  Future<List<String>> loadAiBaseUrlHistory() =>
      _delegate.loadAiBaseUrlHistory();
  Future<List<String>> loadCachedAiModels({String? baseUrl}) =>
      _delegate.loadCachedAiModels(baseUrl: baseUrl);
  Future<void> saveCachedAiModels({
    required String baseUrl,
    required List<String> models,
  }) => _delegate.saveCachedAiModels(baseUrl: baseUrl, models: models);
  Future<void> removeAiBaseUrlHistoryEntry(String baseUrl) =>
      _delegate.removeAiBaseUrlHistoryEntry(baseUrl);
  Future<void> removeAiApiKeyHistoryEntry(String id) =>
      _delegate.removeAiApiKeyHistoryEntry(id);
  Future<String?> getQuarkApiKey() async {
    return _delegate.getQuarkApiKey();
  }

  Future<void> saveQuarkApiKey(String key) =>
      _delegate.saveAiConnectionSettingsLegacy(
        baseUrl: 'https://api.deepseek.com',
        model: 'deepseek-v4-flash',
        quarkApiKey: key,
      );
  Future<String?> getAliyunApiKey() async {
    final value = await _delegate.getAliyunApiKey();
    if (value == null || value.isEmpty) return null;
    return value;
  }

  Future<void> saveAliyunApiKey(String key) => _delegate.saveAliyunApiKey(key);
  Future<String?> getSelectedAiApiKeyId() => _delegate.getSelectedAiApiKeyId();
  Future<void> selectAiApiKey(String id) => _delegate.selectAiApiKey(id);
  Future<void> deleteAiApiKey(String id) => _delegate.deleteAiApiKey(id);
  Future<int> getAiRequestTimeoutSeconds() =>
      _delegate.getAiRequestTimeoutSeconds();
  Future<void> setSecretCacheEnabled(bool enabled) =>
      _delegate.setSecretCacheEnabled(enabled);
  Future<void> setSecretCacheTtl(Duration ttl) =>
      _delegate.setSecretCacheTtl(ttl);
  void clearSecretCache() => _delegate.clearSecretCache();

  Future<List<ai.AiSshSessionSnapshot>> loadRestorableTmuxSessions() =>
      _delegate.loadRestorableTmuxSessions();
}

/// 测试边界的 AI Port 视图；它把可空的测试密钥转换为 Port 约定的空串。
final class _TestAiStoragePort implements ai.AiStoragePort {
  const _TestAiStoragePort(this._owner);

  final TestStorageAdapter _owner;

  @override
  List<ConnectionConfig> get connections => _owner.connections;

  @override
  ConnectionConfig? getConnection(String id) => _owner.getConnection(id);

  @override
  Future<List<ai.AiChatRecord>> loadAiChats() => _owner.loadAiChats();
  @override
  Future<void> saveAiChat(ai.AiChatRecord chat) => _owner.saveAiChat(chat);
  @override
  Future<void> deleteAiChat(String id) => _owner.deleteAiChat(id);
  @override
  Future<List<ai.AiSkillRecord>> loadAiSkills() => _owner.loadAiSkills();
  @override
  Future<void> saveAiSkill(ai.AiSkillRecord skill) => _owner.saveAiSkill(skill);
  @override
  Future<bool> saveAiSkillIfUnchanged(
    ai.AiSkillRecord expected,
    ai.AiSkillRecord next,
  ) => _owner.saveAiSkillIfUnchanged(expected, next);
  @override
  Future<void> deleteAiSkill(String id) => _owner.deleteAiSkill(id);
  @override
  Future<List<ai.AgentRunMetrics>> loadAgentRunMetrics() =>
      _owner.loadAgentRunMetrics();
  @override
  Future<void> saveAgentRunMetrics(ai.AgentRunMetrics metrics) =>
      _owner.saveAgentRunMetrics(metrics);
  @override
  Future<List<ai.AgentTraceEvent>> loadAgentTraceEvents(String runId) =>
      _owner.loadAgentTraceEvents(runId);
  @override
  Future<List<String>> loadRecentAgentTraceRunIdsForChat(
    String chatId, {
    int limit = 20,
  }) => _owner.loadRecentAgentTraceRunIdsForChat(chatId, limit: limit);
  @override
  Future<void> saveAgentTraceEvent(ai.AgentTraceEvent event) =>
      _owner.saveAgentTraceEvent(event);
  @override
  Future<void> saveAgentTraceEvents(List<ai.AgentTraceEvent> events) =>
      _owner.saveAgentTraceEvents(events);
  @override
  Future<void> deleteAgentTraceEvents(String runId) =>
      _owner.deleteAgentTraceEvents(runId);
  @override
  Future<ai.AiConnectionSettings> loadAiConnectionSettings() =>
      _owner.loadAiConnectionSettings();
  @override
  Future<void> saveAiConnectionSettings(ai.AiConnectionSettings settings) =>
      _owner.aiStorage.saveAiConnectionSettings(settings);
  @override
  Future<void> saveAiConnectionSettingsLegacy({
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
    bool clearApiKey = false,
    String? quarkSearchEndpoint,
    String? quarkApiKey,
    bool clearQuarkApiKey = false,
    bool? useCustomPrompts,
    String? customSystemPrompt,
    String? customPlannerPrompt,
    String? customOperatorPrompt,
    String? customExplorePrompt,
    String? customReviewerPrompt,
    String? customSummarizerPrompt,
    String? customCoordinatorPrompt,
    ai.LlmApiFormat? apiFormat,
  }) => _owner.saveAiConnectionSettings(
    baseUrl: baseUrl,
    model: model,
    helperModel: helperModel,
    auditModel: auditModel,
    modelFallbackPolicy: modelFallbackPolicy,
    contextWindowTokens: contextWindowTokens,
    timeoutSeconds: timeoutSeconds,
    deepSeekThinkingEnabled: deepSeekThinkingEnabled,
    deepSeekReasoningEffort: deepSeekReasoningEffort,
    openAiReasoningEffort: openAiReasoningEffort,
    webSearchEnabled: webSearchEnabled,
    webSearchMaxResults: webSearchMaxResults,
    webSearchEngine: webSearchEngine,
    multiAgentEnabled: multiAgentEnabled,
    multiAgentMaxAgents: multiAgentMaxAgents,
    postToolReviewEnabled: postToolReviewEnabled,
    toolCallBudget: toolCallBudget,
    agentLoopMode: agentLoopMode,
    maxImageSizeBytes: maxImageSizeBytes,
    maxFileSizeBytes: maxFileSizeBytes,
    apiKey: apiKey,
    selectedApiKeyId: selectedApiKeyId,
    clearApiKey: clearApiKey,
    quarkSearchEndpoint: quarkSearchEndpoint,
    quarkApiKey: quarkApiKey,
    clearQuarkApiKey: clearQuarkApiKey,
    useCustomPrompts: useCustomPrompts,
    customSystemPrompt: customSystemPrompt,
    customPlannerPrompt: customPlannerPrompt,
    customOperatorPrompt: customOperatorPrompt,
    customExplorePrompt: customExplorePrompt,
    customReviewerPrompt: customReviewerPrompt,
    customSummarizerPrompt: customSummarizerPrompt,
    customCoordinatorPrompt: customCoordinatorPrompt,
    apiFormat: apiFormat,
  );
  @override
  Future<ai.AiRuntimeConnectionSnapshot> loadAiRuntimeConnectionSnapshot() =>
      _owner.loadAiRuntimeConnectionSnapshot();
  @override
  Future<String> getAiApiKey() async => await _owner.getAiApiKey() ?? '';
  @override
  Future<String?> getAiApiKeyById(String id) => _owner.getAiApiKeyById(id);
  @override
  Future<List<ai.AiApiKeyHistoryEntry>> loadAiApiKeyHistory() =>
      _owner.loadAiApiKeyHistory();
  @override
  Future<List<String>> loadAiBaseUrlHistory() => _owner.loadAiBaseUrlHistory();
  @override
  Future<List<String>> loadCachedAiModels({String? baseUrl}) =>
      _owner.loadCachedAiModels(baseUrl: baseUrl);
  @override
  Future<void> saveCachedAiModels({
    required String baseUrl,
    required List<String> models,
  }) => _owner.saveCachedAiModels(baseUrl: baseUrl, models: models);
  @override
  Future<void> removeAiBaseUrlHistoryEntry(String baseUrl) =>
      _owner.removeAiBaseUrlHistoryEntry(baseUrl);
  @override
  Future<void> removeAiApiKeyHistoryEntry(String id) =>
      _owner.removeAiApiKeyHistoryEntry(id);
  @override
  Future<String?> getAliyunApiKey() => _owner.getAliyunApiKey();
  @override
  Future<List<playbook.Playbook>> loadPlaybooks() => _owner.loadPlaybooks();
  @override
  Future<void> savePlaybook(playbook.Playbook item) =>
      _owner.savePlaybook(item);
  @override
  Future<String> exportAppDataJson() => _owner.exportAppDataJson();
  @override
  Future<void> importAppDataJson(String jsonText) =>
      _owner.importAppDataJson(jsonText);
  @override
  bool get isSecretCacheEnabled => _owner.isSecretCacheEnabled;
  @override
  int get secretCacheTtlMinutes => _owner.secretCacheTtlMinutes;
  @override
  Future<void> setSecretCacheEnabled(bool enabled) =>
      _owner.setSecretCacheEnabled(enabled);
  @override
  Future<void> setSecretCacheTtl(Duration ttl) => _owner.setSecretCacheTtl(ttl);
  @override
  void clearSecretCache() => _owner.clearSecretCache();
  @override
  Future<int> getAiRequestTimeoutSeconds() =>
      _owner.getAiRequestTimeoutSeconds();
  @override
  Future<List<ai.AiSshSessionSnapshot>> loadRestorableTmuxSessions() =>
      _owner.loadRestorableTmuxSessions();
  @override
  Map<String, ssh_core.SshTargetBinding> captureConnectionTargetBindings(
    Iterable<String> ids,
  ) => _owner.aiStorage.captureConnectionTargetBindings(ids);
  @override
  Future<ssh_core.SshRuntimeTarget?> resolveConnectionTarget(
    ssh_core.SshTargetBinding binding,
  ) => _owner.aiStorage.resolveConnectionTarget(binding);
}

/// 测试专用的可逆文本保护；只验证 Repository 的加密边界，不保存真实密钥。
final class _TestAiTextProtection implements ai.AiTextProtectionPort {
  const _TestAiTextProtection();

  @override
  Future<String> encrypt(String plainText) async =>
      'test:${base64Encode(utf8.encode(plainText))}';

  @override
  Future<String> decrypt(String storedText) async {
    if (!storedText.startsWith('test:')) return storedText;
    return utf8.decode(base64Decode(storedText.substring(5)));
  }
}
