import 'package:uuid/uuid.dart';

const int agentTraceContentMaxChars = 8192;
const int agentTraceEventsPerRunLimit = 300;
const int agentTraceRunRetentionLimit = 200;

const Uuid _agentTraceUuid = Uuid();

class AgentTraceEvent {
  final String id;
  final String runId;
  final String chatId;
  final DateTime createdAt;
  final int sequence;
  final String kind;
  final String title;
  final String content;
  final String? toolName;
  final String status;
  final int? durationMs;
  final String? parentEventId;
  final bool truncated;

  AgentTraceEvent({
    String? id,
    required this.runId,
    required this.chatId,
    required this.createdAt,
    required this.sequence,
    required this.kind,
    required this.title,
    required String content,
    this.toolName,
    String? status,
    this.durationMs,
    this.parentEventId,
    bool truncated = false,
  })  : id = id?.trim().isNotEmpty == true ? id!.trim() : _agentTraceUuid.v4(),
        status = status?.trim().isNotEmpty == true ? status!.trim() : 'info',
        content = _normalizeContent(content, truncated).$1,
        truncated = _normalizeContent(content, truncated).$2;

  AgentTraceEvent copyWith({
    String? id,
    String? runId,
    String? chatId,
    DateTime? createdAt,
    int? sequence,
    String? kind,
    String? title,
    String? content,
    String? toolName,
    String? status,
    int? durationMs,
    String? parentEventId,
    bool? truncated,
  }) {
    return AgentTraceEvent(
      id: id ?? this.id,
      runId: runId ?? this.runId,
      chatId: chatId ?? this.chatId,
      createdAt: createdAt ?? this.createdAt,
      sequence: sequence ?? this.sequence,
      kind: kind ?? this.kind,
      title: title ?? this.title,
      content: content ?? this.content,
      toolName: toolName ?? this.toolName,
      status: status ?? this.status,
      durationMs: durationMs ?? this.durationMs,
      parentEventId: parentEventId ?? this.parentEventId,
      truncated: truncated ?? this.truncated,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'runId': runId,
      'chatId': chatId,
      'createdAt': createdAt.toIso8601String(),
      'sequence': sequence,
      'kind': kind,
      'title': title,
      'content': content,
      if (toolName?.trim().isNotEmpty == true) 'toolName': toolName,
      'status': status,
      if (durationMs != null) 'durationMs': durationMs,
      if (parentEventId?.trim().isNotEmpty == true)
        'parentEventId': parentEventId,
      if (truncated) 'truncated': true,
    };
  }

  factory AgentTraceEvent.fromJson(Map<String, dynamic> json) {
    return AgentTraceEvent(
      id: json['id'] as String?,
      runId: json['runId'] as String? ?? '',
      chatId: json['chatId'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      sequence: json['sequence'] as int? ?? 0,
      kind: json['kind'] as String? ?? 'info',
      title: json['title'] as String? ?? 'Trace event',
      content: json['content'] as String? ?? '',
      toolName: json['toolName'] as String?,
      status: json['status'] as String? ?? 'info',
      durationMs: json['durationMs'] as int?,
      parentEventId: json['parentEventId'] as String?,
      truncated: json['truncated'] as bool? ?? false,
    );
  }

  static (String, bool) _normalizeContent(String value, bool alreadyTruncated) {
    if (value.length <= agentTraceContentMaxChars) {
      return (value, alreadyTruncated);
    }
    const marker = '\n\n[trace content truncated]';
    final keep = agentTraceContentMaxChars - marker.length;
    final end = keep.clamp(0, value.length).toInt();
    return ('${value.substring(0, end)}$marker', true);
  }
}
