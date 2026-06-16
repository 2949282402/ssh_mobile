import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import '../../../services/ai_tool_service.dart';
import '../../../services/agent_model_profile.dart';
import '../../../services/app_log_service.dart';
import '../../../services/app_settings.dart';
import '../../../services/chat_context_assembler.dart';
import '../../../services/chat_orchestrator.dart';
import '../../../services/llm_chat_service.dart';
import '../../../services/operational_memory_retriever.dart';
import '../../../services/performance_monitor_service.dart';
import '../../../services/performance_monitor_tool_service.dart';
import '../../../services/playbook_service.dart';
import '../../../services/rag_service.dart';
import '../../../services/sftp_service.dart';
import '../../../services/ssh_service.dart';
import '../../../services/storage_service.dart';
import '../../../utils/text_chunker.dart';

@visibleForTesting
String buildApprovedPlanExecutionContext({
  required String userText,
  required AiChatMessageRecord planMessage,
  required AppLanguage language,
}) {
  final isEn = language == AppLanguage.en;
  final steps = planMessage.todoSteps
      .map((step) => {
            'taskId': step.id,
            'name': step.name,
            'command': step.command,
            'description': step.description,
            if (step.connectionId?.trim().isNotEmpty == true)
              'connectionId': step.connectionId,
          })
      .toList(growable: false);
  return [
    isEn ? 'Approved execution plan:' : '已批准执行计划：',
    isEn
        ? 'Use these persisted todoSteps as the source of truth. Execute them sequentially in order. Do not recreate task ids or reparse any earlier playbook text.'
        : '以下持久化 todoSteps 是唯一执行依据。请严格按顺序执行，不要重新创建 taskId，也不要重新解析旧的 playbook 文本。',
    isEn
        ? 'Call client_task_update with status="running" when each step starts, then update it to success, failed, or skipped with stdout/stderr when the step finishes.'
        : '每一步开始时调用 client_task_update(status="running")，完成后再更新为 success、failed 或 skipped，并尽量写入 stdout/stderr。',
    isEn ? 'Persisted steps:' : '持久化步骤：',
    jsonEncode(steps),
    '',
    isEn ? 'User execution trigger:' : '用户执行触发：',
    userText,
  ].join('\n');
}

// ViewModel与View层通信的状态和返回结果
sealed class SendTextResult {
  const SendTextResult();
}

class SendTextSuccess extends SendTextResult {
  const SendTextSuccess();
}

class SendTextApiKeyMissing extends SendTextResult {
  const SendTextApiKeyMissing();
}

class SendTextEmptyText extends SendTextResult {
  const SendTextEmptyText();
}

class SendTextAlreadySending extends SendTextResult {
  const SendTextAlreadySending();
}

class SendTextNoActiveChat extends SendTextResult {
  const SendTextNoActiveChat();
}

class SendTextPlanHasNoSteps extends SendTextResult {
  const SendTextPlanHasNoSteps();
}

class SendTextSlashCommandHandled extends SendTextResult {
  final String feedback;
  const SendTextSlashCommandHandled(this.feedback);
}

class SendTextSlashCommandOpenSkills extends SendTextResult {
  const SendTextSlashCommandOpenSkills();
}

class SendTextSlashCommandOpenToolsSelector extends SendTextResult {
  final List<String> availableTools;
  final Set<String> currentAllowedTools;
  const SendTextSlashCommandOpenToolsSelector({
    required this.availableTools,
    required this.currentAllowedTools,
  });
}

class _StreamingAssistantTarget {
  final String chatId;
  final DateTime assistantCreatedAt;

  const _StreamingAssistantTarget({
    required this.chatId,
    required this.assistantCreatedAt,
  });
}

class PendingToolApproval {
  final String chatId;
  final AiToolApprovalRequest request;
  final Completer<AiToolApprovalDecision> completer;

  const PendingToolApproval({
    required this.chatId,
    required this.request,
    required this.completer,
  });
}

class AiChatViewModel extends ChangeNotifier {
  final StorageService _storageService;
  final SshService _sshService;
  final SftpService _sftpService;
  final PerformanceMonitorService _performanceMonitorService;
  final PlaybookService _playbookService;
  final RagService _ragService;
  final AppSettings _appSettings;

  // 聊天会话状态列表
  List<AiChatRecord> _chats = const [];
  List<AiChatRecord> _savedHistoryChats = const [];
  String? _activeChatId;

  // 操作状态
  bool _loading = true;
  bool _settingsLoadStarted = false;
  bool _historyLoadStarted = false;
  bool _historyLoading = false;
  bool _sending = false;
  bool _toolsExpanded = false;

  // 选中的连接和工具权限
  final Set<String> _selectedConnectionIds = {};
  final Map<String, Set<String>> _chatAllowedTools = {};
  final Set<String> _pendingForceCompressionChats = {};
  final List<AiChatAttachment> _pendingAttachments = [];

  // 工具审批
  PendingToolApproval? _pendingApproval;
  LlmCancellationToken? _activeCancellationToken;

  // 上下文限制
  int _contextWindowTokens = AiContextWindowSize.k259;

  // 估计Token的缓存机制
  String? _contextTokenCacheKey;
  String? _contextTokenCacheChatId;
  int _cachedContextTokens = 0;
  DateTime _lastContextTokenEstimateAt = DateTime.fromMillisecondsSinceEpoch(0);

  // 流式输出ValueNotifier
  final ValueNotifier<String> streamingAssistantText = ValueNotifier<String>('');
  final ValueNotifier<String> streamingAssistantStatus = ValueNotifier<String>('');
  _StreamingAssistantTarget? _streamingAssistantTarget;

  // 通知UI滚动的流
  final StreamController<void> _scrollRequests = StreamController<void>.broadcast();

  AiChatViewModel({
    required StorageService storageService,
    required SshService sshService,
    required SftpService sftpService,
    required PerformanceMonitorService performanceMonitorService,
    required PlaybookService playbookService,
    required RagService ragService,
    required AppSettings appSettings,
  })  : _storageService = storageService,
        _sshService = sshService,
        _sftpService = sftpService,
        _performanceMonitorService = performanceMonitorService,
        _playbookService = playbookService,
        _ragService = ragService,
        _appSettings = appSettings;

  // Getters
  List<AiChatRecord> get chats => _chats;
  List<AiChatRecord> get savedHistoryChats => _savedHistoryChats;
  String? get activeChatId => _activeChatId;
  bool get loading => _loading;
  bool get historyLoading => _historyLoading;
  bool get sending => _sending;
  bool get toolsExpanded => _toolsExpanded;
  Set<String> get selectedConnectionIds => _selectedConnectionIds;
  List<AiChatAttachment> get pendingAttachments => _pendingAttachments;
  PendingToolApproval? get pendingApproval => _pendingApproval;
  int get contextWindowTokens => _contextWindowTokens;
  Stream<void> get scrollRequests => _scrollRequests.stream;

  AiChatRecord? get activeChat {
    for (final chat in _chats) {
      if (chat.id == _activeChatId) return chat;
    }
    return _chats.isEmpty ? null : _chats.first;
  }

  set toolsExpanded(bool value) {
    if (_toolsExpanded != value) {
      _toolsExpanded = value;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_pendingApproval?.completer.isCompleted == false) {
      _pendingApproval!.completer.complete(
        const AiToolApprovalDecision.rejected(),
      );
    }
    _activeCancellationToken?.cancel();
    streamingAssistantText.dispose();
    streamingAssistantStatus.dispose();
    _scrollRequests.close();
    super.dispose();
  }

  void _triggerScroll() {
    _scrollRequests.add(null);
  }

  // 加载初始草稿
  Future<void> loadInitialDraft() async {
    if (_settingsLoadStarted) return;
    _settingsLoadStarted = true;
    final settings = await _storageService.loadAiConnectionSettings();
    final draft = _newChatRecord(settings.model);
    _chats = [draft];
    _activeChatId = draft.id;
    _contextWindowTokens = settings.contextWindowTokens;
    _loading = false;
    notifyListeners();
  }

  // 加载历史记录
  Future<void> loadHistoryChatsIfNeeded() async {
    if (_historyLoadStarted || _historyLoading) return;
    _historyLoading = true;
    notifyListeners();

    final chats = await _storageService.loadAiChats();
    _historyLoadStarted = true;
    _historyLoading = false;
    _savedHistoryChats = chats;

    final drafts = _chats.where((chat) => chat.messages.isEmpty).toList();
    final draftIds = drafts.map((chat) => chat.id).toSet();
    _chats = [
      ...drafts,
      ...chats.where((chat) => !draftIds.contains(chat.id)),
    ];
    _activeChatId ??= _chats.isEmpty ? null : _chats.first.id;
    notifyListeners();
  }

  // 创建/切换/删除会话
  Future<void> createChatFromSettings() async {
    final settings = await _storageService.loadAiConnectionSettings();
    createChat(settings.model);
  }

  void createChat(String model) {
    final chat = _newChatRecord(model);
    _chats = [
      chat,
      ..._chats.where((item) => item.messages.isNotEmpty),
    ];
    _activeChatId = chat.id;
    notifyListeners();
    _triggerScroll();
  }

  void selectChat(String id) {
    if (_activeChatId == id) return;
    _activeChatId = id;
    notifyListeners();
    _triggerScroll();
  }

  Future<void> deleteChat(String id) async {
    if (_chats.isEmpty && _savedHistoryChats.isEmpty) return;
    final deleted = _chatById(id);
    _chatAllowedTools.remove(id);
    _pendingForceCompressionChats.remove(id);
    final nextChats = _chats.where((chat) => chat.id != id).toList();
    if (nextChats.isEmpty) {
      final settings = await _storageService.loadAiConnectionSettings();
      nextChats.add(_newChatRecord(settings.model));
    }
    _chats = nextChats;
    _savedHistoryChats = _savedHistoryChats.where((chat) => chat.id != id).toList();
    if (_activeChatId == id || _activeChatId == null) {
      _activeChatId = nextChats.first.id;
    }
    notifyListeners();
    if (deleted?.messages.isNotEmpty == true) {
      await _storageService.deleteAiChat(id);
    }
    _triggerScroll();
  }

  Future<void> updateActiveChat(AiChatRecord chat) async {
    _replaceChat(chat);
    notifyListeners();
    await _storageService.saveAiChat(chat);
  }

  // 附件操作
  void addAttachment(AiChatAttachment attachment) {
    _pendingAttachments.add(attachment);
    notifyListeners();
  }

  void removeAttachmentAt(int index) {
    if (index >= 0 && index < _pendingAttachments.length) {
      _pendingAttachments.removeAt(index);
      notifyListeners();
    }
  }

  void clearAttachments() {
    _pendingAttachments.clear();
    notifyListeners();
  }

  // 选择服务器连接
  void updateSelectedConnections(Set<String> connectionIds) {
    _selectedConnectionIds.clear();
    _selectedConnectionIds.addAll(connectionIds);
    notifyListeners();
  }

  void updateAllowedTools(String chatId, Set<String> allowedTools) {
    _chatAllowedTools[chatId] = allowedTools;
    notifyListeners();
  }

  // 发送逻辑
  Future<SendTextResult> sendText({
    required String text,
    AiApprovedPlanRef? approvedPlanRef,
  }) async {
    final activeChat = this.activeChat;
    if (text.isEmpty) return const SendTextEmptyText();
    if (_sending) return const SendTextAlreadySending();
    if (activeChat == null) return const SendTextNoActiveChat();

    final normalizedText = text.trim();
    if (normalizedText.startsWith('/')) {
      final handledResult = await _executeSlashCommand(
        chatId: activeChat.id,
        input: normalizedText,
      );
      if (handledResult != null) {
        return handledResult;
      }
    }

    final settings = await _storageService.loadAiConnectionSettings();
    final currentModel = settings.model.trim();
    if (!settings.hasApiKey) {
      AppLogService.instance.warning(
        'LLM chat blocked: API key missing or invalid',
        details: 'model=$currentModel',
      );
      return const SendTextApiKeyMissing();
    }

    _sending = true;
    final chatId = activeChat.id;
    final now = DateTime.now();

    // RAG 检索
    final attachments = List<AiChatAttachment>.from(_pendingAttachments);
    final orchestrator = ChatOrchestrator(
      storageService: _storageService,
      contextAssembler: ChatContextAssembler(
        storageService: _storageService,
      ),
      memoryRetriever: OperationalMemoryRetriever(
        storageService: _storageService,
        ragService: _ragService,
      ),
    );

    final preparedTurn = await orchestrator.prepareTurn(
      chat: activeChat,
      text: text,
      createdAt: now,
      language: _appSettings.language,
      attachments: attachments,
      selectedConnectionIds: _selectedConnectionIds,
      approvedPlanRef: approvedPlanRef,
      ragEnabled: _appSettings.ragEnabled,
    );
    final userMessage = preparedTurn.userMessage;
    final ragChunks = const <RagChunk>[];

    // RAG Traces
    final assistantTraces = List<AiMessageTrace>.from(preparedTurn.assistantMessage.traces);
    if (ragChunks.isNotEmpty) {
      final traceContent = StringBuffer();
      final isEn = _appSettings.isEnglish;
      for (final chunk in ragChunks) {
        traceContent.writeln(isEn
            ? 'Source: [${chunk.documentName}] (Chunk #${chunk.metadata['chunkIndex'] ?? 0})'
            : '来源: [${chunk.documentName}] (分块 #${chunk.metadata['chunkIndex'] ?? 0})');
        traceContent.writeln('---');
        traceContent.writeln(chunk.text);
        traceContent.writeln('========================================\n');
      }
      assistantTraces.add(AiMessageTrace(
        id: 'rag-${now.microsecondsSinceEpoch}',
        kind: 'rag_context',
        title: isEn ? 'Knowledge Base Retrieval (RAG)' : '知识库检索 (RAG)',
        content: traceContent.toString(),
        createdAt: now,
      ));
    }

    final assistantMessage = AiChatMessageRecord(
      role: 'assistant',
      text: '',
      traces: assistantTraces,
      createdAt: now,
    );
    final nextMessages = [
      ...activeChat.messages,
      userMessage,
      assistantMessage,
    ];
    final nextChat = activeChat.copyWith(
      title: activeChat.messages.isEmpty ? _titleFrom(text) : null,
      model: currentModel.isNotEmpty ? currentModel : activeChat.model,
      messages: nextMessages,
      updatedAt: now,
      approvedPlan: approvedPlanRef,
    );

    _replaceChat(nextChat);
    _pendingAttachments.clear();
    _toolsExpanded = false;
    notifyListeners();
    _triggerScroll();

    await _storageService.saveAiChat(nextChat);

    unawaited(_generateAssistantResponse(
      chatId: chatId,
      initialChat: nextChat,
      assistantMessage: assistantMessage,
      model: currentModel.isNotEmpty ? currentModel : nextChat.model,
      requestMessages: nextMessages,
      userRequest: normalizedText,
      memorySources: preparedTurn.memorySources,
      ragHits: preparedTurn.ragHits,
    ));

    return const SendTextSuccess();
  }

  Future<void> approvePlanAndExecute(DateTime assistantCreatedAt) async {
    if (_sending) return;
    final activeChat = this.activeChat;
    if (activeChat == null) return;
    final planMessage = chatAssistantMessageByCreatedAt(activeChat, assistantCreatedAt);
    if (planMessage == null || planMessage.todoSteps.isEmpty) {
      return;
    }

    final approvedAt = DateTime.now();
    final approvedPlan = AiApprovedPlanRef(
      assistantCreatedAt: assistantCreatedAt,
      approvedAt: approvedAt,
    );
    final updatedChat = activeChat.copyWith(
      planMode: false,
      approvedPlan: approvedPlan,
      updatedAt: approvedAt,
    );
    _replaceChat(updatedChat);
    notifyListeners();
    await _storageService.saveAiChat(updatedChat);

    final isEn = _appSettings.language == AppLanguage.en;
    await sendText(
      text: isEn ? 'Execute the approved plan.' : '执行已批准的计划。',
      approvedPlanRef: approvedPlan,
    );
  }

  void stopGeneration() {
    if (!_sending) return;
    _activeCancellationToken?.cancel();
    final pending = _pendingApproval;
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.complete(
        const AiToolApprovalDecision.rejected(abort: true),
      );
    }
    _pendingApproval = null;
    notifyListeners();
  }

  Future<void> regenerateAssistant(int messageIndex) async {
    final activeChat = this.activeChat;
    if (_sending || activeChat == null) return;
    if (messageIndex < 0 || messageIndex >= activeChat.messages.length) return;
    final target = activeChat.messages[messageIndex];
    if (target.role != 'assistant') return;

    final settings = await _storageService.loadAiConnectionSettings();
    if (!settings.hasApiKey) {
      return;
    }

    final prefix = activeChat.messages.take(messageIndex).toList();
    if (prefix.where((message) => message.role == 'user').isEmpty) return;
    final now = DateTime.now();
    final assistantMessage = AiChatMessageRecord(
      role: 'assistant',
      text: '',
      createdAt: now,
    );
    final nextMessages = [...prefix, assistantMessage];
    final nextModel = settings.model.trim().isNotEmpty ? settings.model : activeChat.model;
    final nextChat = activeChat.copyWith(
      model: nextModel,
      messages: nextMessages,
      updatedAt: now,
    );

    _replaceChat(nextChat);
    _sending = true;
    notifyListeners();
    _triggerScroll();

    await _storageService.saveAiChat(nextChat);

    await _generateAssistantResponse(
      chatId: activeChat.id,
      initialChat: nextChat,
      assistantMessage: assistantMessage,
      model: nextModel,
      requestMessages: nextMessages,
      userRequest: prefix.lastWhere((message) => message.role == 'user').text,
      memorySources: const [],
      ragHits: 0,
    );
  }

  Future<void> editUserMessage(int messageIndex, String trimmedEditedText) async {
    final activeChat = this.activeChat;
    if (_sending || activeChat == null) return;
    if (messageIndex < 0 || messageIndex >= activeChat.messages.length) return;
    final target = activeChat.messages[messageIndex];
    if (target.role != 'user') return;
    if (trimmedEditedText.isEmpty) return;

    final targetIndex = activeChat.messages.indexWhere(
      (message) => message.role == 'user' && message.createdAt == target.createdAt,
    );
    if (targetIndex < 0 || targetIndex >= activeChat.messages.length) {
      return;
    }

    final settings = await _storageService.loadAiConnectionSettings();
    if (!settings.hasApiKey) {
      return;
    }

    final currentTarget = activeChat.messages[targetIndex];
    if (currentTarget.role != 'user') return;

    final now = DateTime.now();
    final editedUser = currentTarget.copyWith(
      text: trimmedEditedText,
      createdAt: now,
    );
    final assistantMessage = AiChatMessageRecord(
      role: 'assistant',
      text: '',
      createdAt: now,
    );
    final nextMessages = [
      ...activeChat.messages.take(targetIndex),
      editedUser,
      assistantMessage,
    ];
    final nextModel = settings.model.trim().isNotEmpty ? settings.model : activeChat.model;
    final nextChat = activeChat.copyWith(
      title: targetIndex == 0 ? _titleFrom(trimmedEditedText) : null,
      model: nextModel,
      messages: nextMessages,
      updatedAt: now,
    );

    _replaceChat(nextChat);
    _sending = true;
    notifyListeners();
    _triggerScroll();

    await _storageService.saveAiChat(nextChat);

    await _generateAssistantResponse(
      chatId: activeChat.id,
      initialChat: nextChat,
      assistantMessage: assistantMessage,
      model: nextModel,
      requestMessages: nextMessages,
      userRequest: trimmedEditedText,
      memorySources: const [],
      ragHits: 0,
    );
  }

  void branchFromAssistant(int messageIndex) {
    final activeChat = this.activeChat;
    if (_sending || activeChat == null) return;
    if (messageIndex < 0 || messageIndex >= activeChat.messages.length) return;
    final target = activeChat.messages[messageIndex];
    if (target.role != 'assistant') return;

    final now = DateTime.now();
    final isEn = _appSettings.language == AppLanguage.en;
    final branch = AiChatRecord(
      id: 'ai-${now.microsecondsSinceEpoch}',
      title: '${activeChat.title} ${isEn ? 'Branch' : '分支'}',
      model: activeChat.model,
      messages: activeChat.messages.take(messageIndex + 1).toList(),
      createdAt: now,
      updatedAt: now,
    );

    _chats = [branch, ..._chats];
    if (branch.messages.isNotEmpty) {
      _savedHistoryChats = [branch, ..._savedHistoryChats];
      _historyLoadStarted = true;
    }
    _activeChatId = branch.id;
    notifyListeners();

    _storageService.saveAiChat(branch);
    _triggerScroll();
  }

  // 上下文 Token 压缩与估计逻辑 (吸收自原 chat_token_compression.dart)
  Future<String?> contextTextForUser(
    String text, {
    List<RagChunk> ragChunks = const [],
    AiChatMessageRecord? approvedPlanMessage,
  }) async {
    final lines = <String>[];
    if (_selectedConnectionIds.isNotEmpty) {
      final serverInfos = <String>[];
      for (final id in _selectedConnectionIds) {
        final connection = _storageService.getConnection(id);
        if (connection != null) {
          serverInfos.add(
            '- ${connection.name} (id: ${connection.id}, host: ${connection.username}@${connection.host}:${connection.port})',
          );
        }
      }
      if (serverInfos.isNotEmpty) {
        lines.add('Target servers:\n${serverInfos.join('\n')}');
      }
    }

    if (ragChunks.isNotEmpty) {
      final isEn = _appSettings.isEnglish;
      final ragLines = <String>[];
      ragLines.add(isEn
          ? '【Ops Knowledge Base Reference Information】:'
          : '【运维知识库参考信息】：');
      for (final chunk in ragChunks) {
        ragLines.add('---');
        ragLines.add(isEn
            ? 'Source: [${chunk.documentName}] (Chunk #${chunk.metadata['chunkIndex'] ?? 0})'
            : '来源: [${chunk.documentName}] (分块 #${chunk.metadata['chunkIndex'] ?? 0})');
        ragLines.add('${isEn ? 'Content' : '内容'}:\n${chunk.text}');
      }
      ragLines.add('---');
      lines.add(ragLines.join('\n'));
    }

    final requestBlock = approvedPlanMessage != null && approvedPlanMessage.todoSteps.isNotEmpty
        ? buildApprovedPlanExecutionContext(
            userText: text,
            planMessage: approvedPlanMessage,
            language: _appSettings.language,
          )
        : 'User request:\n$text';
    if (lines.isEmpty) return requestBlock;
    return '${lines.join('\n\n')}\n\n$requestBlock';
  }

  String _contextTextForAssistant(
    String text, {
    List<AiMessageTrace> traces = const [],
  }) {
    final trimmed = text.trim();
    final body = trimmed.isEmpty
        ? trimmed
        : !_shouldOmitAssistantBody(trimmed)
            ? trimmed
            : _slimAssistantBody(trimmed);
    if (traces.isEmpty) return body;

    final buffer = StringBuffer();
    if (body.isNotEmpty) {
      buffer.writeln(body);
      buffer.writeln();
    }
    buffer.writeln('Assistant execution memory:');
    for (final trace in traces) {
      buffer
        ..writeln('[${trace.kind}] ${trace.title}')
        ..writeln(_traceMemoryContent(trace))
        ..writeln();
    }
    return buffer.toString().trimRight();
  }

  String _traceMemoryContent(AiMessageTrace trace) {
    final trimmed = trace.content.trim();
    if (trimmed.length <= 2500) return trimmed;
    final preview = trimmed.replaceAll(RegExp(r'\s+'), ' ').trim().runes.take(900);
    return '[Large ${trace.kind} output omitted from future context. '
        'The full trace remains visible in chat history. '
        'Length: ${trimmed.length} chars. '
        'Preview: ${String.fromCharCodes(preview)}]';
  }

  String _slimAssistantBody(String trimmed) {
    final preview = trimmed.replaceAll(RegExp(r'\s+'), ' ').trim().runes.take(420);
    final type = _largeAssistantBodyType(trimmed);
    return '[Large $type output omitted from future context. '
        'The full content remains visible in chat history. '
        'Length: ${trimmed.length} chars. '
        'Preview: ${String.fromCharCodes(preview)}]';
  }

  bool _shouldOmitAssistantBody(String text) {
    final lowerText = text.toLowerCase();
    if (text.length > 6000) return true;
    if (text.length > 2500 && _codeFenceCount(text) >= 2) return true;
    if (text.length > 2500 &&
        (lowerText.contains('<html') || lowerText.contains('<!doctype'))) {
      return true;
    }
    if (text.length > 3000 && _markdownDocumentScore(text) >= 10) return true;
    return false;
  }

  String _largeAssistantBodyType(String text) {
    final lowerText = text.toLowerCase();
    if (lowerText.contains('<html') || lowerText.contains('<!doctype')) {
      return 'HTML';
    }
    if (_codeFenceCount(text) >= 2) return 'code/document';
    if (_markdownDocumentScore(text) >= 10) return 'Markdown/document';
    return 'document';
  }

  int _codeFenceCount(String text) {
    return RegExp(r'```').allMatches(text).length;
  }

  int _markdownDocumentScore(String text) {
    var score = 0;
    for (final line in text.split('\n')) {
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('#')) score += 2;
      if (trimmed.startsWith('|')) score++;
      if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) score++;
      if (RegExp(r'^\d+\. ').hasMatch(trimmed)) score++;
    }
    return score;
  }

  int contextTokensFor(AiChatRecord chat) {
    final key = _contextTokenKey(chat);
    if (_contextTokenCacheKey == key) return _cachedContextTokens;
    final now = DateTime.now();
    if (_sending &&
        _contextTokenCacheChatId == chat.id &&
        _contextTokenCacheKey != null &&
        now.difference(_lastContextTokenEstimateAt) < const Duration(milliseconds: 1500)) {
      return _cachedContextTokens;
    }
    _contextTokenCacheKey = key;
    _contextTokenCacheChatId = chat.id;
    _lastContextTokenEstimateAt = now;
    _cachedContextTokens = _estimatedContextTokens(chat.messages);
    return _cachedContextTokens;
  }

  String _contextTokenKey(AiChatRecord chat) {
    final messages = chat.messages;
    if (messages.isEmpty) return '${chat.id}:0';
    final last = messages.last;
    return [
      chat.id,
      messages.length,
      last.role,
      last.createdAt.microsecondsSinceEpoch,
      last.text.length,
      last.contextText?.length ?? 0,
      last.traces.length,
    ].join(':');
  }

  int _estimatedContextTokens(List<AiChatMessageRecord> messages) {
    final mapped = <Map<String, dynamic>>[
      <String, dynamic>{'role': 'system', 'content': 'system'},
      ..._messagesForRequest(messages),
    ];
    return LlmChatService.estimateMessagesTokens(mapped);
  }

  ValueListenable<String>? streamingTextFor(
    String chatId,
    AiChatMessageRecord message,
  ) {
    final target = _streamingAssistantTarget;
    if (message.role != 'assistant' ||
        target == null ||
        target.chatId != chatId ||
        target.assistantCreatedAt != message.createdAt) {
      return null;
    }
    return streamingAssistantText;
  }

  ValueListenable<String>? streamingStatusFor(
    String chatId,
    AiChatMessageRecord message,
  ) {
    final target = _streamingAssistantTarget;
    if (message.role != 'assistant' ||
        target == null ||
        target.chatId != chatId ||
        target.assistantCreatedAt != message.createdAt) {
      return null;
    }
    return streamingAssistantStatus;
  }

  // 私有辅助方法
  AiChatRecord? _chatById(String id) {
    for (final chat in _chats) {
      if (chat.id == id) return chat;
    }
    for (final chat in _savedHistoryChats) {
      if (chat.id == id) return chat;
    }
    return null;
  }

  void _replaceChat(AiChatRecord chat, {bool sort = true}) {
    _chats = sort
        ? upsertAiChatRecordsByUpdatedAt(_chats, chat)
        : _replaceChatWithoutReordering(_chats, chat);
    if (chat.messages.isNotEmpty) {
      _savedHistoryChats = sort && _historyLoadStarted
          ? upsertAiChatRecordsByUpdatedAt(_savedHistoryChats, chat)
          : _replaceChatWithoutReordering(
              _savedHistoryChats,
              chat,
              insertIfMissing: false,
            );
    }
    _activeChatId = chat.id;
  }

  List<AiChatRecord> _replaceChatWithoutReordering(
    List<AiChatRecord> chats,
    AiChatRecord chat, {
    bool insertIfMissing = true,
  }) {
    final next = [...chats];
    final index = next.indexWhere((item) => item.id == chat.id);
    if (index >= 0) {
      next[index] = chat;
    } else if (insertIfMissing) {
      next.insert(0, chat);
    }
    return next;
  }

  AiChatRecord _newChatRecord(String model) {
    final now = DateTime.now();
    final isEn = _appSettings.language == AppLanguage.en;
    return AiChatRecord(
      id: 'ai-${now.microsecondsSinceEpoch}',
      title: isEn ? 'New chat' : '新对话',
      model: model,
      messages: const [],
      createdAt: now,
      updatedAt: now,
    );
  }

  String _titleFrom(String text) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) {
      return _appSettings.language == AppLanguage.en ? 'New chat' : '新对话';
    }
    return cleaned.length > 22 ? '${cleaned.substring(0, 22)}...' : cleaned;
  }

  List<Map<String, dynamic>> _messagesForRequest(
    List<AiChatMessageRecord> messages, {
    AiChatMessageRecord? placeholder,
  }) {
    return messages
        .where((message) => message.role != 'error')
        .where((message) => message != placeholder)
        .map((message) {
          final textContent = _contextContentFor(message);
          if (textContent.trim().isEmpty && message.attachments.isEmpty) {
            return null;
          }
          final role = message.role == 'user' ? 'user' : 'assistant';
          if (message.role == 'user' && message.attachments.isNotEmpty) {
            return <String, dynamic>{
              'role': role,
              'content': buildMultipartContent(textContent, message.attachments),
            };
          }
          return <String, dynamic>{
            'role': role,
            'content': textContent,
          };
        })
        .nonNulls
        .toList();
  }

  static List<Map<String, dynamic>> buildMultipartContent(
    String textContent,
    List<AiChatAttachment> attachments,
  ) {
    final textWithFiles = StringBuffer(textContent);
    for (final attachment in attachments) {
      if (!attachment.isImage) {
        if (attachment.isTextFile && attachment.dataBase64.isNotEmpty) {
          try {
            final decoded = utf8.decode(base64Decode(attachment.dataBase64));
            textWithFiles.write('\n\n[File: ${attachment.fileName}]\n$decoded');
          } catch (_) {
            textWithFiles.write(
              '\n\n[Attached file: ${attachment.fileName} (${_formatAttachmentSize(attachment.sizeBytes)})]',
            );
          }
        } else {
          textWithFiles.write(
            '\n\n[Attached file: ${attachment.fileName} (${_formatAttachmentSize(attachment.sizeBytes)})]',
          );
        }
      }
    }
    final parts = <Map<String, dynamic>>[
      {'type': 'text', 'text': textWithFiles.toString()},
    ];
    for (final attachment in attachments) {
      if (attachment.isImage && attachment.dataBase64.isNotEmpty) {
        parts.add({
          'type': 'image_url',
          'image_url': {
            'url': 'data:${attachment.mimeType};base64,${attachment.dataBase64}',
          },
        });
      }
    }
    return parts;
  }

  static String _formatAttachmentSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }

  String _contextContentFor(AiChatMessageRecord message) {
    if (message.role == 'user' && message.contextText != null) {
      return message.contextText!;
    }
    if (message.role == 'assistant') {
      return message.contextText ?? _contextTextForAssistant(message.text, traces: message.traces);
    }
    return message.text;
  }

  // LLM流输出核心实现
  Future<void> _generateAssistantResponse({
    required String chatId,
    required AiChatRecord initialChat,
    required AiChatMessageRecord assistantMessage,
    required String model,
    required List<AiChatMessageRecord> requestMessages,
    required String userRequest,
    required List<String> memorySources,
    required int ragHits,
  }) async {
    final settings = await _storageService.loadAiConnectionSettings();
    final modelProfile = AgentModelProfile(
      mainModel: model,
      helperModel: settings.helperModel,
      auditModel: settings.auditModel,
      fallbackPolicy: settings.modelFallbackPolicy,
    );

    final service = LlmChatService(
      storageService: _storageService,
      toolService: AiToolService(
        storageService: _storageService,
        sshService: _sshService,
        sftpService: _sftpService,
        performanceMonitorToolService: PerformanceMonitorToolService(_performanceMonitorService),
        appSettings: _appSettings,
        playbookService: _playbookService,
        clientWebViewSessionId: chatId,
      ),
      language: _appSettings.language,
      useCustomPrompts: settings.useCustomPrompts,
      customSystemPrompt: settings.customSystemPrompt,
      customPlannerPrompt: settings.customPlannerPrompt,
      customOperatorPrompt: settings.customOperatorPrompt,
      customExplorePrompt: settings.customExplorePrompt,
      customReviewerPrompt: settings.customReviewerPrompt,
      customSummarizerPrompt: settings.customSummarizerPrompt,
      customCoordinatorPrompt: settings.customCoordinatorPrompt,
    );

    final cancellationToken = LlmCancellationToken();
    _activeCancellationToken = cancellationToken;
    final answer = StringBuffer();
    final forceContextCompression = _consumeContextCompression(chatId);
    final allowedTools = _chatAllowedTools[chatId];

    _beginStreamingAssistant(
      chatId: chatId,
      assistantCreatedAt: assistantMessage.createdAt,
      status: _assistantStatusForString(AgentStatusString.preparing),
    );

    try {
      LlmRunStats? runStats;
      var lastStreamUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);

      await for (final chunk in service.stream(
        modelOverride: model,
        onStats: (stats) => runStats = stats,
        onTrace: (event) {
          _updateStreamingAssistantStatus(_assistantStatusForTrace(event));
          _appendTraceToAssistant(
            chatId: chatId,
            assistantCreatedAt: assistantMessage.createdAt,
            event: event,
          );
        },
        requestToolApproval: (request) {
          return _requestToolApproval(
            chatId: chatId,
            request: request,
          );
        },
        allowedTools: allowedTools,
        forceContextCompression: forceContextCompression,
        cancellationToken: cancellationToken,
        planMode: initialChat.planMode,
        userRequest: userRequest,
        selectedConnectionIds: _selectedConnectionIds,
        hasWebViewSession: true,
        hasApprovedPlan: initialChat.approvedPlan != null,
        memorySources: memorySources,
        messages: _messagesForRequest(
          requestMessages,
          placeholder: assistantMessage,
        ),
      )) {
        answer.write(chunk);
        _updateStreamingAssistantStatus(_assistantStatusForString(AgentStatusString.responding));
        final now = DateTime.now();
        if (now.difference(lastStreamUiUpdate) < const Duration(milliseconds: 120)) {
          continue;
        }
        lastStreamUiUpdate = now;
        _updateStreamingAssistant(answer.toString());
        _triggerScroll();
      }

      final currentChat = _chatById(chatId) ?? initialChat;
      final completedMessages = [...currentChat.messages];
      final assistantIndex = completedMessages.indexWhere(
        (message) => message.role == 'assistant' && message.createdAt == assistantMessage.createdAt,
      );

      final orchestrator = ChatOrchestrator(
        storageService: _storageService,
        contextAssembler: ChatContextAssembler(storageService: _storageService),
        memoryRetriever: OperationalMemoryRetriever(
          storageService: _storageService,
          ragService: _ragService,
        ),
      );

      if (assistantIndex >= 0) {
        final completion = orchestrator.finalizeAssistantTurn(
          initialChat: initialChat,
          assistantMessage: completedMessages[assistantIndex],
          answerText: answer.toString(),
          traces: [...completedMessages[assistantIndex].traces],
        );
        completedMessages[assistantIndex] = completion.assistantMessage.copyWith(
          promptTokens: runStats?.promptTokens,
          completionTokens: runStats?.completionTokens,
          totalTokens: runStats?.totalTokens,
          elapsedMs: runStats?.elapsedMs,
          tokenUsageEstimated: runStats == null ? null : !runStats!.usageFromProvider,
          promptCacheHitTokens: runStats?.promptCacheHitTokens,
          promptCacheMissTokens: runStats?.promptCacheMissTokens,
          reasoningTokens: runStats?.reasoningTokens,
        );
      }

      final latestAssistant = latestAssistantMessageForChat(
        currentChat.copyWith(messages: completedMessages),
      );
      final shouldExitPlanMode = initialChat.planMode && latestAssistant?.todoSteps.isNotEmpty == true;
      final answeredChat = currentChat.copyWith(
        messages: completedMessages,
        updatedAt: DateTime.now(),
        planMode: shouldExitPlanMode ? false : currentChat.planMode,
      );

      _clearStreamingAssistant(
        chatId: chatId,
        assistantCreatedAt: assistantMessage.createdAt,
      );
      _replaceChat(answeredChat);
      _sending = false;
      notifyListeners();
      await _storageService.saveAiChat(answeredChat);

      await _persistAgentRunMetrics(
        modelProfile: modelProfile,
        model: model,
        startedAt: assistantMessage.createdAt,
        finishedAt: DateTime.now(),
        runStats: runStats,
        ragHits: ragHits,
        success: true,
      );
    } on LlmCancelledException {
      AppLogService.instance.info(
        'LLM chat UI request cancelled',
        details: 'chatId=$chatId model=$model',
      );
      final currentChat = _chatById(chatId) ?? initialChat;
      final cancelledMessages = [...currentChat.messages];
      final assistantIndex = cancelledMessages.indexWhere(
        (message) => message.role == 'assistant' && message.createdAt == assistantMessage.createdAt,
      );
      final stopStr = _assistantStatusForString(AgentStatusString.stopped);
      if (assistantIndex >= 0) {
        final stoppedText = answer.toString().trim().isEmpty
            ? stopStr
            : '${answer.toString()}\n\n$stopStr';
        final traces = [
          ...cancelledMessages[assistantIndex].traces,
          AiMessageTrace.create(
            kind: 'approval',
            title: 'Stopped by user',
            content: stopStr,
          ),
        ];
        cancelledMessages[assistantIndex] = cancelledMessages[assistantIndex].copyWith(
          text: stoppedText,
          traces: traces,
          contextText: _contextTextForAssistant(stoppedText, traces: traces),
        );
      }
      final cancelledChat = currentChat.copyWith(
        messages: cancelledMessages,
        updatedAt: DateTime.now(),
      );

      _clearStreamingAssistant(
        chatId: chatId,
        assistantCreatedAt: assistantMessage.createdAt,
      );
      _replaceChat(cancelledChat);
      _sending = false;
      notifyListeners();
      await _storageService.saveAiChat(cancelledChat);

      await _persistAgentRunMetrics(
        modelProfile: modelProfile,
        model: model,
        startedAt: assistantMessage.createdAt,
        finishedAt: DateTime.now(),
        ragHits: ragHits,
        success: false,
      );
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'LLM chat UI request failed',
        error: e,
        stackTrace: stackTrace,
        details: 'chatId=$chatId model=$model',
      );
      final currentChat = _chatById(chatId) ?? initialChat;
      final errorMessages = [...currentChat.messages];
      final assistantIndex = errorMessages.indexWhere(
        (message) => message.role == 'assistant' && message.createdAt == assistantMessage.createdAt,
      );
      if (assistantIndex >= 0) {
        final partialText = answer.toString();
        if (partialText.trim().isEmpty && errorMessages[assistantIndex].text.isEmpty) {
          errorMessages.removeAt(assistantIndex);
        } else if (partialText.isNotEmpty) {
          errorMessages[assistantIndex] = errorMessages[assistantIndex].copyWith(
            text: partialText,
            contextText: _contextTextForAssistant(
              partialText,
              traces: errorMessages[assistantIndex].traces,
            ),
          );
        }
      }
      final errorChat = currentChat.copyWith(
        messages: [
          ...errorMessages,
          AiChatMessageRecord(
            role: 'error',
            text: _assistantFailedString(e),
            createdAt: DateTime.now(),
          ),
        ],
        updatedAt: DateTime.now(),
      );

      _clearStreamingAssistant(
        chatId: chatId,
        assistantCreatedAt: assistantMessage.createdAt,
      );
      _replaceChat(errorChat);
      _sending = false;
      notifyListeners();
      await _storageService.saveAiChat(errorChat);

      await _persistAgentRunMetrics(
        modelProfile: modelProfile,
        model: model,
        startedAt: assistantMessage.createdAt,
        finishedAt: DateTime.now(),
        ragHits: ragHits,
        success: false,
      );
    } finally {
      _clearStreamingAssistant(
        chatId: chatId,
        assistantCreatedAt: assistantMessage.createdAt,
      );
      _sending = false;
      if (_pendingApproval?.chatId == chatId) {
        _pendingApproval = null;
      }
      if (identical(_activeCancellationToken, _activeCancellationToken)) {
        _activeCancellationToken = null;
      }
      notifyListeners();
      _triggerScroll();
    }
  }

  Future<AiToolApprovalDecision> _requestToolApproval({
    required String chatId,
    required AiToolApprovalRequest request,
  }) {
    final completer = Completer<AiToolApprovalDecision>();
    final prompt = _assistantAwaitingApprovalStatus(request.connectionName);
    _updateStreamingAssistantStatus(prompt);

    _pendingApproval = PendingToolApproval(
      chatId: chatId,
      request: request,
      completer: completer,
    );
    notifyListeners();
    _triggerScroll();
    return completer.future;
  }

  void resolvePendingApproval({required bool approved}) {
    final pending = _pendingApproval;
    if (pending == null || pending.completer.isCompleted) return;
    _pendingApproval = null;
    notifyListeners();
    pending.completer.complete(
      approved
          ? const AiToolApprovalDecision.approved()
          : const AiToolApprovalDecision.rejected(),
    );
  }

  void _beginStreamingAssistant({
    required String chatId,
    required DateTime assistantCreatedAt,
    required String status,
  }) {
    _streamingAssistantTarget = _StreamingAssistantTarget(
      chatId: chatId,
      assistantCreatedAt: assistantCreatedAt,
    );
    streamingAssistantText.value = '';
    streamingAssistantStatus.value = status;
  }

  void _updateStreamingAssistant(String text) {
    if (streamingAssistantText.value == text) return;
    streamingAssistantText.value = text;
  }

  void _updateStreamingAssistantStatus(String status) {
    if (_streamingAssistantTarget == null) return;
    if (streamingAssistantStatus.value == status) return;
    streamingAssistantStatus.value = status;
  }

  void _clearStreamingAssistant({
    required String chatId,
    required DateTime assistantCreatedAt,
  }) {
    final target = _streamingAssistantTarget;
    if (target == null || target.chatId != chatId || target.assistantCreatedAt != assistantCreatedAt) {
      return;
    }
    _streamingAssistantTarget = null;
    streamingAssistantText.value = '';
    streamingAssistantStatus.value = '';
  }

  void _appendTraceToAssistant({
    required String chatId,
    required DateTime assistantCreatedAt,
    required LlmTraceEvent event,
  }) {
    final currentChat = _chatById(chatId);
    if (currentChat == null) return;
    final messages = [...currentChat.messages];
    final assistantIndex = messages.indexWhere(
      (message) => message.role == 'assistant' && message.createdAt == assistantCreatedAt,
    );
    if (assistantIndex < 0) return;
    messages[assistantIndex] = messages[assistantIndex].copyWith(
      traces: [
        ...messages[assistantIndex].traces,
        AiMessageTrace.create(
          kind: event.kind,
          title: event.title,
          content: event.content,
        ),
      ],
    );
    _replaceChat(
      currentChat.copyWith(
        messages: messages,
        updatedAt: DateTime.now(),
      ),
      sort: false,
    );
    notifyListeners();
    _triggerScroll();
  }

  bool _consumeContextCompression(String chatId) {
    return _pendingForceCompressionChats.remove(chatId);
  }

  // 内部辅助，从Slash命令提取
  Future<SendTextResult?> _executeSlashCommand({
    required String chatId,
    required String input,
  }) async {
    final parts = input.split(' ');
    final cmd = parts[0].toLowerCase();
    final args = parts.sublist(1).join(' ').trim();
    final activeChat = this.activeChat;
    if (activeChat == null) return null;

    final isEn = _appSettings.language == AppLanguage.en;

    if (cmd == '/compact') {
      _pendingForceCompressionChats.add(chatId);
      return SendTextSlashCommandHandled(
        isEn
            ? 'Forced context compaction scheduled for the next generation.'
            : '已强制计划在下一次生成时对上下文进行压缩。',
      );
    }

    if (cmd == '/plan') {
      final updated = activeChat.copyWith(
        planMode: true,
        updatedAt: DateTime.now(),
      );
      _replaceChat(updated);
      notifyListeners();
      await _storageService.saveAiChat(updated);
      return SendTextSlashCommandHandled(
        isEn
            ? 'Plan Mode Enabled. Helper agents will analyze read-only details and prepare structured playbooks.'
            : '规划模式已启用。多 Agent 协作将仅执行只读信息收集并生成 Playbook 步骤。',
      );
    }

    if (cmd == '/tools') {
      final tools = _parseToolList(args);
      if (tools.isEmpty) {
        final service = AiToolService(
          storageService: _storageService,
          sshService: _sshService,
          sftpService: _sftpService,
          performanceMonitorToolService: PerformanceMonitorToolService(_performanceMonitorService),
          appSettings: _appSettings,
          playbookService: _playbookService,
        );
        final definitions = await service.toolDefinitions();
        final names = definitions
            .map((def) => _toolNameFromDefinition(def))
            .nonNulls
            .where((name) => name.isNotEmpty)
            .toList();
        return SendTextSlashCommandOpenToolsSelector(
          availableTools: names,
          currentAllowedTools: _chatAllowedTools[chatId] ?? const {},
        );
      } else {
        final nextAllowed = Set<String>.from(tools);
        _chatAllowedTools[chatId] = nextAllowed;
        notifyListeners();
        return SendTextSlashCommandHandled(
          isEn ? 'Restricted active toolset to: ${tools.join(", ")}' : '已限制当前对话的工具调用范围为: ${tools.join(", ")}',
        );
      }
    }

    if (cmd == '/skills') {
      return const SendTextSlashCommandOpenSkills();
    }

    return null;
  }

  List<String> _parseToolList(String text) {
    return text
        .split(RegExp(r'[,\s]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  String? _toolNameFromDefinition(Map<String, dynamic> definition) {
    final function = definition['function'];
    if (function is! Map) return null;
    final name = function['name'];
    return name is String ? name : null;
  }

  Future<void> _persistAgentRunMetrics({
    required AgentModelProfile modelProfile,
    required String model,
    required DateTime startedAt,
    required DateTime finishedAt,
    LlmRunStats? runStats,
    required int ragHits,
    required bool success,
  }) async {
    final promptTokens = runStats?.promptTokens ?? 0;
    final completionTokens = runStats?.completionTokens ?? 0;
    final totalTokens = runStats?.totalTokens ?? promptTokens + completionTokens;
    final helperModel = modelProfile.resolve(AgentModelRole.helper);
    final auditModel = modelProfile.resolve(AgentModelRole.audit);

    await _storageService.saveAgentRunMetrics(
      AgentRunMetrics(
        id: 'run-${startedAt.microsecondsSinceEpoch}',
        startedAt: startedAt,
        finishedAt: finishedAt,
        model: model,
        helperModel: helperModel == model ? '' : helperModel,
        auditModel: auditModel == model ? '' : auditModel,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        totalTokens: totalTokens,
        elapsedMs: runStats?.elapsedMs ?? finishedAt.difference(startedAt).inMilliseconds,
        toolCalls: runStats?.toolCalls ?? 0,
        cacheHits: runStats?.cacheHits ?? 0,
        dedupBlockedCalls: runStats?.dedupBlockedCalls ?? 0,
        ragHits: ragHits,
        approvalCount: runStats?.approvalCount ?? 0,
        approvedCount: runStats?.approvedCount ?? 0,
        auditCount: runStats?.auditEscalationLevel ?? 0,
        helperFanout: runStats?.helperFanout ?? 0,
        success: success,
        selectedToolSet: runStats?.selectedToolSet ?? const [],
        memorySources: runStats?.memorySources ?? const [],
      ),
    );
  }

  // 状态字符串的多语言逻辑封装
  String _assistantStatusForString(AgentStatusString status) {
    final isEn = _appSettings.language == AppLanguage.en;
    switch (status) {
      case AgentStatusString.preparing:
        return isEn ? 'Preparing response...' : '模型正在准备回答...';
      case AgentStatusString.thinking:
        return isEn ? 'Thinking...' : '模型正在思考...';
      case AgentStatusString.responding:
        return isEn ? 'Generating answer...' : '正在输出回答...';
      case AgentStatusString.processingToolResult:
        return isEn ? 'Processing tool result...' : '正在处理工具结果...';
      case AgentStatusString.processingApproval:
        return isEn ? 'Processing approval decision...' : '正在处理审批结果...';
      case AgentStatusString.collaborating:
        return isEn ? 'Coordinating helper agents...' : '正在协调多 Agent 协作...';
      case AgentStatusString.stopped:
        return isEn ? 'Generation stopped.' : '输出已停止。';
    }
  }

  String _assistantStatusForTrace(LlmTraceEvent event) {
    switch (event.kind) {
      case 'reasoning':
        return _assistantStatusForString(AgentStatusString.thinking);
      case 'tool_request':
        return _assistantRunningToolStatus(_traceToolName(event.title));
      case 'tool_result':
        return _assistantStatusForString(AgentStatusString.processingToolResult);
      case 'approval':
        return _assistantStatusForString(AgentStatusString.processingApproval);
      case 'multi_agent':
        return _assistantStatusForString(AgentStatusString.collaborating);
      case 'budget':
        final lowerTitle = event.title.toLowerCase();
        final isEn = _appSettings.language == AppLanguage.en;
        if (lowerTitle.contains('running')) {
          return isEn ? 'Auditing tool usage before continuing...' : '继续前正在审计工具调用...';
        }
        if (lowerTitle.contains('rejected')) {
          return isEn ? 'Tool usage stopped after safety audit...' : '安全审计后已停止继续调用工具...';
        }
        return isEn ? 'Tool budget extended. Please review tool use...' : '工具预算已扩展，请留意工具调用是否合理...';
      default:
        return _assistantStatusForString(AgentStatusString.preparing);
    }
  }

  String _traceToolName(String title) {
    final index = title.indexOf(':');
    if (index < 0 || index == title.length - 1) return title;
    return title.substring(index + 1).trim();
  }

  String _assistantRunningToolStatus(String toolName) {
    final name = toolName.trim();
    final isEn = _appSettings.language == AppLanguage.en;
    if (isEn) {
      return name.isEmpty ? 'Running tool...' : 'Running tool: $name';
    }
    return name.isEmpty ? '正在调用工具...' : '正在调用工具：$name';
  }

  String _assistantAwaitingApprovalStatus(String serverName) {
    final name = serverName.trim();
    final isEn = _appSettings.language == AppLanguage.en;
    if (isEn) {
      return name.isEmpty
          ? 'Waiting for tool approval...'
          : 'Waiting for tool approval on $name...';
    }
    return name.isEmpty ? '等待确认工具操作...' : '等待确认 $name 上的工具操作...';
  }

  String _assistantFailedString(Object e) {
    final isEn = _appSettings.language == AppLanguage.en;
    return isEn ? 'Request failed: $e' : '请求失败: $e';
  }
}

enum AgentStatusString {
  preparing,
  thinking,
  responding,
  processingToolResult,
  processingApproval,
  collaborating,
  stopped,
}
