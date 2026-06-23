part of '../llm_chat_screen.dart';

class _AiStrings {
  final AppLanguage language;

  const _AiStrings(this.language);

  bool get _en => language == AppLanguage.en;

  String get apiFormat => _en ? 'API Format' : 'API ????';
  String get apiFormatUnsupported => _en
      ? 'The selected API format is currently unsupported. Switched back to OpenAI Chat Completions.'
      : '?? API ?????????? OpenAI Chat Completions?';
  String get recommendedBaseUrl => _en ? 'Recommended' : '????';
  String get useRecommendedBaseUrl => _en ? 'Use Recommended' : '??????';
  String apiFormatLabel(LlmApiFormat format) {
    switch (format) {
      case LlmApiFormat.openAiChatCompletions:
        return 'OpenAI Chat Completions';
      case LlmApiFormat.openAiResponses:
        return 'OpenAI Responses';
      case LlmApiFormat.anthropicMessages:
        return 'Anthropic Messages';
      case LlmApiFormat.geminiNative:
        return 'Gemini Native';
      case LlmApiFormat.geminiOpenAiCompatible:
        return 'Gemini OpenAI-compatible';
    }
  }

  String get title => _en ? 'LLM Assistant' : '?????';
  String get welcome => _en
      ? 'Ask me about your servers, logs, status, or a remote file.'
      : '???????????????????';
  String get history => _en ? 'Chat history' : '????';
  String get newChat => _en ? 'New chat' : '???';
  String get delete => _en ? 'Delete' : '??';
  String get deleteChatTitle => _en ? 'Delete chat?' : '?????';
  String deleteChatContent(String title) => _en
      ? 'Delete "$title"? This action cannot be undone.'
      : '?????$title???????????';
  String get deleteBaseUrlHistoryTitle =>
      _en ? 'Delete history entry?' : '???????';
  String deleteBaseUrlHistoryContent(String baseUrl) => _en
      ? 'Delete this Base URL history entry?\n$baseUrl'
      : '?????? Base URL ??????\n$baseUrl';
  String get deleteApiKeyHistoryTitle =>
      _en ? 'Delete API key history?' : '?? API Key ???';
  String deleteApiKeyHistoryContent(String maskedValue) => _en
      ? 'Delete this API key history entry?\n$maskedValue'
      : '?????? API Key ??????\n$maskedValue';
  String get appSettings => _en ? 'App settings' : '????';
  String get settings => _en ? 'LLM settings' : '?????';
  String get send => _en ? 'Send' : '??';
  String get stop => _en ? 'Stop' : '??';
  String get stopped => _en ? '[Stopped by user]' : '[?????]';
  String get baseUrl => _en ? 'Base URL' : 'Base URL';
  String get baseUrlHistory => _en ? 'Base URL history' : 'Base URL ??';
  String get noBaseUrlHistory =>
      _en ? 'No saved Base URLs yet' : '?????? Base URL';
  String get model => _en ? 'Model' : '??';
  String get helperModel => _en ? 'Helper model (optional)' : '????????';
  String get helperModelHint => _en
      ? 'Used for helper agents and fast classification. Leave blank to reuse the main model.'
      : '?? helper agent ????????????????';
  String get auditModel => _en ? 'Audit model (optional)' : '????????';
  String get auditModelHint => _en
      ? 'Used for tool-budget audits and safety checks. Leave blank to reuse the main model.'
      : '????????????????????????';
  String get modelFallbackPolicy => _en ? 'Secondary model policy' : '?????';
  String modelFallbackPolicyLabel(String value) {
    switch (AgentModelFallbackPolicy.normalize(value)) {
      case AgentModelFallbackPolicy.mainOnly:
        return _en ? 'Always use main model' : '???????';
      case AgentModelFallbackPolicy.fallbackToMain:
      default:
        return _en ? 'Fallback to main model' : '?????????';
    }
  }

  String get refreshModels => _en ? 'Refresh models' : '????';
  String get requestTimeout => _en ? 'Request timeout' : '????';
  String get deepSeekThinking => _en ? 'DeepSeek thinking' : 'DeepSeek ????';
  String get deepSeekThinkingHint => _en
      ? 'Only sent to DeepSeek API hosts. Disable it for faster simple replies.'
      : '?? DeepSeek API ?????????????????';
  String get deepSeekReasoningEffort =>
      _en ? 'DeepSeek reasoning effort' : 'DeepSeek ????';
  String get webSearch => _en ? 'Local web search' : '??????';
  String get webSearchHint => _en
      ? 'Expose a web_search tool that uses the current chat WebView on this device. No search API key is required.'
      : '??????????? WebView ????? web_search ???????? API Key?';
  String get ragTitle => _en ? 'RAG Ops Knowledge Base' : 'RAG ?????';
  String get ragHint => _en
      ? 'Locally retrieve relevant context from uploaded operational manuals based on your query.'
      : '????????????????????????????? AI ???';
  String get ragManage => _en ? 'Manage Knowledge Base' : '???????';
  String get ragSearchMode => _en ? 'Retrieval Mode' : '????';
  String get ragSearchModeBm25 =>
      _en ? 'Keywords (BM25 - Offline)' : '??????? (BM25 - ????)';
  String get ragSearchModeVector =>
      _en ? 'Semantic Vector (Aliyun DashScope)' : '?????? (Vector - ????)';
  String get ragSearchModeHybrid =>
      _en ? 'Hybrid RRF (Recommended)' : '?????? (Hybrid - ??????)';
  String get ragSearchModeNeedKey => _en
      ? '?? Semantic & Hybrid modes require Aliyun API Key configured in Knowledge Base settings.'
      : '?? ??????????????????????????????? API ???';
  String get ragTopN =>
      _en ? 'Retrieval Context Count (Top N)' : '??????? (Top N)';
  String ragTopNValue(int value) => _en ? '$value chunks' : '$value ????';
  String get webSearchMaxResults => _en ? 'Search results per call' : '???????';
  String get webSearchEngine => _en ? 'Web search engine' : '????';

  String webSearchEngineLabel(String value) {
    switch (value) {
      case 'google':
        return _en ? 'Google' : '?? (Google)';
      case 'bing':
        return _en ? 'Bing' : '?? (Bing)';
      case 'baidu':
        return _en ? 'Baidu' : '?? (Baidu)';
      case 'quark':
        return _en ? 'Quark Cloud (Aliyun)' : '????? (Quark Cloud)';
      case 'duckduckgo':
      default:
        return _en ? 'DuckDuckGo' : 'DuckDuckGo';
    }
  }

  String get quarkApiKeySaved =>
      _en ? 'Quark API Key (saved, leave blank)' : '?? API Key??????????';
  String get quarkApiKeyRequired => _en ? 'Quark API Key' : '?? API Key';
  String get quarkApiKeyReplaceHint => _en
      ? 'Enter Aliyun Quark Search API Key to replace the saved one.'
      : '????????? API Key????????? Key?';
  String get quarkSearchEndpoint =>
      _en ? 'Quark Search Endpoint' : '???? API ??';
  String get quarkSearchEndpointHint => _en
      ? 'Alibaba Cloud DashScope or Model Studio Quark search API endpoint.'
      : '?????/DashScope ???????????';

  String get multiAgent => _en ? 'Multi-agent collaboration' : '? Agent ??';
  String get multiAgentHint => _en
      ? 'Automatically ask helper agents to plan, suggest safe operations, and review complex tasks before the main answer.'
      : '?????????? Agent ???????????????';
  String get multiAgentMaxAgents =>
      _en ? 'Maximum helper agents' : '???? Agent ?';
  String get toolCallBudget => _en ? 'Tool call budget' : '??????';
  String get toolCallBudgetHint => _en
      ? 'Per request, the first budget hit auto-extends by half. Later extensions require an internal safety audit.'
      : '??????????????????????????????????????';
  String get budgetAuditTitle =>
      _en ? 'Confirm continued tool use' : '??????????';
  String get budgetAuditReason => _en
      ? 'The AI assistant has performed 3 automated safety audits. Do you want to allow it to continue using tools?'
      : 'AI ???????? 3 ???????????????????';
  String get maxImageSize => _en ? 'Image upload size limit' : '????????';
  String get maxFileSize => _en ? 'File upload size limit' : '????????';
  String imageTooLarge(String name, String limit) => _en
      ? 'Image "$name" exceeds the $limit limit.'
      : '???$name??? $limit ???';
  String fileTooLarge(String name, String limit) =>
      _en ? 'File "$name" exceeds the $limit limit.' : '???$name??? $limit ???';
  String get openAiReasoningEffort =>
      _en ? 'OpenAI reasoning effort' : 'OpenAI ????';
  String get openAiReasoningHint => _en
      ? 'Used for supported OpenAI reasoning models such as GPT-5 and o-series.'
      : '????? OpenAI ??????? GPT-5 ? o ???';
  String get continueAfterTimeoutPrompt => _en
      ? 'Continue the previous answer. If a server command timed out, narrow the scope and continue with a smaller diagnostic step.'
      : '???????????????????????????????????';
  String modelsFailed(String error) =>
      _en ? 'Unable to load models: $error' : '???????$error';
  String savedCount(int count) => _en ? '$count saved' : '??? $count ?';
  String get apiKeySaved =>
      _en ? 'API Key (saved, leave blank)' : 'API Key??????????';
  String get apiKeyRequired => _en ? 'API Key' : 'API Key';
  String get apiKeyHistory => _en ? 'API key history' : 'API Key ??';
  String get noApiKeyHistory =>
      _en ? 'No saved API keys yet' : '?????? API Key';
  String get apiKeyReplaceHint => _en
      ? 'Leave this blank to keep the saved key, or enter a new key to replace it.'
      : '????????? Key???? Key ????? Key?';
  String get apiKeyHistoryHint => _en
      ? 'Choose a saved key from history, or enter a new one to add it.'
      : '?????????? Key????? Key ??????';
  String apiKeySelected(String maskedValue) =>
      _en ? 'Current saved key: $maskedValue' : '????? Key?$maskedValue';
  String apiKeyMaskedPreview(String maskedValue) =>
      _en ? 'Selected key: $maskedValue' : '????? Key?$maskedValue';
  String get apiKeyClearPending => _en
      ? 'The saved API key will be removed when you save.'
      : '???????????? API Key?';
  String get clearSavedApiKey => _en ? 'Clear saved API key' : '?????? API Key';
  String get keepSavedApiKey => _en ? 'Keep saved API key' : '?????? API Key';
  String get close => _en ? 'Close' : '??';
  String get cancel => _en ? 'Cancel' : '??';
  String get save => _en ? 'Save' : '??';
  String failed(Object error) => _en ? 'Failed: $error' : '???$error';
  String get commands => _en ? 'Commands' : '??';
  String get planMode => _en ? 'Plan Mode' : '????';
  String get playbooks => _en ? 'Playbooks' : '????';
  String get commandUnknownHint => _en
      ? 'Type a command to use. Available: /compact, /tools, /skills.'
      : '??? / ??????? /compact?/tools ? /skills';
  String get commandUnknown => _en ? 'Unknown slash command.' : '?????????';
  String commandUnknownWithName(String command) =>
      _en ? 'Unknown command: /$command' : '?????: /$command';
  String get commandCompact => _en
      ? 'Context compression is enabled for the next request.'
      : '???????????????';
  String commandToolsUpdated(int count) => _en
      ? 'Tool whitelist updated: $count selected.'
      : '???????????? $count ??';
  String get commandSkillsOpened =>
      _en ? 'Skills manager opened.' : '??? Skills ???';
  String commandToolsUnknown(List<String> unknown) => _en
      ? 'Unknown tool(s): ${unknown.join(', ')}'
      : '??????${unknown.join(', ')}';
  String get commandToolsLoadFailed =>
      _en ? 'Unable to load available tools.' : '?????????';
  String get commandToolsNoTools =>
      _en ? 'No tools are currently available.' : '????????';
  String get commandToolsSearch => _en ? 'Search tools' : '????';
  String get commandToolsNoResult =>
      _en ? 'No tools match the search.' : '?????????';
}
