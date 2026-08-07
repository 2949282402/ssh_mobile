part of '../storage_service.dart';

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

  const _MemorySecret({required this.value, required this.loadedAt});
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

  const SkillReferenceItem({required this.title, required this.content});

  Map<String, dynamic> toJson() {
    return {'title': title, 'content': content};
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

  String get displayName {
    if (name.isNotEmpty) return name;
    final fm = SkillFrontmatter.parse(content);
    return fm?.name.isNotEmpty == true ? fm!.name : 'Skill';
  }

  String get displayDescription {
    if (description.isNotEmpty) return description;
    final fm = SkillFrontmatter.parse(content);
    return fm?.description.isNotEmpty == true ? fm!.description : '';
  }

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
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      content: json['content'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
      references: ((json['references'] as List<dynamic>?) ?? const [])
          .map(
            (item) => SkillReferenceItem.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
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
      startedAt:
          DateTime.tryParse(json['startedAt'] as String? ?? '') ??
          DateTime.now(),
      finishedAt:
          DateTime.tryParse(json['finishedAt'] as String? ?? '') ??
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
