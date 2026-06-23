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
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value);
      return null;
    }

    return LlmTokenUsage(
      promptTokens: readInt('prompt_tokens'),
      completionTokens: readInt('completion_tokens'),
      totalTokens: readInt('total_tokens'),
      promptCacheHitTokens: readInt('prompt_tokens_details') != null
          ? (json['prompt_tokens_details'] as Map)['cached_tokens'] as int?
          : readInt('prompt_cache_hit_tokens'),
      promptCacheMissTokens: readInt('prompt_cache_miss_tokens'),
      reasoningTokens: readInt('completion_tokens_details') != null
          ? (json['completion_tokens_details'] as Map)['reasoning_tokens'] as int?
          : readInt('reasoning_tokens'),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'prompt_tokens': promptTokens,
      'completion_tokens': completionTokens,
      'total_tokens': totalTokens,
      'prompt_cache_hit_tokens': promptCacheHitTokens,
      'prompt_cache_miss_tokens': promptCacheMissTokens,
      'reasoning_tokens': reasoningTokens,
    };
  }
}
