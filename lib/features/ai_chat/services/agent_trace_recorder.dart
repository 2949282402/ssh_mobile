import 'dart:convert';

import 'llm_chat_service.dart';
import '../../../services/storage_service.dart';
import '../../../services/tool_secret_policy.dart';
import '../models/agent_trace_event.dart';

class AgentTraceRecorder {
  final AgentTraceRepository _repository;
  final String runId;
  final String chatId;
  final ToolSecretPolicy _secretPolicy;
  final List<AgentTraceEvent> _buffer = [];

  int _nextSequence = 0;

  AgentTraceRecorder({
    required AgentTraceRepository repository,
    required this.runId,
    required this.chatId,
    ToolSecretPolicy secretPolicy = const ToolSecretPolicy(),
  })  : _repository = repository,
        _secretPolicy = secretPolicy;

  List<AgentTraceEvent> get bufferedEvents => List.unmodifiable(_buffer);

  void record(LlmTraceEvent event) {
    final redactedContent = _redactContent(event.content);
    final status = _deriveStatus(event, redactedContent);
    _buffer.add(
      AgentTraceEvent(
        runId: runId,
        chatId: chatId,
        createdAt: DateTime.now(),
        sequence: _nextSequence++,
        kind: event.kind,
        title: _secretPolicy.redactText(event.title),
        content: redactedContent,
        toolName: _deriveToolName(event),
        status: status,
        durationMs: _deriveDurationMs(redactedContent),
      ),
    );
  }

  String _redactContent(String content) {
    try {
      return _secretPolicy.safeJson(
        jsonDecode(content),
        truncateLongStrings: true,
        maxChars: 1200,
      );
    } catch (_) {
      return _secretPolicy.previewText(
        content,
        maxChars: agentTraceContentMaxChars,
      );
    }
  }

  Future<void> flush() async {
    if (_buffer.isEmpty) return;
    final events = List<AgentTraceEvent>.from(_buffer, growable: false);
    await _repository.saveAgentTraceEvents(events);
    _buffer.clear();
  }

  void clear() {
    _buffer.clear();
    _nextSequence = 0;
  }

  String? _deriveToolName(LlmTraceEvent event) {
    final title = event.title;
    for (final prefix in [
      'Tool request: ',
      'Tool result: ',
      'Tool blocked: ',
      'Step-Tool Binding: ',
      'Step-Tool Outcome: ',
    ]) {
      if (title.startsWith(prefix)) {
        final value = title.substring(prefix.length).trim();
        final arrowIndex = value.indexOf(' -> ');
        final name = arrowIndex >= 0
            ? value.substring(arrowIndex + 4).trim()
            : value.split(' ').first.trim();
        return name.isEmpty ? null : _secretPolicy.redactText(name);
      }
    }
    final decoded = _tryDecodeMap(event.content);
    final tool = decoded?['tool'] ?? decoded?['toolName'];
    if (tool is String && tool.trim().isNotEmpty) {
      return _secretPolicy.redactText(tool.trim());
    }
    return null;
  }

  int? _deriveDurationMs(String content) {
    final decoded = _tryDecodeMap(content);
    final value = decoded?['durationMs'] ?? decoded?['elapsedMs'];
    return value is int ? value : null;
  }

  String _deriveStatus(LlmTraceEvent event, String content) {
    if (event.kind == 'agent_run_summary') {
      final decoded = _tryDecodeMap(content);
      final outcome = decoded?['finalOutcome'];
      if (outcome is String && outcome.trim().isNotEmpty) {
        return outcome.trim();
      }
      return 'completed';
    }
    final decoded = _tryDecodeMap(content);
    final decodedStatus = decoded?['status'] ?? decoded?['outcome'];
    if (decodedStatus is String && decodedStatus.trim().isNotEmpty) {
      return decodedStatus.trim();
    }
    final lower = '${event.kind} ${event.title} $content'.toLowerCase();
    if (lower.contains('approved')) return 'approved';
    if (lower.contains('rejected')) return 'rejected';
    if (lower.contains('blocked')) return 'blocked';
    if (lower.contains('unavailable')) return 'unavailable';
    if (lower.contains('error') || lower.contains('failed')) return 'error';
    if (lower.contains('requested') || lower.contains('request')) {
      return 'requested';
    }
    return 'info';
  }

  Map<String, dynamic>? _tryDecodeMap(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return {
          for (final entry in decoded.entries) '${entry.key}': entry.value,
        };
      }
    } catch (_) {
      return null;
    }
    return null;
  }
}
