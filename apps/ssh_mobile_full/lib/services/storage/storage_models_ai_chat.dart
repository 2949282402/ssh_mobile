part of '../storage_service.dart';

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
      approvedAt:
          DateTime.tryParse(json['approvedAt'] as String? ?? '') ??
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
      approvedPlan: clearApprovedPlan
          ? null
          : approvedPlan ?? this.approvedPlan,
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
          .map(
            (item) =>
                AiChatMessageRecord.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
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

enum PlanModeExitActor { userUi, llmTool }

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
  final String? agentRunId;

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
    this.agentRunId,
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
    String? agentRunId,
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
      agentRunId: agentRunId ?? this.agentRunId,
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
      if (agentRunId?.trim().isNotEmpty == true) 'agentRunId': agentRunId,
    };
  }

  factory AiChatMessageRecord.fromJson(Map<String, dynamic> json) {
    return AiChatMessageRecord(
      role: json['role'] as String? ?? 'assistant',
      text: json['text'] as String? ?? '',
      contextText: json['contextText'] as String?,
      attachments: ((json['attachments'] as List<dynamic>?) ?? const [])
          .map(
            (item) => AiChatAttachment.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
      traces: ((json['traces'] as List<dynamic>?) ?? const [])
          .map((item) => AiMessageTrace.fromJson(item as Map<String, dynamic>))
          .toList(),
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
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
      agentRunId: json['agentRunId'] as String?,
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
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
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
