part of '../llm_chat_service.dart';

/// 可取消令牌：调用 cancel() 后，所有 isCancelled/throwIfCancelled 点立即响应。
/// onCancel 用于释放资源（关闭 HttpClient 连接）。
class LlmCancellationToken {
  final List<void Function()> _callbacks = [];
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final callbacks = List<void Function()>.of(_callbacks);
    _callbacks.clear();
    for (final callback in callbacks) {
      callback();
    }
  }

  void onCancel(void Function() callback) {
    if (_cancelled) {
      callback();
      return;
    }
    _callbacks.add(callback);
  }

  void throwIfCancelled() {
    if (_cancelled) throw const LlmCancelledException();
  }
}

class LlmCancelledException implements Exception {
  const LlmCancelledException();

  @override
  String toString() => 'LLM request cancelled.';
}

class _StreamChatResult {
  final List<String> contentChunks;
  final String reasoningContent;
  final List<_StreamingToolCall> toolCalls;
  final LlmTokenUsage? usage;

  const _StreamChatResult({
    required this.contentChunks,
    required this.reasoningContent,
    required this.toolCalls,
    required this.usage,
  });
}

class LlmRunStats {
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final int elapsedMs;
  final bool usageFromProvider;
  final int? promptCacheHitTokens;
  final int? promptCacheMissTokens;
  final int? reasoningTokens;
  final int contextTokensBeforeCompression;
  final int contextWindowTokens;
  final bool compressed;

  const LlmRunStats({
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    required this.elapsedMs,
    required this.usageFromProvider,
    this.promptCacheHitTokens,
    this.promptCacheMissTokens,
    this.reasoningTokens,
    required this.contextTokensBeforeCompression,
    required this.contextWindowTokens,
    required this.compressed,
  });
}

class LlmTraceEvent {
  final String kind;
  final String title;
  final String content;

  const LlmTraceEvent({
    required this.kind,
    required this.title,
    required this.content,
  });
}

class LlmTokenUsage {
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
  final int? promptCacheHitTokens;
  final int? promptCacheMissTokens;
  final int? reasoningTokens;

  const LlmTokenUsage({
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    required this.promptCacheHitTokens,
    required this.promptCacheMissTokens,
    required this.reasoningTokens,
  });

  factory LlmTokenUsage.fromJson(Map<String, dynamic> json) {
    int? readInt(String key) {
      final value = json[key];
      return value is int ? value : null;
    }

    return LlmTokenUsage(
      promptTokens: readInt('prompt_tokens'),
      completionTokens: readInt('completion_tokens'),
      totalTokens: readInt('total_tokens'),
      promptCacheHitTokens: readInt('prompt_cache_hit_tokens'),
      promptCacheMissTokens: readInt('prompt_cache_miss_tokens'),
      reasoningTokens: (json['completion_tokens_details']
          as Map?)?['reasoning_tokens'] as int?,
    );
  }
}

class _StreamingToolCall {
  String id;
  String name;
  String arguments;

  _StreamingToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });
}
