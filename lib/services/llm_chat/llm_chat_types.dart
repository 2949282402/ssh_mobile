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
  final List<StreamingToolCall> toolCalls;
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
  final int toolCalls;
  final int cacheHits;
  final int dedupBlockedCalls;
  final int helperFanout;
  final int auditEscalationLevel;
  final List<String> selectedToolSet;
  final List<String> memorySources;
  final int approvalCount;
  final int approvedCount;

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
    this.toolCalls = 0,
    this.cacheHits = 0,
    this.dedupBlockedCalls = 0,
    this.helperFanout = 0,
    this.auditEscalationLevel = 0,
    this.selectedToolSet = const [],
    this.memorySources = const [],
    this.approvalCount = 0,
    this.approvedCount = 0,
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

class LlmToolBudgetController {
  final int baseBudget;
  final int extensionSize;
  int _usedCalls;
  int _currentLimit;
  bool _initialExtensionGranted;
  int _auditCount;

  LlmToolBudgetController({
    required int baseBudget,
  })  : baseBudget = AiToolCallBudget.normalize(baseBudget),
        extensionSize = AiToolCallBudget.normalize(baseBudget) ~/ 2,
        _usedCalls = 0,
        _currentLimit = AiToolCallBudget.normalize(baseBudget),
        _initialExtensionGranted = false,
        _auditCount = 0;

  int get usedCalls => _usedCalls;
  int get currentLimit => _currentLimit;
  bool get initialExtensionGranted => _initialExtensionGranted;
  int get auditCount => _auditCount;

  void recordAuditTriggered() {
    _auditCount += 1;
  }

  bool get requiresAuditBeforeNextCall =>
      _initialExtensionGranted && _usedCalls >= _currentLimit;

  LlmToolBudgetCheck checkBeforeToolCall() {
    if (requiresAuditBeforeNextCall) {
      return const LlmToolBudgetCheck.auditRequired();
    }
    return const LlmToolBudgetCheck.allowed();
  }

  LlmToolBudgetEvent? recordAcceptedToolCall() {
    _usedCalls += 1;
    if (!_initialExtensionGranted && _usedCalls >= baseBudget) {
      _initialExtensionGranted = true;
      final previousLimit = _currentLimit;
      _currentLimit = baseBudget + extensionSize;
      return LlmToolBudgetEvent(
        type: 'auto_extend',
        usedCalls: _usedCalls,
        previousLimit: previousLimit,
        newLimit: _currentLimit,
      );
    }
    return null;
  }

  LlmToolBudgetEvent approveAuditExtension() {
    final previousLimit = _currentLimit;
    _currentLimit += extensionSize;
    return LlmToolBudgetEvent(
      type: 'audit_extend',
      usedCalls: _usedCalls,
      previousLimit: previousLimit,
      newLimit: _currentLimit,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'baseBudget': baseBudget,
      'extensionSize': extensionSize,
      'usedCalls': _usedCalls,
      'currentLimit': _currentLimit,
      'initialExtensionGranted': _initialExtensionGranted,
      'auditCount': _auditCount,
    };
  }
}

class LlmToolBudgetCheck {
  final bool allowToolCall;
  final bool requiresAudit;

  const LlmToolBudgetCheck._({
    required this.allowToolCall,
    required this.requiresAudit,
  });

  const LlmToolBudgetCheck.allowed()
      : this._(
          allowToolCall: true,
          requiresAudit: false,
        );

  const LlmToolBudgetCheck.auditRequired()
      : this._(
          allowToolCall: false,
          requiresAudit: true,
        );
}

class LlmToolBudgetEvent {
  final String type;
  final int usedCalls;
  final int previousLimit;
  final int newLimit;

  const LlmToolBudgetEvent({
    required this.type,
    required this.usedCalls,
    required this.previousLimit,
    required this.newLimit,
  });

  Map<String, dynamic> toJson() {
    return {
      'type': type,
      'usedCalls': usedCalls,
      'previousLimit': previousLimit,
      'newLimit': newLimit,
    };
  }
}

class LlmToolLedgerEntry {
  final int index;
  final String toolName;
  final String signature;
  final String argumentsPreview;
  final String outcome;
  final bool approvalRequired;
  final bool approved;
  final bool failed;
  final bool emptyResult;
  final String resultPreview;
  final bool cacheHit;
  final bool dedupBlocked;
  final int auditEscalationLevel;
  final String quality;

  const LlmToolLedgerEntry({
    required this.index,
    required this.toolName,
    required this.signature,
    required this.argumentsPreview,
    required this.outcome,
    required this.approvalRequired,
    required this.approved,
    required this.failed,
    required this.emptyResult,
    required this.resultPreview,
    this.cacheHit = false,
    this.dedupBlocked = false,
    this.auditEscalationLevel = 0,
    this.quality = 'useful',
  });

  static String buildSignature(
    String toolName,
    Map<String, dynamic> arguments,
  ) {
    final canonical = _canonicalize(arguments);
    return '$toolName:${jsonEncode(canonical)}';
  }

  static Object? _canonicalize(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => '$key').toList()..sort();
      return {
        for (final key in keys) key: _canonicalize(value[key]),
      };
    }
    if (value is List) {
      return value.map(_canonicalize).toList(growable: false);
    }
    return value;
  }

  Map<String, dynamic> toJson() {
    return {
      'index': index,
      'toolName': toolName,
      'signature': signature,
      'argumentsPreview': argumentsPreview,
      'outcome': outcome,
      'approvalRequired': approvalRequired,
      'approved': approved,
      'failed': failed,
      'emptyResult': emptyResult,
      'resultPreview': resultPreview,
      'cacheHit': cacheHit,
      'dedupBlocked': dedupBlocked,
      'auditEscalationLevel': auditEscalationLevel,
      'quality': quality,
    };
  }
}

class LlmToolUsageSignals {
  final int totalCalls;
  final int failedCalls;
  final int emptyResults;
  final int repeatedSignatureMaxStreak;
  final int alternatingPairMaxLength;
  final bool suspectedLoop;
  final bool likelyNotAdvancing;

  const LlmToolUsageSignals({
    required this.totalCalls,
    required this.failedCalls,
    required this.emptyResults,
    required this.repeatedSignatureMaxStreak,
    required this.alternatingPairMaxLength,
    required this.suspectedLoop,
    required this.likelyNotAdvancing,
  });

  factory LlmToolUsageSignals.fromLedger(List<LlmToolLedgerEntry> ledger) {
    var failedCalls = 0;
    var emptyResults = 0;
    var repeatedSignatureMaxStreak = 0;
    var repeatedSignatureCurrentStreak = 0;
    String? previousSignature;
    final signatures = <String>[];

    for (final entry in ledger) {
      signatures.add(entry.signature);
      if (entry.failed) {
        failedCalls += 1;
      }
      if (entry.emptyResult) {
        emptyResults += 1;
      }
      if (entry.signature == previousSignature) {
        repeatedSignatureCurrentStreak += 1;
      } else {
        repeatedSignatureCurrentStreak = 1;
        previousSignature = entry.signature;
      }
      if (repeatedSignatureCurrentStreak > repeatedSignatureMaxStreak) {
        repeatedSignatureMaxStreak = repeatedSignatureCurrentStreak;
      }
    }

    var alternatingPairMaxLength = 0;
    for (var start = 0; start < signatures.length - 1; start++) {
      final first = signatures[start];
      final second = signatures[start + 1];
      if (first == second) {
        continue;
      }
      var length = 2;
      for (var index = start + 2; index < signatures.length; index++) {
        final expected = signatures[index - 2];
        if (signatures[index] != expected ||
            signatures[index] == signatures[index - 1]) {
          break;
        }
        length += 1;
      }
      if (length > alternatingPairMaxLength) {
        alternatingPairMaxLength = length;
      }
    }

    final suspectedLoop = repeatedSignatureMaxStreak >= 3 ||
        alternatingPairMaxLength >= 4 ||
        (failedCalls >= 3 && ledger.length >= 4);
    final likelyNotAdvancing = suspectedLoop ||
        emptyResults >= 3 ||
        (failedCalls + emptyResults >= 4 && ledger.length >= 5);

    return LlmToolUsageSignals(
      totalCalls: ledger.length,
      failedCalls: failedCalls,
      emptyResults: emptyResults,
      repeatedSignatureMaxStreak: repeatedSignatureMaxStreak,
      alternatingPairMaxLength: alternatingPairMaxLength,
      suspectedLoop: suspectedLoop,
      likelyNotAdvancing: likelyNotAdvancing,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'totalCalls': totalCalls,
      'failedCalls': failedCalls,
      'emptyResults': emptyResults,
      'repeatedSignatureMaxStreak': repeatedSignatureMaxStreak,
      'alternatingPairMaxLength': alternatingPairMaxLength,
      'suspectedLoop': suspectedLoop,
      'likelyNotAdvancing': likelyNotAdvancing,
    };
  }
}

class LlmToolSafetyAuditResult {
  final bool shouldContinue;
  final String summary;
  final List<String> issues;
  final bool suspectedLoop;
  final bool goalDrift;
  final String recommendedNextAction;

  const LlmToolSafetyAuditResult({
    required this.shouldContinue,
    required this.summary,
    required this.issues,
    required this.suspectedLoop,
    required this.goalDrift,
    required this.recommendedNextAction,
  });

  factory LlmToolSafetyAuditResult.fromJson(Map<String, dynamic> json) {
    final issuesValue = json['issues'];
    final issues = issuesValue is List
        ? issuesValue
            .map((item) => '$item'.trim())
            .where((item) => item.isNotEmpty)
            .toList(growable: false)
        : const <String>[];
    return LlmToolSafetyAuditResult(
      shouldContinue: json['shouldContinue'] == true,
      summary: ('${json['summary'] ?? ''}').trim(),
      issues: issues,
      suspectedLoop: json['suspectedLoop'] == true,
      goalDrift: json['goalDrift'] == true,
      recommendedNextAction: ('${json['recommendedNextAction'] ?? ''}').trim(),
    );
  }

  factory LlmToolSafetyAuditResult.blocked({
    required String summary,
    required List<String> issues,
    required bool suspectedLoop,
    required bool goalDrift,
    required String recommendedNextAction,
  }) {
    return LlmToolSafetyAuditResult(
      shouldContinue: false,
      summary: summary,
      issues: issues,
      suspectedLoop: suspectedLoop,
      goalDrift: goalDrift,
      recommendedNextAction: recommendedNextAction,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'shouldContinue': shouldContinue,
      'summary': summary,
      'issues': issues,
      'suspectedLoop': suspectedLoop,
      'goalDrift': goalDrift,
      'recommendedNextAction': recommendedNextAction,
    };
  }
}

class CachedToolResult {
  final String result;
  final DateTime expiresAt;

  const CachedToolResult({
    required this.result,
    required this.expiresAt,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);
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

class StreamingToolCall {
  String id;
  String name;
  String arguments;

  StreamingToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });
}

enum AgentFinalOutcome {
  success,
  cancelled,
  modelError,
  toolError,
  approvalRejected,
  planModeBlocked,
  budgetAuditRejected,
  loopGuardBlocked,
  approvalUnavailable,
}

class AgentRunSummary {
  final String runId;
  final DateTime startedAt;
  final DateTime finishedAt;
  final String model;
  final String helperModel;
  final String auditModel;
  final bool planMode;
  final int promptTokens;
  final int completionTokens;
  final int toolCalls;
  final int cacheHits;
  final int dedupBlockedCalls;
  final int approvalCount;
  final int approvedCount;
  final int helperFanout;
  final int auditEscalationLevel;
  final List<String> selectedToolSet;
  final List<String> memorySources;
  final AgentFinalOutcome finalOutcome;

  const AgentRunSummary({
    required this.runId,
    required this.startedAt,
    required this.finishedAt,
    required this.model,
    required this.helperModel,
    required this.auditModel,
    required this.planMode,
    required this.promptTokens,
    required this.completionTokens,
    required this.toolCalls,
    required this.cacheHits,
    required this.dedupBlockedCalls,
    required this.approvalCount,
    required this.approvedCount,
    required this.helperFanout,
    required this.auditEscalationLevel,
    required this.selectedToolSet,
    required this.memorySources,
    required this.finalOutcome,
  });

  Map<String, dynamic> toJson() {
    return {
      'runId': runId,
      'startedAt': startedAt.toIso8601String(),
      'finishedAt': finishedAt.toIso8601String(),
      'model': model,
      'helperModel': helperModel,
      'auditModel': auditModel,
      'planMode': planMode,
      'promptTokens': promptTokens,
      'completionTokens': completionTokens,
      'toolCalls': toolCalls,
      'cacheHits': cacheHits,
      'dedupBlockedCalls': dedupBlockedCalls,
      'approvalCount': approvalCount,
      'approvedCount': approvedCount,
      'helperFanout': helperFanout,
      'auditEscalationLevel': auditEscalationLevel,
      'selectedToolSet': selectedToolSet,
      'memorySources': memorySources,
      'finalOutcome': finalOutcome.name,
    };
  }
}
