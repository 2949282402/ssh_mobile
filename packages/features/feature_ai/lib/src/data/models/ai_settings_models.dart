import 'package:feature_playbook/feature_playbook.dart';

import '../../domain/ai_models.dart';
import '../../agent/agent_model_profile.dart';
import '../../llm/provider/llm_api_format.dart';

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
  final bool postToolReviewEnabled;
  final int toolCallBudget;
  final String agentLoopMode;
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
  final LlmApiFormat apiFormat;

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
    required this.postToolReviewEnabled,
    required this.toolCallBudget,
    this.agentLoopMode = AiAgentLoopMode.defaultValue,
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
    this.apiFormat = LlmApiFormat.openAiChatCompletions,
  });

  AgentModelProfile get agentModelProfile => AgentModelProfile(
    mainModel: model,
    helperModel: helperModel,
    auditModel: auditModel,
    fallbackPolicy: modelFallbackPolicy,
  );

  AiConnectionSettings copyWith({
    String? baseUrl,
    String? model,
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
    String? quarkSearchEndpoint,
    bool? hasQuarkApiKey,
    bool? multiAgentEnabled,
    int? multiAgentMaxAgents,
    bool? postToolReviewEnabled,
    int? toolCallBudget,
    String? agentLoopMode,
    int? maxImageSizeBytes,
    int? maxFileSizeBytes,
    bool? hasApiKey,
    String? activeApiKeyId,
    String? activeApiKeyMasked,
    bool? useCustomPrompts,
    String? customSystemPrompt,
    String? customPlannerPrompt,
    String? customOperatorPrompt,
    String? customExplorePrompt,
    String? customReviewerPrompt,
    String? customSummarizerPrompt,
    String? customCoordinatorPrompt,
    LlmApiFormat? apiFormat,
  }) {
    return AiConnectionSettings(
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      helperModel: helperModel ?? this.helperModel,
      auditModel: auditModel ?? this.auditModel,
      modelFallbackPolicy: modelFallbackPolicy ?? this.modelFallbackPolicy,
      contextWindowTokens: contextWindowTokens ?? this.contextWindowTokens,
      timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
      deepSeekThinkingEnabled:
          deepSeekThinkingEnabled ?? this.deepSeekThinkingEnabled,
      deepSeekReasoningEffort:
          deepSeekReasoningEffort ?? this.deepSeekReasoningEffort,
      openAiReasoningEffort:
          openAiReasoningEffort ?? this.openAiReasoningEffort,
      webSearchEnabled: webSearchEnabled ?? this.webSearchEnabled,
      webSearchMaxResults: webSearchMaxResults ?? this.webSearchMaxResults,
      webSearchEngine: webSearchEngine ?? this.webSearchEngine,
      quarkSearchEndpoint: quarkSearchEndpoint ?? this.quarkSearchEndpoint,
      hasQuarkApiKey: hasQuarkApiKey ?? this.hasQuarkApiKey,
      multiAgentEnabled: multiAgentEnabled ?? this.multiAgentEnabled,
      multiAgentMaxAgents: multiAgentMaxAgents ?? this.multiAgentMaxAgents,
      postToolReviewEnabled:
          postToolReviewEnabled ?? this.postToolReviewEnabled,
      toolCallBudget: toolCallBudget ?? this.toolCallBudget,
      agentLoopMode: AiAgentLoopMode.normalize(
        agentLoopMode ?? this.agentLoopMode,
      ),
      maxImageSizeBytes: maxImageSizeBytes ?? this.maxImageSizeBytes,
      maxFileSizeBytes: maxFileSizeBytes ?? this.maxFileSizeBytes,
      hasApiKey: hasApiKey ?? this.hasApiKey,
      activeApiKeyId: activeApiKeyId ?? this.activeApiKeyId,
      activeApiKeyMasked: activeApiKeyMasked ?? this.activeApiKeyMasked,
      useCustomPrompts: useCustomPrompts ?? this.useCustomPrompts,
      customSystemPrompt: customSystemPrompt ?? this.customSystemPrompt,
      customPlannerPrompt: customPlannerPrompt ?? this.customPlannerPrompt,
      customOperatorPrompt: customOperatorPrompt ?? this.customOperatorPrompt,
      customExplorePrompt: customExplorePrompt ?? this.customExplorePrompt,
      customReviewerPrompt: customReviewerPrompt ?? this.customReviewerPrompt,
      customSummarizerPrompt:
          customSummarizerPrompt ?? this.customSummarizerPrompt,
      customCoordinatorPrompt:
          customCoordinatorPrompt ?? this.customCoordinatorPrompt,
      apiFormat: apiFormat ?? this.apiFormat,
    );
  }
}

/// Ephemeral, non-serializable runtime pairing of provider settings and secret.
/// Keep this object in memory only and never include its keys in logs or traces.
class AiRuntimeConnectionSnapshot {
  final AiConnectionSettings settings;
  final String apiKey;
  final String quarkApiKey;
  final String aliyunApiKey;

  const AiRuntimeConnectionSnapshot({
    required this.settings,
    required this.apiKey,
    this.quarkApiKey = '',
    this.aliyunApiKey = '',
  });

  bool get hasApiKey => apiKey.isNotEmpty;
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

  static const String defaultValue = baidu;

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

class AiAgentLoopMode {
  static const String balanced = 'balanced';
  static const String deep = 'deep';
  static const String unlimited = 'unlimited';
  static const String defaultValue = balanced;
  static const List<String> values = [balanced, deep, unlimited];

  static String normalize(String? value) {
    final normalized = value?.trim().toLowerCase();
    return values.contains(normalized) ? normalized! : defaultValue;
  }

  static int? initialRoundLimit(String? value) {
    switch (normalize(value)) {
      case deep:
        return 24;
      case unlimited:
        return null;
      case balanced:
      default:
        return 16;
    }
  }

  static int extensionSize(String? value) {
    switch (normalize(value)) {
      case deep:
        return 12;
      case unlimited:
        return 0;
      case balanced:
      default:
        return 8;
    }
  }

  static String label(String value, {bool english = false}) {
    switch (normalize(value)) {
      case deep:
        return english ? 'Deep' : '深度';
      case unlimited:
        return english ? 'Unlimited' : '无限制';
      case balanced:
      default:
        return english ? 'Balanced' : '均衡';
    }
  }
}
