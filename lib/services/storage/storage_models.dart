part of '../storage_service.dart';

List<AiChatRecord> upsertAiChatRecordsByUpdatedAt(
  Iterable<AiChatRecord> chats,
  AiChatRecord chat, {
  int? limit,
}) {
  final ordered = <AiChatRecord>[];
  var inserted = false;
  for (final item in chats) {
    if (item.id == chat.id) {
      continue;
    }
    if (!inserted && !chat.updatedAt.isBefore(item.updatedAt)) {
      ordered.add(chat);
      inserted = true;
    }
    ordered.add(item);
  }
  if (!inserted) {
    ordered.add(chat);
  }
  if (limit != null && ordered.length > limit) {
    ordered.removeRange(limit, ordered.length);
  }
  return ordered;
}

List<AiSkillRecord> upsertAiSkillRecordsByUpdatedAt(
  Iterable<AiSkillRecord> skills,
  AiSkillRecord skill,
) {
  final ordered = <AiSkillRecord>[];
  var inserted = false;
  for (final item in skills) {
    if (item.id == skill.id) {
      continue;
    }
    if (!inserted && !skill.updatedAt.isBefore(item.updatedAt)) {
      ordered.add(skill);
      inserted = true;
    }
    ordered.add(item);
  }
  if (!inserted) {
    ordered.add(skill);
  }
  return ordered;
}

List<Playbook> upsertPlaybooksByUpdatedAt(
  Iterable<Playbook> playbooks,
  Playbook playbook,
) {
  final ordered = <Playbook>[];
  var inserted = false;
  for (final item in playbooks) {
    if (item.id == playbook.id) {
      continue;
    }
    if (!inserted && !playbook.updatedAt.isBefore(item.updatedAt)) {
      ordered.add(playbook);
      inserted = true;
    }
    ordered.add(item);
  }
  if (!inserted) {
    ordered.add(playbook);
  }
  return ordered;
}

class AiConnectionSettings {
  final String baseUrl;
  final String model;
  final String helperModel;
  final String auditModel;
  final String modelFallbackPolicy;
  final int contextWindowTokens;
  final int timeoutSeconds;
  final bool deepSeekThinkingEnabled;
  final String deepSeekReasoningEffort;
  final String openAiReasoningEffort;
  final bool webSearchEnabled;
  final int webSearchMaxResults;
  final String webSearchEngine;
  final String quarkSearchEndpoint;
  final bool hasQuarkApiKey;
  final bool multiAgentEnabled;
  final int multiAgentMaxAgents;
  final int toolCallBudget;
  final int maxImageSizeBytes;
  final int maxFileSizeBytes;
  final bool hasApiKey;
  final String? activeApiKeyId;
  final String? activeApiKeyMasked;
  final bool useCustomPrompts;
  final String customSystemPrompt;
  final String customPlannerPrompt;
  final String customOperatorPrompt;
  final String customExplorePrompt;
  final String customReviewerPrompt;
  final String customSummarizerPrompt;
  final String customCoordinatorPrompt;

  const AiConnectionSettings({
    required this.baseUrl,
    required this.model,
    this.helperModel = '',
    this.auditModel = '',
    this.modelFallbackPolicy = AgentModelFallbackPolicy.defaultValue,
    required this.contextWindowTokens,
    required this.timeoutSeconds,
    required this.deepSeekThinkingEnabled,
    required this.deepSeekReasoningEffort,
    required this.openAiReasoningEffort,
    required this.webSearchEnabled,
    required this.webSearchMaxResults,
    required this.webSearchEngine,
    required this.quarkSearchEndpoint,
    required this.hasQuarkApiKey,
    required this.multiAgentEnabled,
    required this.multiAgentMaxAgents,
    required this.toolCallBudget,
    required this.maxImageSizeBytes,
    required this.maxFileSizeBytes,
    required this.hasApiKey,
    required this.activeApiKeyId,
    required this.activeApiKeyMasked,
    required this.useCustomPrompts,
    required this.customSystemPrompt,
    required this.customPlannerPrompt,
    required this.customOperatorPrompt,
    required this.customExplorePrompt,
    required this.customReviewerPrompt,
    required this.customSummarizerPrompt,
    required this.customCoordinatorPrompt,
  });

  AgentModelProfile get agentModelProfile => AgentModelProfile(
        mainModel: model,
        helperModel: helperModel,
        auditModel: auditModel,
        fallbackPolicy: modelFallbackPolicy,
      );
}

class AiApiKeyHistoryEntry {
  final String id;
  final String maskedValue;
  final bool isSelected;

  const AiApiKeyHistoryEntry({
    required this.id,
    required this.maskedValue,
    required this.isSelected,
  });
}

class AiWebSearchMaxResults {
  static const int defaultValue = 5;
  static const List<int> values = [3, 5, 8, 10];

  static int normalize(int? value) {
    if (value == null) return defaultValue;
    return value.clamp(values.first, values.last).toInt();
  }
}

class AiWebSearchEngine {
  static const String google = 'google';
  static const String bing = 'bing';
  static const String baidu = 'baidu';
  static const String duckDuckGo = 'duckduckgo';
  static const String quark = 'quark';

  static const String defaultValue = duckDuckGo;

  static const List<String> values = [google, bing, baidu, duckDuckGo, quark];

  static String normalize(String? value) {
    if (value == null) return defaultValue;
    final normalized = value.trim().toLowerCase();
    if (values.contains(normalized)) return normalized;
    return defaultValue;
  }
}

class AiUploadSizeLimit {
  static const int _mb = 1024 * 1024;
  static const int defaultImageSizeBytes = 50 * _mb;
  static const int defaultFileSizeBytes = 50 * _mb;
  static const List<int> imageValues = [
    1 * _mb,
    2 * _mb,
    5 * _mb,
    10 * _mb,
    20 * _mb,
    50 * _mb,
  ];
  static const List<int> fileValues = [
    1 * _mb,
    5 * _mb,
    10 * _mb,
    20 * _mb,
    50 * _mb,
  ];

  static int normalizeImage(int? value) {
    if (value == null) return defaultImageSizeBytes;
    return value.clamp(imageValues.first, imageValues.last);
  }

  static int normalizeFile(int? value) {
    if (value == null) return defaultFileSizeBytes;
    return value.clamp(fileValues.first, fileValues.last);
  }

  static String label(int bytes) {
    if (bytes >= _mb) {
      final mb = bytes ~/ _mb;
      return '$mb MB';
    }
    return '${bytes ~/ 1024} KB';
  }
}

class AiToolCallBudget {
  static const int defaultValue = 20;
  static const List<int> values = [10, 20, 30, 40, 60];

  static int normalize(int? value) {
    return values.contains(value) ? value! : defaultValue;
  }

  static String label(int value) {
    return '${normalize(value)}';
  }
}

class AiChatAttachment {
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final String dataBase64;

  const AiChatAttachment({
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.dataBase64,
  });

  bool get isImage => mimeType.startsWith('image/');

  bool get isTextFile {
    if (mimeType.startsWith('text/')) return true;
    const textExtensions = [
      '.json',
      '.xml',
      '.yaml',
      '.yml',
      '.md',
      '.csv',
      '.log',
      '.sh',
      '.py',
      '.js',
      '.dart',
      '.ts',
      '.html',
      '.css',
      '.sql',
      '.ini',
      '.conf',
      '.cfg',
      '.toml',
      '.env',
      '.bat',
      '.ps1',
      '.rb',
      '.go',
      '.rs',
      '.c',
      '.cpp',
      '.h',
      '.java',
      '.kt',
      '.swift',
      '.r',
      '.m',
      '.php',
      '.pl',
    ];
    final lower = fileName.toLowerCase();
    return textExtensions.any((ext) => lower.endsWith(ext));
  }

  Map<String, dynamic> toJson() {
    return {
      'fileName': fileName,
      'mimeType': mimeType,
      'sizeBytes': sizeBytes,
      'dataBase64': dataBase64,
    };
  }

  factory AiChatAttachment.fromJson(Map<String, dynamic> json) {
    return AiChatAttachment(
      fileName: json['fileName'] as String? ?? '',
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
      sizeBytes: json['sizeBytes'] as int? ?? 0,
      dataBase64: json['dataBase64'] as String? ?? '',
    );
  }
}

class DeepSeekReasoningEffort {
  static const String high = 'high';
  static const String max = 'max';
  static const String defaultEffort = high;
  static const List<String> values = [high, max];

  static String normalize(String? value) {
    final normalized = value?.trim().toLowerCase();
    return values.contains(normalized) ? normalized! : defaultEffort;
  }

  static String label(String value) {
    return normalize(value) == max ? 'Max' : 'High';
  }
}

class OpenAiReasoningEffort {
  static const String low = 'low';
  static const String medium = 'medium';
  static const String high = 'high';
  static const String xhigh = 'xhigh';
  static const String defaultEffort = medium;
  static const List<String> values = [low, medium, high, xhigh];

  static String normalize(String? value) {
    final normalized = value?.trim().toLowerCase();
    return values.contains(normalized) ? normalized! : defaultEffort;
  }

  static String label(String value) {
    switch (normalize(value)) {
      case low:
        return 'Low';
      case high:
        return 'High';
      case xhigh:
        return 'Extra high';
      case medium:
      default:
        return 'Medium';
    }
  }
}

bool isDeepSeekModelId(String model) {
  return model.trim().toLowerCase().contains('deepseek');
}

bool supportsOpenAiReasoningEffort(String model) {
  final normalized = model.trim().toLowerCase();
  return normalized.startsWith('gpt-5') ||
      normalized.startsWith('o1') ||
      normalized.startsWith('o3') ||
      normalized.startsWith('o4');
}

String maskAiApiKey(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';
  if (trimmed.length <= 4) return trimmed;
  if (trimmed.length <= 6) {
    final prefix = trimmed.substring(0, 4);
    final suffix = trimmed.substring(trimmed.length - 2);
    final hiddenCount = trimmed.length - prefix.length - suffix.length;
    return '$prefix${'*' * hiddenCount}$suffix';
  }
  final prefix = trimmed.substring(0, 4);
  final suffix = trimmed.substring(trimmed.length - 2);
  return '$prefix${'*' * (trimmed.length - 6)}$suffix';
}

class _MemorySecret {
  final String? value;
  final DateTime loadedAt;

  const _MemorySecret({
    required this.value,
    required this.loadedAt,
  });
}

class AiRequestTimeout {
  static const int k30 = 30;
  static const int k60 = 60;
  static const int k90 = 90;
  static const int k120 = 120;
  static const int k180 = 180;
  static const int k300 = 300;
  static const int defaultSeconds = k60;
  static const List<int> values = [k30, k60, k90, k120, k180, k300];

  static int normalize(int? value) {
    return values.contains(value) ? value! : defaultSeconds;
  }

  static String label(int value) {
    return '${normalize(value)}s';
  }
}

class AiContextWindowSize {
  static const int k259 = 259000;
  static const int k512 = 512000;
  static const int k1m = 1000000;
  static const List<int> values = [k259, k512, k1m];

  static int normalize(int? value) {
    if (value == k512 || value == k1m) return value!;
    return k259;
  }

  static String label(int value) {
    switch (normalize(value)) {
      case k512:
        return '512K';
      case k1m:
        return '1M';
      default:
        return '259K';
    }
  }
}

class SkillReferenceItem {
  final String title;
  final String content;

  const SkillReferenceItem({
    required this.title,
    required this.content,
  });

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'content': content,
    };
  }

  factory SkillReferenceItem.fromJson(Map<String, dynamic> json) {
    return SkillReferenceItem(
      title: json['title'] as String? ?? '',
      content: json['content'] as String? ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SkillReferenceItem &&
          runtimeType == other.runtimeType &&
          title == other.title &&
          content == other.content;

  @override
  int get hashCode => title.hashCode ^ content.hashCode;
}

class AiSkillRecord {
  final String id;
  final String name;
  final String description;
  final String content;
  final bool enabled;
  final List<SkillReferenceItem> references;
  final DateTime createdAt;
  final DateTime updatedAt;

  const AiSkillRecord({
    required this.id,
    required this.name,
    required this.description,
    required this.content,
    this.enabled = true,
    this.references = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  AiSkillRecord copyWith({
    String? name,
    String? description,
    String? content,
    bool? enabled,
    List<SkillReferenceItem>? references,
    DateTime? updatedAt,
  }) {
    return AiSkillRecord(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      content: content ?? this.content,
      enabled: enabled ?? this.enabled,
      references: references ?? this.references,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'content': content,
      'enabled': enabled,
      'references': references.map((item) => item.toJson()).toList(),
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory AiSkillRecord.fromJson(Map<String, dynamic> json) {
    return AiSkillRecord(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Skill',
      description: json['description'] as String? ?? '',
      content: json['content'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
      references: ((json['references'] as List<dynamic>?) ?? const [])
          .map((item) => SkillReferenceItem.fromJson(item as Map<String, dynamic>))
          .toList(),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class AgentRunMetrics {
  final String id;
  final DateTime startedAt;
  final DateTime finishedAt;
  final String model;
  final String helperModel;
  final String auditModel;
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final int elapsedMs;
  final int toolCalls;
  final int cacheHits;
  final int dedupBlockedCalls;
  final int ragHits;
  final int approvalCount;
  final int approvedCount;
  final int auditCount;
  final int helperFanout;
  final bool success;
  final List<String> selectedToolSet;
  final List<String> memorySources;

  const AgentRunMetrics({
    required this.id,
    required this.startedAt,
    required this.finishedAt,
    required this.model,
    this.helperModel = '',
    this.auditModel = '',
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    required this.elapsedMs,
    this.toolCalls = 0,
    this.cacheHits = 0,
    this.dedupBlockedCalls = 0,
    this.ragHits = 0,
    this.approvalCount = 0,
    this.approvedCount = 0,
    this.auditCount = 0,
    this.helperFanout = 0,
    this.success = true,
    this.selectedToolSet = const [],
    this.memorySources = const [],
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'startedAt': startedAt.toIso8601String(),
      'finishedAt': finishedAt.toIso8601String(),
      'model': model,
      if (helperModel.trim().isNotEmpty) 'helperModel': helperModel,
      if (auditModel.trim().isNotEmpty) 'auditModel': auditModel,
      'promptTokens': promptTokens,
      'completionTokens': completionTokens,
      'totalTokens': totalTokens,
      'elapsedMs': elapsedMs,
      'toolCalls': toolCalls,
      'cacheHits': cacheHits,
      'dedupBlockedCalls': dedupBlockedCalls,
      'ragHits': ragHits,
      'approvalCount': approvalCount,
      'approvedCount': approvedCount,
      'auditCount': auditCount,
      'helperFanout': helperFanout,
      'success': success,
      if (selectedToolSet.isNotEmpty) 'selectedToolSet': selectedToolSet,
      if (memorySources.isNotEmpty) 'memorySources': memorySources,
    };
  }

  factory AgentRunMetrics.fromJson(Map<String, dynamic> json) {
    return AgentRunMetrics(
      id: json['id'] as String? ?? _traceUuid.v4(),
      startedAt: DateTime.tryParse(json['startedAt'] as String? ?? '') ??
          DateTime.now(),
      finishedAt: DateTime.tryParse(json['finishedAt'] as String? ?? '') ??
          DateTime.now(),
      model: json['model'] as String? ?? '',
      helperModel: json['helperModel'] as String? ?? '',
      auditModel: json['auditModel'] as String? ?? '',
      promptTokens: json['promptTokens'] as int? ?? 0,
      completionTokens: json['completionTokens'] as int? ?? 0,
      totalTokens: json['totalTokens'] as int? ?? 0,
      elapsedMs: json['elapsedMs'] as int? ?? 0,
      toolCalls: json['toolCalls'] as int? ?? 0,
      cacheHits: json['cacheHits'] as int? ?? 0,
      dedupBlockedCalls: json['dedupBlockedCalls'] as int? ?? 0,
      ragHits: json['ragHits'] as int? ?? 0,
      approvalCount: json['approvalCount'] as int? ?? 0,
      approvedCount: json['approvedCount'] as int? ?? 0,
      auditCount: json['auditCount'] as int? ?? 0,
      helperFanout: json['helperFanout'] as int? ?? 0,
      success: json['success'] as bool? ?? true,
      selectedToolSet:
          ((json['selectedToolSet'] as List<dynamic>?) ?? const <dynamic>[])
              .map((item) => '$item')
              .toList(growable: false),
      memorySources:
          ((json['memorySources'] as List<dynamic>?) ?? const <dynamic>[])
              .map((item) => '$item')
              .toList(growable: false),
    );
  }
}

class AiApprovedPlanRef {
  final DateTime assistantCreatedAt;
  final DateTime approvedAt;

  const AiApprovedPlanRef({
    required this.assistantCreatedAt,
    required this.approvedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'assistantCreatedAt': assistantCreatedAt.toIso8601String(),
      'approvedAt': approvedAt.toIso8601String(),
    };
  }

  factory AiApprovedPlanRef.fromJson(Map<String, dynamic> json) {
    return AiApprovedPlanRef(
      assistantCreatedAt:
          DateTime.tryParse(json['assistantCreatedAt'] as String? ?? '') ??
              DateTime.now(),
      approvedAt: DateTime.tryParse(json['approvedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class AiChatRecord {
  final String id;
  final String title;
  final String model;
  final List<AiChatMessageRecord> messages;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool planMode;
  final AiApprovedPlanRef? approvedPlan;

  const AiChatRecord({
    required this.id,
    required this.title,
    required this.model,
    required this.messages,
    required this.createdAt,
    required this.updatedAt,
    this.planMode = false,
    this.approvedPlan,
  });

  AiChatRecord copyWith({
    String? title,
    String? model,
    List<AiChatMessageRecord>? messages,
    DateTime? updatedAt,
    bool? planMode,
    AiApprovedPlanRef? approvedPlan,
    bool clearApprovedPlan = false,
  }) {
    return AiChatRecord(
      id: id,
      title: title ?? this.title,
      model: model ?? this.model,
      messages: messages ?? this.messages,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      planMode: planMode ?? this.planMode,
      approvedPlan:
          clearApprovedPlan ? null : approvedPlan ?? this.approvedPlan,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'model': model,
      'messages': messages.map((item) => item.toJson()).toList(),
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'planMode': planMode,
      if (approvedPlan != null) 'approvedPlan': approvedPlan!.toJson(),
    };
  }

  factory AiChatRecord.fromJson(Map<String, dynamic> json) {
    return AiChatRecord(
      id: json['id'] as String,
      title: json['title'] as String? ?? 'New chat',
      model: json['model'] as String? ?? 'deepseek-v4-flash',
      messages: ((json['messages'] as List<dynamic>?) ?? const [])
          .map((item) =>
              AiChatMessageRecord.fromJson(item as Map<String, dynamic>))
          .toList(),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      planMode: json['planMode'] as bool? ?? false,
      approvedPlan: json['approvedPlan'] is Map<String, dynamic>
          ? AiApprovedPlanRef.fromJson(
              json['approvedPlan'] as Map<String, dynamic>,
            )
          : null,
    );
  }
}

AiChatMessageRecord? chatAssistantMessageByCreatedAt(
  AiChatRecord chat,
  DateTime assistantCreatedAt,
) {
  for (final message in chat.messages.reversed) {
    if (message.role == 'assistant' &&
        message.createdAt == assistantCreatedAt) {
      return message;
    }
  }
  return null;
}

AiChatMessageRecord? latestAssistantMessageForChat(AiChatRecord chat) {
  for (final message in chat.messages.reversed) {
    if (message.role == 'assistant') {
      return message;
    }
  }
  return null;
}

enum PlanModeExitActor {
  userUi,
  llmTool,
}

AiChatMessageRecord? approvedPlanMessageForChat(AiChatRecord chat) {
  final approvedPlan = chat.approvedPlan;
  if (approvedPlan == null) return null;
  return chatAssistantMessageByCreatedAt(chat, approvedPlan.assistantCreatedAt);
}

bool canExitPlanMode(
  AiChatRecord chat, {
  PlanModeExitActor actor = PlanModeExitActor.llmTool,
}) {
  if (actor == PlanModeExitActor.userUi) {
    return true;
  }
  final latestAssistant = latestAssistantMessageForChat(chat);
  return latestAssistant != null && latestAssistant.todoSteps.isNotEmpty;
}

String buildStableTodoStepId(DateTime assistantCreatedAt, int index) {
  return 'task-${assistantCreatedAt.microsecondsSinceEpoch}-$index';
}

class AiChatMessageRecord {
  final String role;
  final String text;
  final String? contextText;
  final List<AiMessageTrace> traces;
  final DateTime createdAt;
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
  final int? elapsedMs;
  final bool? tokenUsageEstimated;
  final int? promptCacheHitTokens;
  final int? promptCacheMissTokens;
  final List<AiChatAttachment> attachments;
  final int? reasoningTokens;
  final List<AiTodoStep> todoSteps;

  const AiChatMessageRecord({
    required this.role,
    required this.text,
    this.contextText,
    this.attachments = const [],
    this.traces = const [],
    required this.createdAt,
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.elapsedMs,
    this.tokenUsageEstimated,
    this.promptCacheHitTokens,
    this.promptCacheMissTokens,
    this.reasoningTokens,
    this.todoSteps = const [],
  });

  AiChatMessageRecord copyWith({
    String? role,
    String? text,
    String? contextText,
    List<AiChatAttachment>? attachments,
    List<AiMessageTrace>? traces,
    DateTime? createdAt,
    int? promptTokens,
    int? completionTokens,
    int? totalTokens,
    int? elapsedMs,
    bool? tokenUsageEstimated,
    int? promptCacheHitTokens,
    int? promptCacheMissTokens,
    int? reasoningTokens,
    List<AiTodoStep>? todoSteps,
  }) {
    return AiChatMessageRecord(
      role: role ?? this.role,
      text: text ?? this.text,
      contextText: contextText ?? this.contextText,
      attachments: attachments ?? this.attachments,
      traces: traces ?? this.traces,
      createdAt: createdAt ?? this.createdAt,
      promptTokens: promptTokens ?? this.promptTokens,
      completionTokens: completionTokens ?? this.completionTokens,
      totalTokens: totalTokens ?? this.totalTokens,
      elapsedMs: elapsedMs ?? this.elapsedMs,
      tokenUsageEstimated: tokenUsageEstimated ?? this.tokenUsageEstimated,
      promptCacheHitTokens: promptCacheHitTokens ?? this.promptCacheHitTokens,
      promptCacheMissTokens:
          promptCacheMissTokens ?? this.promptCacheMissTokens,
      reasoningTokens: reasoningTokens ?? this.reasoningTokens,
      todoSteps: todoSteps ?? this.todoSteps,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'role': role,
      'text': text,
      if (contextText != null) 'contextText': contextText,
      if (attachments.isNotEmpty)
        'attachments': attachments.map((a) => a.toJson()).toList(),
      if (traces.isNotEmpty)
        'traces': traces.map((trace) => trace.toJson()).toList(),
      'createdAt': createdAt.toIso8601String(),
      if (promptTokens != null) 'promptTokens': promptTokens,
      if (completionTokens != null) 'completionTokens': completionTokens,
      if (totalTokens != null) 'totalTokens': totalTokens,
      if (elapsedMs != null) 'elapsedMs': elapsedMs,
      if (tokenUsageEstimated != null)
        'tokenUsageEstimated': tokenUsageEstimated,
      if (promptCacheHitTokens != null)
        'promptCacheHitTokens': promptCacheHitTokens,
      if (promptCacheMissTokens != null)
        'promptCacheMissTokens': promptCacheMissTokens,
      if (reasoningTokens != null) 'reasoningTokens': reasoningTokens,
      if (todoSteps.isNotEmpty)
        'todoSteps': todoSteps.map((s) => s.toJson()).toList(),
    };
  }

  factory AiChatMessageRecord.fromJson(Map<String, dynamic> json) {
    return AiChatMessageRecord(
      role: json['role'] as String? ?? 'assistant',
      text: json['text'] as String? ?? '',
      contextText: json['contextText'] as String?,
      attachments: ((json['attachments'] as List<dynamic>?) ?? const [])
          .map(
              (item) => AiChatAttachment.fromJson(item as Map<String, dynamic>))
          .toList(),
      traces: ((json['traces'] as List<dynamic>?) ?? const [])
          .map((item) => AiMessageTrace.fromJson(item as Map<String, dynamic>))
          .toList(),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      promptTokens: json['promptTokens'] as int?,
      completionTokens: json['completionTokens'] as int?,
      totalTokens: json['totalTokens'] as int?,
      elapsedMs: json['elapsedMs'] as int?,
      tokenUsageEstimated: json['tokenUsageEstimated'] as bool?,
      promptCacheHitTokens: json['promptCacheHitTokens'] as int?,
      promptCacheMissTokens: json['promptCacheMissTokens'] as int?,
      reasoningTokens: json['reasoningTokens'] as int?,
      todoSteps: ((json['todoSteps'] as List<dynamic>?) ?? const [])
          .map((item) => AiTodoStep.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }
}

class AiMessageTrace {
  final String id;
  final String kind;
  final String title;
  final String content;
  final DateTime createdAt;

  const AiMessageTrace({
    required this.id,
    required this.kind,
    required this.title,
    required this.content,
    required this.createdAt,
  });

  factory AiMessageTrace.create({
    required String kind,
    required String title,
    required String content,
    DateTime? createdAt,
  }) {
    return AiMessageTrace(
      id: _traceUuid.v4(),
      kind: kind,
      title: title,
      content: content,
      createdAt: createdAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'kind': kind,
      'title': title,
      'content': content,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory AiMessageTrace.fromJson(Map<String, dynamic> json) {
    final rawId = (json['id'] as String?)?.trim();
    return AiMessageTrace(
      id: rawId?.isNotEmpty == true ? rawId! : _traceUuid.v4(),
      kind: json['kind'] as String? ?? 'info',
      title: json['title'] as String? ?? 'Details',
      content: json['content'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class RestorableTmuxSession {
  final String sessionId;
  final String connectionId;
  final String displayName;
  final String tmuxSessionName;
  final double fontSize;
  final DateTime updatedAt;

  const RestorableTmuxSession({
    required this.sessionId,
    required this.connectionId,
    required this.displayName,
    required this.tmuxSessionName,
    required this.fontSize,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'sessionId': sessionId,
      'connectionId': connectionId,
      'displayName': displayName,
      'tmuxSessionName': tmuxSessionName,
      'fontSize': fontSize,
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory RestorableTmuxSession.fromJson(Map<String, dynamic> json) {
    return RestorableTmuxSession(
      sessionId: json['sessionId'] as String,
      connectionId: json['connectionId'] as String,
      displayName: json['displayName'] as String? ?? 'SSH',
      tmuxSessionName: json['tmuxSessionName'] as String? ?? 'ssh_mobile',
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 14,
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class TerminalHistoryRecord {
  final String sessionId;
  final String connectionId;
  final String connectionName;
  final String displayName;
  final String? tmuxSessionName;
  final String state;
  final String? errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;

  const TerminalHistoryRecord({
    required this.sessionId,
    required this.connectionId,
    required this.connectionName,
    required this.displayName,
    required this.tmuxSessionName,
    required this.state,
    required this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
  });

  String? get tmuxKillCommand {
    final name = tmuxSessionName;
    if (name == null || name.isEmpty) return null;
    return "tmux kill-session -t ${_shellQuote(name)}";
  }

  Map<String, dynamic> toJson() {
    return {
      'sessionId': sessionId,
      'connectionId': connectionId,
      'connectionName': connectionName,
      'displayName': displayName,
      'tmuxSessionName': tmuxSessionName,
      'state': state,
      'errorMessage': errorMessage,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory TerminalHistoryRecord.fromJson(Map<String, dynamic> json) {
    return TerminalHistoryRecord(
      sessionId: json['sessionId'] as String,
      connectionId: json['connectionId'] as String? ?? '',
      connectionName: json['connectionName'] as String? ?? 'SSH',
      displayName: json['displayName'] as String? ?? 'SSH',
      tmuxSessionName: json['tmuxSessionName'] as String?,
      state: json['state'] as String? ?? 'disconnected',
      errorMessage: json['errorMessage'] as String?,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  static String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }
}

class AiTodoStep {
  final String id;
  final String name;
  final String command;
  final String description;
  final StepStatus status;
  final String? stdout;
  final String? stderr;
  final int? exitCode;
  final String? connectionId;

  const AiTodoStep({
    required this.id,
    required this.name,
    required this.command,
    required this.description,
    this.status = StepStatus.pending,
    this.stdout,
    this.stderr,
    this.exitCode,
    this.connectionId,
  });

  AiTodoStep copyWith({
    String? id,
    String? name,
    String? command,
    String? description,
    StepStatus? status,
    String? stdout,
    String? stderr,
    int? exitCode,
    String? connectionId,
  }) {
    return AiTodoStep(
      id: id ?? this.id,
      name: name ?? this.name,
      command: command ?? this.command,
      description: description ?? this.description,
      status: status ?? this.status,
      stdout: stdout ?? this.stdout,
      stderr: stderr ?? this.stderr,
      exitCode: exitCode ?? this.exitCode,
      connectionId: connectionId ?? this.connectionId,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'command': command,
      'description': description,
      'status': status.name,
      if (stdout != null) 'stdout': stdout,
      if (stderr != null) 'stderr': stderr,
      if (exitCode != null) 'exitCode': exitCode,
      if (connectionId != null) 'connectionId': connectionId,
    };
  }

  factory AiTodoStep.fromJson(Map<String, dynamic> json) {
    return AiTodoStep(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Step',
      command: json['command'] as String? ?? '',
      description: json['description'] as String? ?? '',
      status: StepStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => StepStatus.pending,
      ),
      stdout: json['stdout'] as String?,
      stderr: json['stderr'] as String?,
      exitCode: json['exitCode'] as int?,
      connectionId: json['connectionId'] as String?,
    );
  }
}
