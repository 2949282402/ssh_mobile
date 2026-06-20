part of '../storage_service.dart';

extension SettingsOps on StorageService {
  /// 从 SharedPreferences 读取密钥缓存开关和 TTL
  Future<void> _loadSecretCacheSettings() async {
    if (_prefs == null) return;
    _secretCacheEnabled =
        _prefs!.getBool(StorageService._secretCacheEnabledKey) ?? true;

    final ttlSeconds = _prefs!.getInt(StorageService._secretCacheTtlSecondsKey);
    if (ttlSeconds != null && ttlSeconds > 0) {
      _secretCacheTtl = _normalizeSecretCacheTtl(Duration(seconds: ttlSeconds));
    } else {
      _secretCacheTtl = StorageService._defaultSecretCacheTtl;
    }
  }

  /// 将用户输入的 TTL 规整到预设选项中最接近的大于等于值
  Duration _normalizeSecretCacheTtl(Duration value) {
    final requested = value.inMinutes.clamp(1, 120);
    final normalized = StorageService._memorySecretTtlOptionsMinutes.firstWhere(
      (option) => option >= requested,
      orElse: () => StorageService._memorySecretTtlOptionsMinutes.last,
    );
    return Duration(minutes: normalized);
  }

  Future<void> setSecretCacheEnabled(bool enabled) async {
    if (!_initialized || _prefs == null) return;
    if (_secretCacheEnabled == enabled) return;
    _secretCacheEnabled = enabled;
    if (!enabled) {
      clearSecretCache();
    }
    await _prefs!.setBool(StorageService._secretCacheEnabledKey, enabled);
    notifyStorageListeners();
  }

  Future<void> setSecretCacheTtl(Duration ttl) async {
    if (!_initialized || _prefs == null) return;
    final normalized = _normalizeSecretCacheTtl(ttl);
    if (_secretCacheTtl == normalized) return;
    _secretCacheTtl = normalized;
    await _prefs!
        .setInt(StorageService._secretCacheTtlSecondsKey, normalized.inSeconds);
    notifyStorageListeners();
  }

  /// 清除所有内存中缓存的秘密（密码/私钥/API Key）
  void clearSecretCache() {
    _secretCache.remove(StorageService._memoryAiApiKeyCacheKey);
    for (final key in _secretCache.keys.toList()) {
      if (key.startsWith(StorageService._passwordSecretKeyPrefix) ||
          key.startsWith(StorageService._privateKeySecretKeyPrefix)) {
        _secretCache.remove(key);
      }
    }
  }

  /// 加载 AI 连接设置（baseUrl、model、timeout 等），
  /// 各字段为空时返回合理的默认值。
  Future<AiConnectionSettings> loadAiConnectionSettings() async {
    final baseUrl = _prefs?.getString(StorageService._aiBaseUrlKey)?.trim();
    final model = _prefs?.getString(StorageService._aiModelKey)?.trim();
    final helperModel =
        _prefs?.getString(StorageService._aiHelperModelKey)?.trim() ?? '';
    final auditModel =
        _prefs?.getString(StorageService._aiAuditModelKey)?.trim() ?? '';
    final modelFallbackPolicy = AgentModelFallbackPolicy.normalize(
      _prefs?.getString(StorageService._aiModelFallbackPolicyKey),
    );
    final contextWindow = _prefs?.getInt(StorageService._aiContextWindowKey);
    final thinkingEnabled =
        _prefs?.getBool(StorageService._aiDeepSeekThinkingEnabledKey) ?? true;
    final reasoningEffort = DeepSeekReasoningEffort.normalize(
      _prefs?.getString(StorageService._aiDeepSeekReasoningEffortKey),
    );
    final openAiReasoningEffort = OpenAiReasoningEffort.normalize(
      _prefs?.getString(StorageService._aiOpenAiReasoningEffortKey),
    );
    final webSearchEngine = AiWebSearchEngine.normalize(
      _prefs?.getString(StorageService._aiWebSearchEngineKey),
    );
    final quarkSearchEndpoint =
        _prefs?.getString(StorageService._aiQuarkSearchEndpointKey)?.trim() ??
            'https://dashscope.aliyuncs.com/api/v1/services/search/quark';
    final quarkApiKey = await getQuarkApiKey();
    final hasQuarkApiKey = quarkApiKey?.isNotEmpty == true;
    final apiKey = await getAiApiKey();
    final activeApiKeyId = await getSelectedAiApiKeyId();
    final activeApiKeyMasked =
        apiKey?.isNotEmpty == true ? maskAiApiKey(apiKey!) : null;
    final useCustomPrompts =
        _prefs?.getBool(StorageService._aiUseCustomPromptsKey) ?? false;
    final customSystemPrompt =
        _prefs?.getString(StorageService._aiCustomSystemPromptKey) ?? '';
    final customPlannerPrompt =
        _prefs?.getString(StorageService._aiCustomPlannerPromptKey) ?? '';
    final customOperatorPrompt =
        _prefs?.getString(StorageService._aiCustomOperatorPromptKey) ?? '';
    final customExplorePrompt =
        _prefs?.getString(StorageService._aiCustomExplorePromptKey) ?? '';
    final customReviewerPrompt =
        _prefs?.getString(StorageService._aiCustomReviewerPromptKey) ?? '';
    final customSummarizerPrompt =
        _prefs?.getString(StorageService._aiCustomSummarizerPromptKey) ?? '';
    final customCoordinatorPrompt =
        _prefs?.getString(StorageService._aiCustomCoordinatorPromptKey) ?? '';
    return AiConnectionSettings(
      baseUrl:
          baseUrl?.isNotEmpty == true ? baseUrl! : 'https://api.deepseek.com',
      model: model?.isNotEmpty == true ? model! : 'deepseek-v4-flash',
      helperModel: helperModel,
      auditModel: auditModel,
      modelFallbackPolicy: modelFallbackPolicy,
      contextWindowTokens: AiContextWindowSize.normalize(contextWindow),
      timeoutSeconds: await getAiRequestTimeoutSeconds(),
      deepSeekThinkingEnabled: thinkingEnabled,
      deepSeekReasoningEffort: reasoningEffort,
      openAiReasoningEffort: openAiReasoningEffort,
      webSearchEnabled:
          _prefs?.getBool(StorageService._aiWebSearchEnabledKey) ?? true,
      webSearchMaxResults: AiWebSearchMaxResults.normalize(
        _prefs?.getInt(StorageService._aiWebSearchMaxResultsKey),
      ),
      webSearchEngine: webSearchEngine,
      quarkSearchEndpoint: quarkSearchEndpoint,
      hasQuarkApiKey: hasQuarkApiKey,
      multiAgentEnabled:
          _prefs?.getBool(StorageService._aiMultiAgentEnabledKey) ?? true,
      multiAgentMaxAgents: AiMultiAgentMaxAgents.normalize(
        _prefs?.getInt(StorageService._aiMultiAgentMaxAgentsKey),
      ),
      postToolReviewEnabled:
          _prefs?.getBool(StorageService._aiPostToolReviewEnabledKey) ?? true,
      toolCallBudget: AiToolCallBudget.normalize(
        _prefs?.getInt(StorageService._aiToolCallBudgetKey),
      ),
      maxImageSizeBytes: AiUploadSizeLimit.normalizeImage(
        _prefs?.getInt(StorageService._aiMaxImageSizeBytesKey),
      ),
      maxFileSizeBytes: AiUploadSizeLimit.normalizeFile(
        _prefs?.getInt(StorageService._aiMaxFileSizeBytesKey),
      ),
      hasApiKey: apiKey?.isNotEmpty == true,
      activeApiKeyId: activeApiKeyId,
      activeApiKeyMasked: activeApiKeyMasked,
      useCustomPrompts: useCustomPrompts,
      customSystemPrompt: customSystemPrompt,
      customPlannerPrompt: customPlannerPrompt,
      customOperatorPrompt: customOperatorPrompt,
      customExplorePrompt: customExplorePrompt,
      customReviewerPrompt: customReviewerPrompt,
      customSummarizerPrompt: customSummarizerPrompt,
      customCoordinatorPrompt: customCoordinatorPrompt,
    );
  }

  Future<List<String>> loadCachedAiModels({String? baseUrl}) async {
    if (!_initialized || _prefs == null) return const [];
    final normalizedBaseUrl = _normalizeAiModelsCacheBaseUrl(
      baseUrl?.trim().isNotEmpty == true
          ? baseUrl!
          : (_prefs!.getString(StorageService._aiBaseUrlKey) ??
              'https://api.deepseek.com'),
    );
    if (normalizedBaseUrl.isEmpty) return const [];
    final cache = _readAiModelsCacheMap();
    return List.unmodifiable(cache[normalizedBaseUrl] ?? const <String>[]);
  }

  Future<List<String>> loadAiBaseUrlHistory() async {
    if (!_initialized || _prefs == null) return const [];
    final currentBaseUrl = _prefs?.getString(StorageService._aiBaseUrlKey);
    return List.unmodifiable(
      _normalizeAiBaseUrlHistory(
        _readStringListPref(StorageService._aiBaseUrlHistoryKey),
        prependValue: currentBaseUrl,
      ),
    );
  }

  Future<void> removeAiBaseUrlHistoryEntry(String baseUrl) async {
    if (!_initialized || _prefs == null) return;
    final normalizedTarget = _normalizeAiModelsCacheBaseUrl(baseUrl);
    if (normalizedTarget.isEmpty) return;
    final nextHistory = _normalizeAiBaseUrlHistory(
      _readStringListPref(StorageService._aiBaseUrlHistoryKey),
    )..remove(normalizedTarget);
    await _writeStringListPref(
        StorageService._aiBaseUrlHistoryKey, nextHistory);
  }

  Future<List<AiApiKeyHistoryEntry>> loadAiApiKeyHistory() async {
    if (!_initialized || _prefs == null) return const [];
    await _ensureAiApiKeyHistoryMigrated();
    final selectedId = await getSelectedAiApiKeyId();
    final ids = _readAiApiKeyRefIds();
    final entries = <AiApiKeyHistoryEntry>[];
    final staleIds = <String>[];
    for (final id in ids) {
      final value = await _readSecure(_aiApiKeyStorageKey(id));
      final normalized = _normalizeAiApiKey(value);
      if (normalized == null) {
        staleIds.add(id);
        if (value != null && value.isNotEmpty) {
          await _deleteSecure(_aiApiKeyStorageKey(id));
        }
        continue;
      }
      entries.add(
        AiApiKeyHistoryEntry(
          id: id,
          maskedValue: maskAiApiKey(normalized),
          isSelected: id == selectedId,
        ),
      );
    }
    if (staleIds.isNotEmpty) {
      final nextIds = ids.where((id) => !staleIds.contains(id)).toList();
      await _writeAiApiKeyRefIds(nextIds);
      if (selectedId != null && staleIds.contains(selectedId)) {
        await _setSelectedAiApiKeyId(nextIds.isNotEmpty ? nextIds.first : null);
      }
    }
    return List.unmodifiable(entries);
  }

  /// Alias for loadAiApiKeyHistory to support getAiApiKeyHistory
  Future<List<AiApiKeyHistoryEntry>> getAiApiKeyHistory() =>
      loadAiApiKeyHistory();

  Future<String?> getAiApiKeyById(String id) async {
    if (!_initialized) return null;
    await _ensureAiApiKeyHistoryMigrated();
    final normalizedId = id.trim();
    if (normalizedId.isEmpty) return null;
    final value = await _readSecure(_aiApiKeyStorageKey(normalizedId));
    return _normalizeAiApiKey(value);
  }

  Future<void> removeAiApiKeyHistoryEntry(String id) async {
    if (!_initialized || _prefs == null) return;
    await _ensureAiApiKeyHistoryMigrated();
    final ids = _readAiApiKeyRefIds();
    if (!ids.contains(id)) return;
    final nextIds = ids.where((item) => item != id).toList();
    await _deleteSecure(_aiApiKeyStorageKey(id));
    await _writeAiApiKeyRefIds(nextIds);
    final selectedId =
        _prefs?.getString(StorageService._aiSelectedApiKeyIdKey)?.trim();
    if (selectedId == id) {
      await _setSelectedAiApiKeyId(nextIds.isNotEmpty ? nextIds.first : null);
    }
    _secretCache.remove(StorageService._memoryAiApiKeyCacheKey);
  }

  /// Alias for removeAiApiKeyHistoryEntry to support deleteAiApiKey
  Future<void> deleteAiApiKey(String id) => removeAiApiKeyHistoryEntry(id);

  Future<String?> getSelectedAiApiKeyId() async {
    if (!_initialized || _prefs == null) return null;
    await _ensureAiApiKeyHistoryMigrated();
    final ids = _readAiApiKeyRefIds();
    if (ids.isEmpty) {
      await _setSelectedAiApiKeyId(null);
      return null;
    }
    final selectedId =
        _prefs?.getString(StorageService._aiSelectedApiKeyIdKey)?.trim();
    if (selectedId != null && ids.contains(selectedId)) {
      return selectedId;
    }
    final fallbackId = ids.first;
    await _setSelectedAiApiKeyId(fallbackId);
    return fallbackId;
  }

  /// Alias for _setSelectedAiApiKeyId to support selectAiApiKey
  Future<void> selectAiApiKey(String id) => _setSelectedAiApiKeyId(id);

  Future<void> saveCachedAiModels({
    required String baseUrl,
    required Iterable<String> models,
  }) async {
    if (!_initialized || _prefs == null) return;
    final normalizedBaseUrl = _normalizeAiModelsCacheBaseUrl(baseUrl);
    if (normalizedBaseUrl.isEmpty) return;
    final normalizedModels = _normalizeAiModelList(models);
    final cache = _readAiModelsCacheMap();
    if (normalizedModels.isEmpty) {
      cache.remove(normalizedBaseUrl);
    } else {
      cache[normalizedBaseUrl] = normalizedModels;
    }
    await _prefs!
        .setString(StorageService._aiModelsCacheKey, jsonEncode(cache));
  }

  Future<void> clearCachedAiModels({String? baseUrl}) async {
    if (!_initialized || _prefs == null) return;
    if (baseUrl == null) {
      await _prefs!.remove(StorageService._aiModelsCacheKey);
      return;
    }
    final normalizedBaseUrl = _normalizeAiModelsCacheBaseUrl(baseUrl);
    if (normalizedBaseUrl.isEmpty) return;
    final cache = _readAiModelsCacheMap();
    cache.remove(normalizedBaseUrl);
    if (cache.isEmpty) {
      await _prefs!.remove(StorageService._aiModelsCacheKey);
      return;
    }
    await _prefs!
        .setString(StorageService._aiModelsCacheKey, jsonEncode(cache));
  }

  Future<int> getAiRequestTimeoutSeconds() async {
    return AiRequestTimeout.normalize(
        _prefs?.getInt(StorageService._aiTimeoutSecondsKey));
  }

  Future<String?> getAiApiKey() async {
    if (!_initialized) return null;
    await _ensureAiApiKeyHistoryMigrated();
    final cache =
        _readCachedSecretEntry(StorageService._memoryAiApiKeyCacheKey);
    if (cache != null) return cache.value;

    while (true) {
      final selectedId = await getSelectedAiApiKeyId();
      if (selectedId == null) {
        _secretCache.remove(StorageService._memoryAiApiKeyCacheKey);
        return null;
      }
      final value = await _readSecure(_aiApiKeyStorageKey(selectedId));
      final normalized = _normalizeAiApiKey(value);
      if (value != null && value.isNotEmpty && normalized == null) {
        await removeAiApiKeyHistoryEntry(selectedId);
        AppLogService.instance.warning(
          'Invalid LLM API key cleared',
          details:
              'Stored key contained characters that cannot be used safely.',
        );
        continue;
      }
      if (_secretCacheEnabled) {
        _secretCache[StorageService._memoryAiApiKeyCacheKey] = _MemorySecret(
          value: normalized,
          loadedAt: DateTime.now(),
        );
      }
      return normalized;
    }
  }

  Future<String?> getQuarkApiKey() async {
    if (!_initialized) return null;
    final value = await _readSecure(StorageService._quarkApiKeySecureKey);
    return value?.trim();
  }

  Future<void> saveQuarkApiKey(String key) async {
    if (!_initialized) return;
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      await _deleteSecure(StorageService._quarkApiKeySecureKey);
    } else {
      await _writeSecure(StorageService._quarkApiKeySecureKey, trimmed);
    }
  }

  Future<void> clearQuarkApiKey() async {
    if (!_initialized) return;
    await _deleteSecure(StorageService._quarkApiKeySecureKey);
  }

  Future<String?> getAliyunApiKey() async {
    if (!_initialized) return null;
    final value = await _readSecure(StorageService._aliyunApiKeySecureKey);
    return value?.trim();
  }

  Future<void> saveAliyunApiKey(String key) async {
    if (!_initialized) return;
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      await _deleteSecure(StorageService._aliyunApiKeySecureKey);
    } else {
      await _writeSecure(StorageService._aliyunApiKeySecureKey, trimmed);
    }
  }

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
  }) async {
    if (!_initialized || _prefs == null) return;
    final normalizedBaseUrl = baseUrl.trim();
    final normalizedModel = model.trim();
    final normalizedHelperModel = helperModel?.trim() ?? '';
    final normalizedAuditModel = auditModel?.trim() ?? '';
    await _prefs!.setString(StorageService._aiBaseUrlKey, normalizedBaseUrl);
    await _persistAiBaseUrlHistory(normalizedBaseUrl);
    await _prefs!.setString(StorageService._aiModelKey, normalizedModel);
    if (normalizedHelperModel.isEmpty) {
      await _prefs!.remove(StorageService._aiHelperModelKey);
    } else {
      await _prefs!.setString(
        StorageService._aiHelperModelKey,
        normalizedHelperModel,
      );
    }
    if (normalizedAuditModel.isEmpty) {
      await _prefs!.remove(StorageService._aiAuditModelKey);
    } else {
      await _prefs!.setString(
        StorageService._aiAuditModelKey,
        normalizedAuditModel,
      );
    }
    await _prefs!.setString(
      StorageService._aiModelFallbackPolicyKey,
      AgentModelFallbackPolicy.normalize(
        modelFallbackPolicy ??
            _prefs!.getString(StorageService._aiModelFallbackPolicyKey),
      ),
    );
    await _prefs!.setInt(
      StorageService._aiContextWindowKey,
      AiContextWindowSize.normalize(contextWindowTokens),
    );
    await _prefs!.setInt(
      StorageService._aiTimeoutSecondsKey,
      AiRequestTimeout.normalize(timeoutSeconds),
    );
    await _prefs!.setBool(
      StorageService._aiDeepSeekThinkingEnabledKey,
      deepSeekThinkingEnabled ??
          (_prefs!.getBool(StorageService._aiDeepSeekThinkingEnabledKey) ??
              true),
    );
    await _prefs!.setString(
      StorageService._aiDeepSeekReasoningEffortKey,
      DeepSeekReasoningEffort.normalize(
        deepSeekReasoningEffort ??
            _prefs!.getString(StorageService._aiDeepSeekReasoningEffortKey),
      ),
    );
    await _prefs!.setString(
      StorageService._aiOpenAiReasoningEffortKey,
      OpenAiReasoningEffort.normalize(
        openAiReasoningEffort ??
            _prefs!.getString(StorageService._aiOpenAiReasoningEffortKey),
      ),
    );
    await _prefs!.setBool(
      StorageService._aiWebSearchEnabledKey,
      webSearchEnabled ??
          (_prefs!.getBool(StorageService._aiWebSearchEnabledKey) ?? true),
    );
    await _prefs!.setInt(
      StorageService._aiWebSearchMaxResultsKey,
      AiWebSearchMaxResults.normalize(
        webSearchMaxResults ??
            _prefs!.getInt(StorageService._aiWebSearchMaxResultsKey),
      ),
    );
    await _prefs!.setString(
      StorageService._aiWebSearchEngineKey,
      AiWebSearchEngine.normalize(
        webSearchEngine ??
            _prefs!.getString(StorageService._aiWebSearchEngineKey),
      ),
    );
    if (quarkSearchEndpoint != null) {
      await _prefs!.setString(
          StorageService._aiQuarkSearchEndpointKey, quarkSearchEndpoint.trim());
    }
    if (useCustomPrompts != null) {
      await _prefs!
          .setBool(StorageService._aiUseCustomPromptsKey, useCustomPrompts);
    }
    if (customSystemPrompt != null) {
      await _prefs!.setString(
          StorageService._aiCustomSystemPromptKey, customSystemPrompt);
    }
    if (customPlannerPrompt != null) {
      await _prefs!.setString(
          StorageService._aiCustomPlannerPromptKey, customPlannerPrompt);
    }
    if (customOperatorPrompt != null) {
      await _prefs!.setString(
          StorageService._aiCustomOperatorPromptKey, customOperatorPrompt);
    }
    if (customExplorePrompt != null) {
      await _prefs!.setString(
          StorageService._aiCustomExplorePromptKey, customExplorePrompt);
    }
    if (customReviewerPrompt != null) {
      await _prefs!.setString(
          StorageService._aiCustomReviewerPromptKey, customReviewerPrompt);
    }
    if (customSummarizerPrompt != null) {
      await _prefs!.setString(
          StorageService._aiCustomSummarizerPromptKey, customSummarizerPrompt);
    }
    if (customCoordinatorPrompt != null) {
      await _prefs!.setString(StorageService._aiCustomCoordinatorPromptKey,
          customCoordinatorPrompt);
    }
    await _prefs!.setBool(
      StorageService._aiMultiAgentEnabledKey,
      multiAgentEnabled ??
          (_prefs!.getBool(StorageService._aiMultiAgentEnabledKey) ?? true),
    );
    await _prefs!.setBool(
      StorageService._aiPostToolReviewEnabledKey,
      postToolReviewEnabled ??
          (_prefs!.getBool(StorageService._aiPostToolReviewEnabledKey) ?? true),
    );
    await _prefs!.setInt(
      StorageService._aiMultiAgentMaxAgentsKey,
      AiMultiAgentMaxAgents.normalize(
        multiAgentMaxAgents ??
            _prefs!.getInt(StorageService._aiMultiAgentMaxAgentsKey),
      ),
    );
    await _prefs!.setInt(
      StorageService._aiToolCallBudgetKey,
      AiToolCallBudget.normalize(
        toolCallBudget ?? _prefs!.getInt(StorageService._aiToolCallBudgetKey),
      ),
    );
    await _prefs!.setInt(
      StorageService._aiMaxImageSizeBytesKey,
      AiUploadSizeLimit.normalizeImage(
        maxImageSizeBytes ??
            _prefs!.getInt(StorageService._aiMaxImageSizeBytesKey),
      ),
    );
    await _prefs!.setInt(
      StorageService._aiMaxFileSizeBytesKey,
      AiUploadSizeLimit.normalizeFile(
        maxFileSizeBytes ??
            _prefs!.getInt(StorageService._aiMaxFileSizeBytesKey),
      ),
    );
    await _ensureAiApiKeyHistoryMigrated();
    var apiKeyUpdated = false;
    final hasReplacementApiKey = apiKey?.trim().isNotEmpty == true;
    if (hasReplacementApiKey) {
      final replacementApiKey = apiKey!;
      final normalizedApiKey = _normalizeAiApiKey(apiKey);
      if (normalizedApiKey == null) {
        AppLogService.instance.warning(
          'LLM settings rejected invalid API key',
          details:
              'baseUrl=$normalizedBaseUrl model=$normalizedModel inputLength=${replacementApiKey.length}',
        );
        throw const FormatException('Invalid API key format.');
      }
      final selectedId = await _upsertAiApiKeyHistoryEntry(normalizedApiKey);
      await _setSelectedAiApiKeyId(selectedId);
      if (_secretCacheEnabled) {
        _secretCache[StorageService._memoryAiApiKeyCacheKey] = _MemorySecret(
          value: normalizedApiKey,
          loadedAt: DateTime.now(),
        );
      }
      apiKeyUpdated = true;
    } else if (selectedApiKeyId?.trim().isNotEmpty == true) {
      await _setSelectedAiApiKeyId(selectedApiKeyId!.trim());
      _secretCache.remove(StorageService._memoryAiApiKeyCacheKey);
    } else if (clearApiKey) {
      final currentId = await getSelectedAiApiKeyId();
      if (currentId != null) {
        await removeAiApiKeyHistoryEntry(currentId);
      } else {
        await _clearLegacyAiApiKeySecret();
      }
      apiKeyUpdated = true;
    }

    var quarkApiKeyUpdated = false;
    if (quarkApiKey != null) {
      final trimmed = quarkApiKey.trim();
      if (trimmed.isNotEmpty) {
        await _writeSecure(StorageService._quarkApiKeySecureKey, trimmed);
        quarkApiKeyUpdated = true;
      } else {
        await _deleteSecure(StorageService._quarkApiKeySecureKey);
        quarkApiKeyUpdated = true;
      }
    } else if (clearQuarkApiKey) {
      await _deleteSecure(StorageService._quarkApiKeySecureKey);
      quarkApiKeyUpdated = true;
    }
    AppLogService.instance.info(
      'LLM settings saved',
      details:
          'baseUrl=$normalizedBaseUrl model=$normalizedModel helperModel=$normalizedHelperModel auditModel=$normalizedAuditModel fallbackPolicy=${AgentModelFallbackPolicy.normalize(modelFallbackPolicy ?? _prefs!.getString(StorageService._aiModelFallbackPolicyKey))} contextWindow=${AiContextWindowSize.normalize(contextWindowTokens)} timeoutSeconds=${AiRequestTimeout.normalize(timeoutSeconds)} deepSeekThinking=${deepSeekThinkingEnabled ?? (_prefs!.getBool(StorageService._aiDeepSeekThinkingEnabledKey) ?? true)} deepSeekEffort=${DeepSeekReasoningEffort.normalize(deepSeekReasoningEffort ?? _prefs!.getString(StorageService._aiDeepSeekReasoningEffortKey))} openAiEffort=${OpenAiReasoningEffort.normalize(openAiReasoningEffort ?? _prefs!.getString(StorageService._aiOpenAiReasoningEffortKey))} webSearch=${webSearchEnabled ?? (_prefs!.getBool(StorageService._aiWebSearchEnabledKey) ?? true)} webSearchEngine=${AiWebSearchEngine.normalize(webSearchEngine ?? _prefs!.getString(StorageService._aiWebSearchEngineKey))} quarkSearchEndpoint=${_prefs!.getString(StorageService._aiQuarkSearchEndpointKey)} quarkApiKeyUpdated=$quarkApiKeyUpdated multiAgent=${multiAgentEnabled ?? (_prefs!.getBool(StorageService._aiMultiAgentEnabledKey) ?? true)} maxAgents=${AiMultiAgentMaxAgents.normalize(multiAgentMaxAgents ?? _prefs!.getInt(StorageService._aiMultiAgentMaxAgentsKey))} toolCallBudget=${AiToolCallBudget.normalize(toolCallBudget ?? _prefs!.getInt(StorageService._aiToolCallBudgetKey))} apiKeyUpdated=$apiKeyUpdated useCustomPrompts=$useCustomPrompts',
    );
  }

  String? _normalizeAiApiKey(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.contains(RegExp(r'[\r\n\t]'))) return null;
    if (trimmed.contains('package:flutter/') ||
        trimmed.contains('Failed assertion') ||
        trimmed.contains('docs.flutter.dev/testing/errors')) {
      return null;
    }
    if (trimmed.length > 4096) return null;
    return trimmed;
  }

  Future<void> _clearAiApiKeySecret() async {
    _secretCache.remove(StorageService._memoryAiApiKeyCacheKey);
    await _clearLegacyAiApiKeySecret();
    final ids = _readAiApiKeyRefIds();
    for (final id in ids) {
      await _deleteSecure(_aiApiKeyStorageKey(id));
    }
    await _writeAiApiKeyRefIds(const []);
    await _setSelectedAiApiKeyId(null);
  }

  Future<void> _clearLegacyAiApiKeySecret() async {
    _secretCache.remove(StorageService._memoryAiApiKeyCacheKey);
    await _deleteSecure(StorageService._aiApiKeyKey);
  }

  Future<void> _ensureAiApiKeyHistoryMigrated() async {
    if (!_initialized || _prefs == null) return;
    if (_readAiApiKeyRefIds().isNotEmpty) return;
    final legacyValue = await _readSecure(StorageService._aiApiKeyKey);
    final normalizedLegacy = _normalizeAiApiKey(legacyValue);
    if (normalizedLegacy == null) {
      if (legacyValue != null && legacyValue.isNotEmpty) {
        await _deleteSecure(StorageService._aiApiKeyKey);
      }
      return;
    }
    final id = _traceUuid.v4();
    await _writeSecure(_aiApiKeyStorageKey(id), normalizedLegacy);
    await _writeAiApiKeyRefIds([id]);
    await _setSelectedAiApiKeyId(id);
    await _deleteSecure(StorageService._aiApiKeyKey);
  }

  Future<String> _upsertAiApiKeyHistoryEntry(String apiKey) async {
    final normalizedApiKey = _normalizeAiApiKey(apiKey);
    if (normalizedApiKey == null) {
      throw const FormatException('Invalid API key format.');
    }
    final ids = _readAiApiKeyRefIds();
    String? matchedId;
    for (final id in ids) {
      final value = await _readSecure(_aiApiKeyStorageKey(id));
      if (_normalizeAiApiKey(value) == normalizedApiKey) {
        matchedId = id;
        break;
      }
    }
    final targetId = matchedId ?? _traceUuid.v4();
    await _writeSecure(_aiApiKeyStorageKey(targetId), normalizedApiKey);
    final nextIds = <String>[
      targetId,
      ...ids.where((id) => id != targetId),
    ];
    await _writeAiApiKeyRefIds(nextIds);
    return targetId;
  }

  Future<void> _setSelectedAiApiKeyId(String? id) async {
    if (_prefs == null) return;
    final normalized = id?.trim();
    if (normalized == null || normalized.isEmpty) {
      await _prefs!.remove(StorageService._aiSelectedApiKeyIdKey);
      return;
    }
    await _prefs!.setString(StorageService._aiSelectedApiKeyIdKey, normalized);
  }

  List<String> _readAiApiKeyRefIds() {
    return _readStringListPref(StorageService._aiApiKeyRefsKey);
  }

  Future<void> _writeAiApiKeyRefIds(List<String> ids) async {
    await _writeStringListPref(StorageService._aiApiKeyRefsKey, ids);
  }

  String _aiApiKeyStorageKey(String id) =>
      '${StorageService._aiApiKeyEntryPrefix}$id';

  Future<void> _persistAiBaseUrlHistory(String currentBaseUrl) async {
    await _writeStringListPref(
      StorageService._aiBaseUrlHistoryKey,
      _normalizeAiBaseUrlHistory(
        _readStringListPref(StorageService._aiBaseUrlHistoryKey),
        prependValue: currentBaseUrl,
      ),
    );
  }

  List<String> _readStringListPref(String key) {
    final raw = _prefs?.getString(key);
    if (raw == null || raw.trim().isEmpty) return <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>[];
      return decoded.whereType<String>().toList();
    } catch (_) {
      return <String>[];
    }
  }

  Future<void> _writeStringListPref(String key, List<String> values) async {
    if (_prefs == null) return;
    if (values.isEmpty) {
      await _prefs!.remove(key);
      return;
    }
    await _prefs!.setString(key, jsonEncode(values));
  }

  List<String> _normalizeAiBaseUrlHistory(
    Iterable<String> history, {
    String? prependValue,
  }) {
    final seen = <String>{};
    final normalized = <String>[];
    void addValue(String value) {
      final item = _normalizeAiModelsCacheBaseUrl(value);
      if (item.isEmpty || !seen.add(item)) return;
      normalized.add(item);
    }

    if (prependValue != null) {
      addValue(prependValue);
    }
    for (final item in history) {
      addValue(item);
    }
    return normalized;
  }

  Map<String, List<String>> _readAiModelsCacheMap() {
    final raw = _prefs?.getString(StorageService._aiModelsCacheKey);
    if (raw == null || raw.trim().isEmpty) {
      return <String, List<String>>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return <String, List<String>>{};
      }
      final cache = <String, List<String>>{};
      for (final entry in decoded.entries) {
        final normalizedBaseUrl = _normalizeAiModelsCacheBaseUrl(entry.key);
        if (normalizedBaseUrl.isEmpty || entry.value is! List) continue;
        final normalizedModels = _normalizeAiModelList(
          (entry.value as List).whereType<String>(),
        );
        if (normalizedModels.isNotEmpty) {
          cache[normalizedBaseUrl] = normalizedModels;
        }
      }
      return cache;
    } catch (_) {
      return <String, List<String>>{};
    }
  }

  List<String> _normalizeAiModelList(Iterable<String> models) {
    return models
        .map((model) => model.trim())
        .where((model) => model.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
  }

  String _normalizeAiModelsCacheBaseUrl(String value) {
    var normalized = value.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  _MemorySecret? _readCachedSecretEntry(String cacheKey) {
    if (!_secretCacheEnabled) return null;
    final cached = _secretCache[cacheKey];
    if (cached == null) return null;
    if (DateTime.now().difference(cached.loadedAt) > _secretCacheTtl) {
      _secretCache.remove(cacheKey);
      return null;
    }
    return cached;
  }

  void _cancelPendingProtectedPrefWrite(String key) {
    final pending = _pendingProtectedPrefWrites.remove(key);
    pending?.timer?.cancel();
  }
}
