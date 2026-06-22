part of '../llm_chat_screen.dart';

class _AiStrings {
  final AppLanguage language;

  const _AiStrings(this.language);

  bool get _en => language == AppLanguage.en;

  String get apiFormat => _en ? 'API Format' : 'API 协议格式';
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

  String get title => _en ? 'LLM Assistant' : '大模型助手';
  String get welcome => _en
      ? 'Ask me about your servers, logs, status, or a remote file.'
      : '可以问我服务器状态、日志、远程文件等。';
  String get history => _en ? 'Chat history' : '聊天历史';
  String get newChat => _en ? 'New chat' : '新聊天';
  String get delete => _en ? 'Delete' : '删除';
  String get deleteChatTitle => _en ? 'Delete chat?' : '删除对话？';
  String deleteChatContent(String title) => _en
      ? 'Delete "$title"? This action cannot be undone.'
      : '确定删除“$title”吗？此操作不可恢复。';
  String get deleteBaseUrlHistoryTitle =>
      _en ? 'Delete history entry?' : '删除历史记录？';
  String deleteBaseUrlHistoryContent(String baseUrl) => _en
      ? 'Delete this Base URL history entry?\n$baseUrl'
      : '确定删除这个 Base URL 历史记录吗？\n$baseUrl';
  String get deleteApiKeyHistoryTitle =>
      _en ? 'Delete API key history?' : '删除 API Key 历史？';
  String deleteApiKeyHistoryContent(String maskedValue) => _en
      ? 'Delete this API key history entry?\n$maskedValue'
      : '确定删除这个 API Key 历史记录吗？\n$maskedValue';
  String get appSettings => _en ? 'App settings' : '应用设置';
  String get settings => _en ? 'LLM settings' : '大模型设置';
  String get send => _en ? 'Send' : '发送';
  String get stop => _en ? 'Stop' : '停止';
  String get stopped => _en ? '[Stopped by user]' : '[用户已终止]';
  String get baseUrl => _en ? 'Base URL' : 'Base URL';
  String get baseUrlHistory => _en ? 'Base URL history' : 'Base URL 历史';
  String get noBaseUrlHistory =>
      _en ? 'No saved Base URLs yet' : '还没有保存过 Base URL';
  String get model => _en ? 'Model' : '模型';
  String get helperModel => _en ? 'Helper model (optional)' : '辅助模型（可选）';
  String get helperModelHint => _en
      ? 'Used for helper agents and fast classification. Leave blank to reuse the main model.'
      : '用于 helper agent 和快速分类。留空时回退到主模型。';
  String get auditModel => _en ? 'Audit model (optional)' : '审计模型（可选）';
  String get auditModelHint => _en
      ? 'Used for tool-budget audits and safety checks. Leave blank to reuse the main model.'
      : '用于工具预算审计和安全检查。留空时回退到主模型。';
  String get modelFallbackPolicy => _en ? 'Secondary model policy' : '副模型策略';
  String modelFallbackPolicyLabel(String value) {
    switch (AgentModelFallbackPolicy.normalize(value)) {
      case AgentModelFallbackPolicy.mainOnly:
        return _en ? 'Always use main model' : '始终使用主模型';
      case AgentModelFallbackPolicy.fallbackToMain:
      default:
        return _en ? 'Fallback to main model' : '缺失时回退到主模型';
    }
  }

  String get refreshModels => _en ? 'Refresh models' : '刷新模型';
  String get requestTimeout => _en ? 'Request timeout' : '请求超时';
  String get deepSeekThinking => _en ? 'DeepSeek thinking' : 'DeepSeek 思考模式';
  String get deepSeekThinkingHint => _en
      ? 'Only sent to DeepSeek API hosts. Disable it for faster simple replies.'
      : '仅在 DeepSeek API 地址下发送。关闭后简单回复会更快。';
  String get deepSeekReasoningEffort =>
      _en ? 'DeepSeek reasoning effort' : 'DeepSeek 思考强度';
  String get webSearch => _en ? 'Local web search' : '本地网络搜索';
  String get webSearchHint => _en
      ? 'Expose a web_search tool that uses the current chat WebView on this device. No search API key is required.'
      : '通过当前聊天绑定的本机 WebView 给模型提供 web_search 工具，不需要搜索 API Key。';
  String get ragTitle => _en ? 'RAG Ops Knowledge Base' : 'RAG 运维知识库';
  String get ragHint => _en
      ? 'Locally retrieve relevant context from uploaded operational manuals based on your query.'
      : '根据问题自动在本地检索运维手册与文档，并作为参考上下文喂给 AI 助手。';
  String get ragManage => _en ? 'Manage Knowledge Base' : '管理运维知识库';
  String get ragSearchMode => _en ? 'Retrieval Mode' : '检索模式';
  String get ragSearchModeBm25 =>
      _en ? 'Keywords (BM25 - Offline)' : '本地关键词检索 (BM25 - 完全离线)';
  String get ragSearchModeVector =>
      _en ? 'Semantic Vector (Aliyun DashScope)' : '语义向量检索 (Vector - 通义向量)';
  String get ragSearchModeHybrid =>
      _en ? 'Hybrid RRF (Recommended)' : '双模混合检索 (Hybrid - 推荐效果最好)';
  String get ragSearchModeNeedKey => _en
      ? '⚠️ Semantic & Hybrid modes require Aliyun API Key configured in Knowledge Base settings.'
      : '⚠️ 语义向量与混合检索模式需要在下方“管理运维知识库”中配置阿里云 API 密钥。';
  String get ragTopN =>
      _en ? 'Retrieval Context Count (Top N)' : '知识库参考段数 (Top N)';
  String ragTopNValue(int value) => _en ? '$value chunks' : '$value 个参考段';
  String get webSearchMaxResults => _en ? 'Search results per call' : '每次搜索结果数';
  String get webSearchEngine => _en ? 'Web search engine' : '搜索引擎';

  String webSearchEngineLabel(String value) {
    switch (value) {
      case 'google':
        return _en ? 'Google' : '谷歌 (Google)';
      case 'bing':
        return _en ? 'Bing' : '必应 (Bing)';
      case 'baidu':
        return _en ? 'Baidu' : '百度 (Baidu)';
      case 'quark':
        return _en ? 'Quark Cloud (Aliyun)' : '阿里云夸克 (Quark Cloud)';
      case 'duckduckgo':
      default:
        return _en ? 'DuckDuckGo' : 'DuckDuckGo';
    }
  }

  String get quarkApiKeySaved =>
      _en ? 'Quark API Key (saved, leave blank)' : '夸克 API Key（已保存，留空不改）';
  String get quarkApiKeyRequired => _en ? 'Quark API Key' : '夸克 API Key';
  String get quarkApiKeyReplaceHint => _en
      ? 'Enter Aliyun Quark Search API Key to replace the saved one.'
      : '输入阿里云夸克搜索 API Key。留空保留已保存的 Key。';
  String get quarkSearchEndpoint =>
      _en ? 'Quark Search Endpoint' : '夸克搜索 API 地址';
  String get quarkSearchEndpointHint => _en
      ? 'Alibaba Cloud DashScope or Model Studio Quark search API endpoint.'
      : '阿里云百炼/DashScope 夸克搜索服务接口地址。';

  String get multiAgent => _en ? 'Multi-agent collaboration' : '多 Agent 协作';
  String get multiAgentHint => _en
      ? 'Automatically ask helper agents to plan, suggest safe operations, and review complex tasks before the main answer.'
      : '复杂任务前自动让辅助 Agent 规划、建议安全操作并检查风险。';
  String get multiAgentMaxAgents =>
      _en ? 'Maximum helper agents' : '最大辅助 Agent 数';
  String get toolCallBudget => _en ? 'Tool call budget' : '工具调用预算';
  String get toolCallBudgetHint => _en
      ? 'Per request, the first budget hit auto-extends by half. Later extensions require an internal safety audit.'
      : '按单次请求计数，首次达到预算会自动增加一半；后续每次扩容都需要内部安全审计。';
  String get budgetAuditTitle =>
      _en ? 'Confirm continued tool use' : '确认连续调用工具授权';
  String get budgetAuditReason => _en
      ? 'The AI assistant has performed 3 automated safety audits. Do you want to allow it to continue using tools?'
      : 'AI 助手已自动进行了 3 次安全审计。您是否允许其继续调用工具？';
  String get maxImageSize => _en ? 'Image upload size limit' : '图片上传大小限制';
  String get maxFileSize => _en ? 'File upload size limit' : '文件上传大小限制';
  String imageTooLarge(String name, String limit) => _en
      ? 'Image "$name" exceeds the $limit limit.'
      : '图片「$name」超过 $limit 限制。';
  String fileTooLarge(String name, String limit) =>
      _en ? 'File "$name" exceeds the $limit limit.' : '文件「$name」超过 $limit 限制。';
  String get openAiReasoningEffort =>
      _en ? 'OpenAI reasoning effort' : 'OpenAI 思考强度';
  String get openAiReasoningHint => _en
      ? 'Used for supported OpenAI reasoning models such as GPT-5 and o-series.'
      : '用于支持的 OpenAI 推理模型，例如 GPT-5 和 o 系列。';
  String get continueAfterTimeoutPrompt => _en
      ? 'Continue the previous answer. If a server command timed out, narrow the scope and continue with a smaller diagnostic step.'
      : '继续上一次回答。如果服务器命令超时，请缩小范围，用更小的诊断步骤继续。';
  String modelsFailed(String error) =>
      _en ? 'Unable to load models: $error' : '无法加载模型：$error';
  String savedCount(int count) => _en ? '$count saved' : '已保存 $count 条';
  String get apiKeySaved =>
      _en ? 'API Key (saved, leave blank)' : 'API Key（已保存，留空不改）';
  String get apiKeyRequired => _en ? 'API Key' : 'API Key';
  String get apiKeyHistory => _en ? 'API key history' : 'API Key 历史';
  String get noApiKeyHistory =>
      _en ? 'No saved API keys yet' : '还没有保存过 API Key';
  String get apiKeyReplaceHint => _en
      ? 'Leave this blank to keep the saved key, or enter a new key to replace it.'
      : '留空会保留已保存的 Key，输入新 Key 会替换当前 Key。';
  String get apiKeyHistoryHint => _en
      ? 'Choose a saved key from history, or enter a new one to add it.'
      : '可从历史中选择已保存 Key，或输入新 Key 后保存新增。';
  String apiKeySelected(String maskedValue) =>
      _en ? 'Current saved key: $maskedValue' : '当前已保存 Key：$maskedValue';
  String apiKeyMaskedPreview(String maskedValue) =>
      _en ? 'Selected key: $maskedValue' : '当前选择的 Key：$maskedValue';
  String get apiKeyClearPending => _en
      ? 'The saved API key will be removed when you save.'
      : '保存后会清除当前已保存的 API Key。';
  String get clearSavedApiKey => _en ? 'Clear saved API key' : '清除已保存的 API Key';
  String get keepSavedApiKey => _en ? 'Keep saved API key' : '保留已保存的 API Key';
  String get close => _en ? 'Close' : '关闭';
  String get cancel => _en ? 'Cancel' : '取消';
  String get save => _en ? 'Save' : '保存';
  String failed(Object error) => _en ? 'Failed: $error' : '失败：$error';
  String get commands => _en ? 'Commands' : '命令';
  String get planMode => _en ? 'Plan Mode' : '规划模式';
  String get playbooks => _en ? 'Playbooks' : '运维剧本';
  String get commandUnknownHint => _en
      ? 'Type a command to use. Available: /compact, /tools, /skills.'
      : '输入以 / 开头的命令，如 /compact、/tools 或 /skills';
  String get commandUnknown => _en ? 'Unknown slash command.' : '未识别的斜杠命令。';
  String commandUnknownWithName(String command) =>
      _en ? 'Unknown command: /$command' : '未识别命令: /$command';
  String get commandCompact => _en
      ? 'Context compression is enabled for the next request.'
      : '已为下一次请求启用上下文压缩。';
  String commandToolsUpdated(int count) => _en
      ? 'Tool whitelist updated: $count selected.'
      : '工具白名单已更新：共选中 $count 个。';
  String get commandSkillsOpened =>
      _en ? 'Skills manager opened.' : '已打开 Skills 管理。';
  String commandToolsUnknown(List<String> unknown) => _en
      ? 'Unknown tool(s): ${unknown.join(', ')}'
      : '未识别工具：${unknown.join(', ')}';
  String get commandToolsLoadFailed =>
      _en ? 'Unable to load available tools.' : '无法加载可用工具。';
  String get commandToolsNoTools =>
      _en ? 'No tools are currently available.' : '当前无可用工具。';
  String get commandToolsSearch => _en ? 'Search tools' : '搜索工具';
  String get commandToolsNoResult =>
      _en ? 'No tools match the search.' : '未找到匹配的工具。';
}
