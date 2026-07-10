part of '../llm_chat_screen.dart';

// --- Shared Group / Card Container for LLM Settings sections ---
class _LlmSettingsGroup extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _LlmSettingsGroup({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.28),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.72),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                color: colorScheme.primary,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

// --- Section 1: API & Base connection settings ---
class _LlmApiConfigSection extends StatelessWidget {
  final AiStrings strings;
  final bool saving;
  final LlmApiFormat apiFormat;
  final ValueChanged<LlmApiFormat?> onApiFormatChanged;
  final TextEditingController baseUrlController;
  final List<String> baseUrlHistory;
  final VoidCallback onOpenBaseUrlHistory;
  final String recommendedBaseUrl;
  final VoidCallback onUseRecommendedBaseUrl;

  final TextEditingController apiKeyController;
  final String? selectedApiKeyMasked;
  final List<AiApiKeyHistoryEntry> apiKeyHistory;
  final String? selectedApiKeyId;
  final VoidCallback onOpenApiKeyHistory;
  final ValueChanged<String> onSelectApiKeyHistoryEntry;

  final List<String> models;
  final TextEditingController modelController;
  final bool loadingModels;
  final VoidCallback onRefreshModels;

  final TextEditingController helperModelController;
  final TextEditingController auditModelController;

  final String modelFallbackPolicy;
  final ValueChanged<String?> onModelFallbackPolicyChanged;
  final int contextWindowTokens;
  final ValueChanged<int?> onContextWindowTokensChanged;
  final int timeoutSeconds;
  final ValueChanged<int?> onTimeoutSecondsChanged;

  const _LlmApiConfigSection({
    required this.strings,
    required this.saving,
    required this.apiFormat,
    required this.onApiFormatChanged,
    required this.baseUrlController,
    required this.baseUrlHistory,
    required this.onOpenBaseUrlHistory,
    required this.recommendedBaseUrl,
    required this.onUseRecommendedBaseUrl,
    required this.apiKeyController,
    required this.selectedApiKeyMasked,
    required this.apiKeyHistory,
    required this.selectedApiKeyId,
    required this.onOpenApiKeyHistory,
    required this.onSelectApiKeyHistoryEntry,
    required this.models,
    required this.modelController,
    required this.loadingModels,
    required this.onRefreshModels,
    required this.helperModelController,
    required this.auditModelController,
    required this.modelFallbackPolicy,
    required this.onModelFallbackPolicyChanged,
    required this.contextWindowTokens,
    required this.onContextWindowTokensChanged,
    required this.timeoutSeconds,
    required this.onTimeoutSecondsChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _LlmSettingsGroup(
      title: strings.apiFormat,
      children: [
        DropdownButtonFormField<LlmApiFormat>(
          initialValue: apiFormat,
          decoration: InputDecoration(labelText: strings.apiFormat),
          items:
              const [
                LlmApiFormat.openAiChatCompletions,
                LlmApiFormat.geminiOpenAiCompatible,
                LlmApiFormat.anthropicMessages,
              ].map((format) {
                return DropdownMenuItem<LlmApiFormat>(
                  value: format,
                  child: Text(strings.apiFormatLabel(format)),
                );
              }).toList(),
          onChanged: saving ? null : onApiFormatChanged,
        ),
        const SizedBox(height: 14),
        TextField(
          controller: baseUrlController,
          enabled: !saving,
          decoration: InputDecoration(
            labelText: strings.baseUrl,
            helperText: baseUrlHistory.isEmpty
                ? null
                : strings.savedCount(baseUrlHistory.length),
            suffixIcon: IconButton(
              tooltip: strings.baseUrlHistory,
              onPressed: saving ? null : onOpenBaseUrlHistory,
              icon: const Icon(Icons.arrow_drop_down_rounded),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  '${strings.recommendedBaseUrl}: $recommendedBaseUrl',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.grey),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: saving ? null : onUseRecommendedBaseUrl,
                child: Text(strings.useRecommendedBaseUrl),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: apiKeyController,
          enabled: !saving,
          obscureText: true,
          decoration: InputDecoration(
            labelText: selectedApiKeyMasked != null
                ? strings.apiKeySaved
                : strings.apiKeyRequired,
            helperText: selectedApiKeyMasked != null
                ? strings.apiKeySelected(selectedApiKeyMasked!)
                : (apiKeyHistory.isNotEmpty
                      ? strings.apiKeyHistoryHint
                      : strings.apiKeyReplaceHint),
            helperMaxLines: 2,
            suffixIcon: IconButton(
              tooltip: strings.apiKeyHistory,
              onPressed: saving ? null : onOpenApiKeyHistory,
              icon: const Icon(Icons.arrow_drop_down_rounded),
            ),
          ),
        ),
        if (apiKeyHistory.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in apiKeyHistory)
                ChoiceChip(
                  label: Text(entry.maskedValue),
                  selected: entry.id == selectedApiKeyId,
                  onSelected: saving
                      ? null
                      : (_) => onSelectApiKeyHistoryEntry(entry.id),
                ),
            ],
          ),
          if (selectedApiKeyMasked != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                strings.apiKeyMaskedPreview(selectedApiKeyMasked!),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ],
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: models.contains(modelController.text)
                    ? modelController.text
                    : models.first,
                isExpanded: true,
                decoration: InputDecoration(labelText: strings.model),
                selectedItemBuilder: (context) => [
                  for (final model in models)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        model,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                      ),
                    ),
                ],
                items: [
                  for (final model in models)
                    DropdownMenuItem(
                      value: model,
                      child: Text(
                        model,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                      ),
                    ),
                ],
                onChanged: saving
                    ? null
                    : (value) {
                        if (value != null) {
                          modelController.text = value;
                        }
                      },
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: strings.refreshModels,
              onPressed: loadingModels || saving ? null : onRefreshModels,
              icon: loadingModels
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync_rounded),
            ),
          ],
        ),
        const SizedBox(height: 14),
        TextField(
          controller: helperModelController,
          enabled: !saving,
          decoration: InputDecoration(
            labelText: strings.helperModel,
            helperText: strings.helperModelHint,
            helperMaxLines: 2,
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: auditModelController,
          enabled: !saving,
          decoration: InputDecoration(
            labelText: strings.auditModel,
            helperText: strings.auditModelHint,
            helperMaxLines: 2,
          ),
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          initialValue: AgentModelFallbackPolicy.normalize(modelFallbackPolicy),
          isExpanded: true,
          decoration: InputDecoration(labelText: strings.modelFallbackPolicy),
          items: [
            for (final value in AgentModelFallbackPolicy.values)
              DropdownMenuItem(
                value: value,
                child: Text(strings.modelFallbackPolicyLabel(value)),
              ),
          ],
          onChanged: saving ? null : onModelFallbackPolicyChanged,
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<int>(
          initialValue: contextWindowTokens,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Context window'),
          items: [
            for (final value in AiContextWindowSize.values)
              DropdownMenuItem(
                value: value,
                child: Text(AiContextWindowSize.label(value)),
              ),
          ],
          onChanged: saving ? null : onContextWindowTokensChanged,
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<int>(
          initialValue: timeoutSeconds,
          isExpanded: true,
          decoration: InputDecoration(labelText: strings.requestTimeout),
          items: [
            for (final value in AiRequestTimeout.values)
              DropdownMenuItem(
                value: value,
                child: Text(AiRequestTimeout.label(value)),
              ),
          ],
          onChanged: saving ? null : onTimeoutSecondsChanged,
        ),
      ],
    );
  }
}

// --- Section 2: Agent Orchestration & Loop limits ---
class _LlmAgentConfigSection extends StatelessWidget {
  final AiStrings strings;
  final bool saving;
  final bool multiAgentEnabled;
  final ValueChanged<bool> onMultiAgentEnabledChanged;
  final int multiAgentMaxAgents;
  final ValueChanged<int?> onMultiAgentMaxAgentsChanged;
  final bool postToolReviewEnabled;
  final ValueChanged<bool> onPostToolReviewEnabledChanged;
  final int toolCallBudget;
  final ValueChanged<int?> onToolCallBudgetChanged;
  final String agentLoopMode;
  final ValueChanged<String?> onAgentLoopModeChanged;

  const _LlmAgentConfigSection({
    required this.strings,
    required this.saving,
    required this.multiAgentEnabled,
    required this.onMultiAgentEnabledChanged,
    required this.multiAgentMaxAgents,
    required this.onMultiAgentMaxAgentsChanged,
    required this.postToolReviewEnabled,
    required this.onPostToolReviewEnabledChanged,
    required this.toolCallBudget,
    required this.onToolCallBudgetChanged,
    required this.agentLoopMode,
    required this.onAgentLoopModeChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _LlmSettingsGroup(
      title: strings.multiAgent,
      children: [
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(strings.multiAgent),
          subtitle: Text(strings.multiAgentHint),
          value: multiAgentEnabled,
          onChanged: saving ? null : onMultiAgentEnabledChanged,
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<int>(
          initialValue: AiMultiAgentMaxAgents.normalize(multiAgentMaxAgents),
          isExpanded: true,
          decoration: InputDecoration(labelText: strings.multiAgentMaxAgents),
          items: [
            for (final value in AiMultiAgentMaxAgents.values)
              DropdownMenuItem(value: value, child: Text('$value')),
          ],
          onChanged: saving || !multiAgentEnabled
              ? null
              : onMultiAgentMaxAgentsChanged,
        ),
        const SizedBox(height: 14),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(
            strings.language == AppLanguage.en
                ? 'Post-tool review agent'
                : '异常恢复审查 Agent',
          ),
          subtitle: Text(
            strings.language == AppLanguage.en
                ? 'Runs a review agent after tool errors, approval rejection, unavailable approval, budget audit rejection, or loop guard blocking.'
                : '工具失败、审批拒绝、审批不可用、预算审计拒绝或循环阻断时，自动调用审查 Agent 分析原因并给出下一步建议。',
          ),
          value: postToolReviewEnabled,
          onChanged: saving ? null : onPostToolReviewEnabledChanged,
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<int>(
          initialValue: AiToolCallBudget.normalize(toolCallBudget),
          isExpanded: true,
          decoration: InputDecoration(
            labelText: strings.toolCallBudget,
            helperText: strings.toolCallBudgetHint,
            helperMaxLines: 3,
          ),
          items: [
            for (final value in AiToolCallBudget.values)
              DropdownMenuItem(
                value: value,
                child: Text(AiToolCallBudget.label(value)),
              ),
          ],
          onChanged: saving ? null : onToolCallBudgetChanged,
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          initialValue: AiAgentLoopMode.normalize(agentLoopMode),
          isExpanded: true,
          decoration: InputDecoration(
            labelText: strings.language == AppLanguage.en
                ? 'Agent loop rounds'
                : 'Agent 循环轮次',
            helperText: strings.language == AppLanguage.en
                ? 'Controls primary model rounds separately from tool call budget. Balanced 16 (+8), Deep 24 (+12), Unlimited has no round cap. Tool call budget is unchanged.'
                : '单独控制主模型循环轮次，不影响工具调用预算。均衡 16（批准 +8），深度 24（批准 +12），无限制不设轮次上限。工具预算保持不变。',
            helperMaxLines: 4,
          ),
          items: [
            for (final value in AiAgentLoopMode.values)
              DropdownMenuItem(
                value: value,
                child: Text(switch (value) {
                  AiAgentLoopMode.deep =>
                    strings.language == AppLanguage.en ? 'Deep' : '深度',
                  AiAgentLoopMode.unlimited =>
                    strings.language == AppLanguage.en ? 'Unlimited' : '无限制',
                  _ => strings.language == AppLanguage.en ? 'Balanced' : '均衡',
                }),
              ),
          ],
          onChanged: saving ? null : onAgentLoopModeChanged,
        ),
      ],
    );
  }
}

// --- Section 3: DeepSeek / OpenAI reasoning settings ---
class _LlmReasoningConfigSection extends StatelessWidget {
  final AiStrings strings;
  final bool saving;
  final bool showsDeepSeekControls;
  final bool deepSeekThinkingEnabled;
  final ValueChanged<bool> onDeepSeekThinkingChanged;
  final String deepSeekReasoningEffort;
  final ValueChanged<String?> onDeepSeekReasoningEffortChanged;

  final bool showsOpenAiReasoningControls;
  final String openAiReasoningEffort;
  final ValueChanged<String?> onOpenAiReasoningEffortChanged;

  const _LlmReasoningConfigSection({
    required this.strings,
    required this.saving,
    required this.showsDeepSeekControls,
    required this.deepSeekThinkingEnabled,
    required this.onDeepSeekThinkingChanged,
    required this.deepSeekReasoningEffort,
    required this.onDeepSeekReasoningEffortChanged,
    required this.showsOpenAiReasoningControls,
    required this.openAiReasoningEffort,
    required this.onOpenAiReasoningEffortChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (!showsDeepSeekControls && !showsOpenAiReasoningControls) {
      return const SizedBox.shrink();
    }

    return _LlmSettingsGroup(
      title: strings.language == AppLanguage.en
          ? 'Reasoning & Thinking'
          : '推理与思考设置',
      children: [
        if (showsDeepSeekControls) ...[
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(strings.deepSeekThinking),
            subtitle: Text(strings.deepSeekThinkingHint),
            value: deepSeekThinkingEnabled,
            onChanged: saving ? null : onDeepSeekThinkingChanged,
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            initialValue: DeepSeekReasoningEffort.normalize(
              deepSeekReasoningEffort,
            ),
            isExpanded: true,
            decoration: InputDecoration(
              labelText: strings.deepSeekReasoningEffort,
            ),
            items: [
              for (final value in DeepSeekReasoningEffort.values)
                DropdownMenuItem(
                  value: value,
                  child: Text(DeepSeekReasoningEffort.label(value)),
                ),
            ],
            onChanged: saving || !deepSeekThinkingEnabled
                ? null
                : onDeepSeekReasoningEffortChanged,
          ),
        ],
        if (showsOpenAiReasoningControls) ...[
          DropdownButtonFormField<String>(
            initialValue: OpenAiReasoningEffort.normalize(
              openAiReasoningEffort,
            ),
            isExpanded: true,
            decoration: InputDecoration(
              labelText: strings.openAiReasoningEffort,
              helperText: strings.openAiReasoningHint,
            ),
            items: [
              for (final value in OpenAiReasoningEffort.values)
                DropdownMenuItem(
                  value: value,
                  child: Text(OpenAiReasoningEffort.label(value)),
                ),
            ],
            onChanged: saving ? null : onOpenAiReasoningEffortChanged,
          ),
        ],
      ],
    );
  }
}

// --- Section 4: Web search engine & keys ---
class _LlmSearchConfigSection extends StatelessWidget {
  final AiStrings strings;
  final bool saving;
  final bool webSearchEnabled;
  final ValueChanged<bool> onWebSearchEnabledChanged;
  final String webSearchEngine;
  final ValueChanged<String?> onWebSearchEngineChanged;
  final bool hasQuarkApiKey;
  final TextEditingController quarkApiKeyController;
  final TextEditingController quarkEndpointController;
  final int webSearchMaxResults;
  final ValueChanged<int?> onWebSearchMaxResultsChanged;

  const _LlmSearchConfigSection({
    required this.strings,
    required this.saving,
    required this.webSearchEnabled,
    required this.onWebSearchEnabledChanged,
    required this.webSearchEngine,
    required this.onWebSearchEngineChanged,
    required this.hasQuarkApiKey,
    required this.quarkApiKeyController,
    required this.quarkEndpointController,
    required this.webSearchMaxResults,
    required this.onWebSearchMaxResultsChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _LlmSettingsGroup(
      title: strings.webSearch,
      children: [
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(strings.webSearch),
          subtitle: Text(strings.webSearchHint),
          value: webSearchEnabled,
          onChanged: saving ? null : onWebSearchEnabledChanged,
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          initialValue: webSearchEngine,
          isExpanded: true,
          decoration: InputDecoration(labelText: strings.webSearchEngine),
          items: [
            for (final value in AiWebSearchEngine.values)
              DropdownMenuItem(
                value: value,
                child: Text(strings.webSearchEngineLabel(value)),
              ),
          ],
          onChanged: saving || !webSearchEnabled
              ? null
              : onWebSearchEngineChanged,
        ),
        if (webSearchEnabled && webSearchEngine == AiWebSearchEngine.quark) ...[
          const SizedBox(height: 14),
          TextField(
            controller: quarkApiKeyController,
            enabled: !saving,
            obscureText: true,
            decoration: InputDecoration(
              labelText: hasQuarkApiKey
                  ? strings.quarkApiKeySaved
                  : strings.quarkApiKeyRequired,
              helperText: strings.quarkApiKeyReplaceHint,
              helperMaxLines: 2,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: quarkEndpointController,
            enabled: !saving,
            decoration: InputDecoration(
              labelText: strings.quarkSearchEndpoint,
              helperText: strings.quarkSearchEndpointHint,
              helperMaxLines: 2,
            ),
          ),
        ],
        const SizedBox(height: 14),
        DropdownButtonFormField<int>(
          initialValue: AiWebSearchMaxResults.normalize(webSearchMaxResults),
          isExpanded: true,
          decoration: InputDecoration(labelText: strings.webSearchMaxResults),
          items: [
            for (final value in AiWebSearchMaxResults.values)
              DropdownMenuItem(value: value, child: Text('$value')),
          ],
          onChanged: saving || !webSearchEnabled
              ? null
              : onWebSearchMaxResultsChanged,
        ),
      ],
    );
  }
}

// --- Section 5: RAG settings ---
class _LlmRagConfigSection extends StatelessWidget {
  final AiStrings strings;
  final bool saving;
  final bool ragEnabled;
  final ValueChanged<bool> onRagEnabledChanged;
  final String ragSearchMode;
  final ValueChanged<String?> onRagSearchModeChanged;
  final VoidCallback onManageRag;

  const _LlmRagConfigSection({
    required this.strings,
    required this.saving,
    required this.ragEnabled,
    required this.onRagEnabledChanged,
    required this.ragSearchMode,
    required this.onRagSearchModeChanged,
    required this.onManageRag,
  });

  @override
  Widget build(BuildContext context) {
    return _LlmSettingsGroup(
      title: strings.ragTitle,
      children: [
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(strings.ragTitle),
          subtitle: Text(strings.ragHint),
          value: ragEnabled,
          onChanged: saving ? null : onRagEnabledChanged,
        ),
        if (ragEnabled) ...[
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: ragSearchMode,
            isExpanded: true,
            decoration: InputDecoration(labelText: strings.ragSearchMode),
            items: [
              DropdownMenuItem(
                value: 'bm25',
                child: Text(strings.ragSearchModeBm25),
              ),
              DropdownMenuItem(
                value: 'vector',
                child: Text(strings.ragSearchModeVector),
              ),
              DropdownMenuItem(
                value: 'hybrid',
                child: Text(strings.ragSearchModeHybrid),
              ),
            ],
            onChanged: saving ? null : onRagSearchModeChanged,
          ),
          if (ragSearchMode == 'vector' || ragSearchMode == 'hybrid') ...[
            const SizedBox(height: 8),
            Text(
              strings.ragSearchModeNeedKey,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ],
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.auto_stories),
            label: Text(strings.ragManage),
            onPressed: saving ? null : onManageRag,
          ),
        ),
      ],
    );
  }
}

// --- Section 6: Upload limit settings ---
class _LlmUploadLimitsSection extends StatelessWidget {
  final AiStrings strings;
  final bool saving;
  final int maxImageSizeBytes;
  final ValueChanged<int?> onMaxImageSizeBytesChanged;
  final int maxFileSizeBytes;
  final ValueChanged<int?> onMaxFileSizeBytesChanged;

  const _LlmUploadLimitsSection({
    required this.strings,
    required this.saving,
    required this.maxImageSizeBytes,
    required this.onMaxImageSizeBytesChanged,
    required this.maxFileSizeBytes,
    required this.onMaxFileSizeBytesChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _LlmSettingsGroup(
      title: strings.language == AppLanguage.en ? 'Upload Limits' : '上传文件限制',
      children: [
        DropdownButtonFormField<int>(
          initialValue: AiUploadSizeLimit.normalizeImage(maxImageSizeBytes),
          isExpanded: true,
          decoration: InputDecoration(labelText: strings.maxImageSize),
          items: [
            for (final value in AiUploadSizeLimit.imageValues)
              DropdownMenuItem(
                value: value,
                child: Text(AiUploadSizeLimit.label(value)),
              ),
          ],
          onChanged: saving ? null : onMaxImageSizeBytesChanged,
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<int>(
          initialValue: AiUploadSizeLimit.normalizeFile(maxFileSizeBytes),
          isExpanded: true,
          decoration: InputDecoration(labelText: strings.maxFileSize),
          items: [
            for (final value in AiUploadSizeLimit.fileValues)
              DropdownMenuItem(
                value: value,
                child: Text(AiUploadSizeLimit.label(value)),
              ),
          ],
          onChanged: saving ? null : onMaxFileSizeBytesChanged,
        ),
      ],
    );
  }
}
