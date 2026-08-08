// AI Feature 的跨层 Port。
//
// Port 只保留 AI 真实使用的最小能力。App Shell 负责实现这些接口并注入，
// AI Package 不直接创建 SSH、SFTP、监控、WebView、设置或全局日志对象。

import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart';
import 'package:feature_playbook/feature_playbook.dart';
import 'package:flutter/foundation.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import 'ai_models.dart';
import 'ai_webview_models.dart';
import '../llm/provider/llm_api_format.dart';

/// AI 运行时读取和修改聊天、技能、模型设置及应用备份所需的存储能力。
abstract interface class AiStoragePort {
  List<ConnectionConfig> get connections;

  ConnectionConfig? getConnection(String id);

  Future<List<AiChatRecord>> loadAiChats();

  Future<void> saveAiChat(AiChatRecord chat);

  Future<void> deleteAiChat(String id);

  Future<List<AiSkillRecord>> loadAiSkills();

  Future<void> saveAiSkill(AiSkillRecord skill);

  Future<bool> saveAiSkillIfUnchanged(
    AiSkillRecord expected,
    AiSkillRecord next,
  );

  Future<void> deleteAiSkill(String id);

  Future<List<AgentRunMetrics>> loadAgentRunMetrics();

  Future<void> saveAgentRunMetrics(AgentRunMetrics metrics);

  Future<List<AgentTraceEvent>> loadAgentTraceEvents(String runId);

  Future<List<String>> loadRecentAgentTraceRunIdsForChat(
    String chatId, {
    int limit = 20,
  });

  Future<void> saveAgentTraceEvent(AgentTraceEvent event);

  Future<void> saveAgentTraceEvents(List<AgentTraceEvent> events);

  Future<void> deleteAgentTraceEvents(String runId);

  Future<AiConnectionSettings> loadAiConnectionSettings();

  Future<void> saveAiConnectionSettings(AiConnectionSettings settings);

  /// 兼容工具侧的增量更新；App Shell 负责合并并持久化完整设置。
  Future<void> saveAiConnectionSettingsLegacy({
    required String baseUrl,
    required String model,
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
    bool? multiAgentEnabled,
    int? multiAgentMaxAgents,
    bool? postToolReviewEnabled,
    int? toolCallBudget,
    String? agentLoopMode,
    int? maxImageSizeBytes,
    int? maxFileSizeBytes,
    String? apiKey,
    String? selectedApiKeyId,
    bool clearApiKey = false,
    String? quarkSearchEndpoint,
    String? quarkApiKey,
    bool clearQuarkApiKey = false,
    bool? useCustomPrompts,
    String? customSystemPrompt,
    String? customPlannerPrompt,
    String? customOperatorPrompt,
    String? customExplorePrompt,
    String? customReviewerPrompt,
    String? customSummarizerPrompt,
    String? customCoordinatorPrompt,
    LlmApiFormat? apiFormat,
  });

  Future<AiRuntimeConnectionSnapshot> loadAiRuntimeConnectionSnapshot();

  Future<String> getAiApiKey();

  Future<String?> getAiApiKeyById(String id);

  Future<List<AiApiKeyHistoryEntry>> loadAiApiKeyHistory();

  Future<List<String>> loadAiBaseUrlHistory();

  Future<List<String>> loadCachedAiModels({String? baseUrl});

  Future<void> saveCachedAiModels({
    required String baseUrl,
    required List<String> models,
  });

  Future<void> removeAiBaseUrlHistoryEntry(String baseUrl);

  Future<void> removeAiApiKeyHistoryEntry(String id);

  Future<String> getAliyunApiKey();

  Future<List<Playbook>> loadPlaybooks();

  Future<void> savePlaybook(Playbook playbook);

  Future<String> exportAppDataJson();

  Future<void> importAppDataJson(String jsonText);

  bool get isSecretCacheEnabled;

  int get secretCacheTtlMinutes;

  Future<void> setSecretCacheEnabled(bool enabled);

  Future<void> setSecretCacheTtl(Duration ttl);

  void clearSecretCache();

  Future<int> getAiRequestTimeoutSeconds();

  Future<List<AiSshSessionSnapshot>> loadRestorableTmuxSessions();

  Map<String, ssh_core.SshTargetBinding> captureConnectionTargetBindings(
    Iterable<String> connectionIds,
  );

  Future<ssh_core.SshRuntimeTarget?> resolveConnectionTarget(
    ssh_core.SshTargetBinding binding,
  );
}

/// AI 使用的 App 设置最小读写契约。
abstract interface class AiSettingsPort implements Listenable {
  AppLanguage get language;

  bool get isEnglish;

  bool get ragEnabled;

  String get ragSearchMode;

  int get ragTopN;

  int get sftpDownloadLimitBytes;

  int get sftpTextEditLimitBytes;

  Future<void> setRagEnabled(bool value);

  Future<void> setRagSearchMode(String value);

  Future<void> setRagTopN(int value);

  Future<void> setSftpDownloadLimitBytes(int value);

  Future<void> setSftpTextEditLimitBytes(int value);
}

/// AI 运行时使用的 SSH 会话摘要；不暴露终端输出或凭据。
enum AiSshConnectionState { disconnected, connecting, connected, error }

final class AiSshConnectionOverview {
  const AiSshConnectionOverview({
    required this.count,
    required this.latestState,
    required this.hasConnected,
  });

  final int count;
  final AiSshConnectionState? latestState;
  final bool hasConnected;
}

final class AiSshOverviewSnapshot {
  const AiSshOverviewSnapshot({
    required this.byConnection,
    required this.windowCount,
  });

  final Map<String, AiSshConnectionOverview> byConnection;
  final int windowCount;
}

final class AiSshSessionSnapshot {
  const AiSshSessionSnapshot({
    required this.id,
    required this.connectionId,
    required this.connectionName,
    required this.displayName,
    required this.state,
    required this.isConnected,
    required this.createdAt,
    required this.updatedAt,
    this.tmuxSessionName,
    this.tmuxAutoDeleteSeconds,
    this.errorMessage,
    this.estimatedMemoryBytes = 0,
  });

  final String id;
  final String connectionId;
  final String connectionName;
  final String displayName;
  final AiSshConnectionState state;
  final bool isConnected;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? tmuxSessionName;
  final int? tmuxAutoDeleteSeconds;
  final String? errorMessage;
  final int estimatedMemoryBytes;

  String? get tmuxKillCommand {
    final name = tmuxSessionName;
    if (name == null || name.isEmpty) return null;
    return "tmux kill-session -t ${_shellQuote(name)}";
  }
}

/// 终端历史的脱敏摘要。
final class AiTerminalHistorySnapshot {
  const AiTerminalHistorySnapshot({
    required this.sessionId,
    required this.connectionId,
    required this.connectionName,
    required this.displayName,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
    this.tmuxSessionName,
    this.errorMessage,
  });

  final String sessionId;
  final String connectionId;
  final String connectionName;
  final String displayName;
  final String state;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? tmuxSessionName;
  final String? errorMessage;

  String? get tmuxKillCommand {
    final name = tmuxSessionName;
    if (name == null || name.isEmpty) return null;
    return "tmux kill-session -t ${_shellQuote(name)}";
  }
}

/// AI 所需的 SSH/终端能力；资源 Owner 仍由 AppRuntime 的 SSH Manager 持有。
abstract interface class AiSshPort {
  List<AiSshSessionSnapshot> get sessions;

  bool get isConnected;

  AiSshOverviewSnapshot get serverOverviewSnapshot;

  String? get errorMessage;

  AiSshSessionSnapshot? getSession(String sessionId);

  Future<String?> openSession(String connectionId, {String? displayName});

  Future<bool> ensureSessionConnected(String sessionId, String connectionId);

  bool renameSession(String sessionId, String name);

  Future<String> loadSessionHistoryText(String sessionId);

  bool hasConnectedSession(String connectionId);

  AiSshSessionSnapshot? latestSessionForConnection(String connectionId);

  int sessionCountForConnection(String connectionId);

  Future<void> disconnectSession(String sessionId);

  Future<void> disconnect();

  Future<void> disconnectSessionsForConnection(String connectionId);

  Future<void> restoreTmuxSessions();

  Future<List<AiTerminalHistorySnapshot>> loadTerminalHistoryRecords();

  Future<void> removeTerminalHistoryRecord(String sessionId);

  Future<RemoteCommandResult> runOneShotCommand({
    required String connectionId,
    required String command,
    Duration timeout,
  });
}

/// AI 使用的 SFTP 内容能力；实现由 App Shell 适配现有 SFTP Module。
abstract interface class AiSftpPort {
  Future<List<AiSftpEntrySnapshot>> listDirectoryForConnection(
    String connectionId,
    String path,
  );

  Future<AiSftpPathSnapshot> statPathForConnection({
    required String connectionId,
    required String path,
  });

  Future<String> readTextPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes,
  });

  Future<Uint8List> downloadPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes,
  });

  Future<void> writeTextPathForConnection({
    required String connectionId,
    required String path,
    required String text,
    int maxBytes,
  });

  Future<void> uploadBytesPathForConnection({
    required String connectionId,
    required String path,
    required Uint8List bytes,
    int maxBytes,
  });

  Future<void> createDirectoryPathForConnection({
    required String connectionId,
    required String path,
  });

  Future<void> renamePathForConnection({
    required String connectionId,
    required String path,
    required String newPath,
  });

  Future<void> deletePathForConnection({
    required String connectionId,
    required String path,
  });
}

/// SFTP 目录项的不可变摘要。
final class AiSftpEntrySnapshot {
  const AiSftpEntrySnapshot({
    this.connectionId = '',
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.isLink,
    required this.size,
    required this.sizeLabel,
    required this.modifiedAt,
    this.modifiedLabel,
  });

  final String connectionId;
  final String name;
  final String path;
  String get lowerName => name.toLowerCase();
  final bool isDirectory;
  final bool isLink;
  final int? size;
  final String sizeLabel;
  final DateTime? modifiedAt;
  final String? modifiedLabel;
}

/// SFTP 路径元数据摘要。
final class AiSftpPathSnapshot {
  const AiSftpPathSnapshot({
    required this.path,
    required this.isDirectory,
    required this.isLink,
    required this.size,
    required this.sizeLabel,
    required this.modifiedAt,
  });

  final String path;
  final bool isDirectory;
  final bool isLink;
  final int? size;
  final String sizeLabel;
  final DateTime? modifiedAt;

  Map<String, dynamic> toJson() => {
    'path': path,
    'type': isDirectory ? 'directory' : 'file',
    'isDirectory': isDirectory,
    'isLink': isLink,
    'size': size,
    'sizeLabel': sizeLabel,
    'modifiedAt': modifiedAt?.toIso8601String(),
  };
}

/// 监控工具所需的最小能力；内部仍由 Monitoring Module 管理采样 Timer。
abstract interface class AiMonitoringPort implements MonitoringCapability {
  Map<String, dynamic> getState();

  Map<String, dynamic> setSelectedServers(List<String> connectionIds);

  Map<String, dynamic> clearSelection();

  Future<Map<String, dynamic>> start();

  Map<String, dynamic> stop();

  Map<String, dynamic> stopForConnection(String connectionId);

  Map<String, dynamic> setInterval(Duration interval);

  Map<String, dynamic> setHistoryWindow(Duration window);

  Map<String, dynamic> getHealth({List<String>? connectionIds});

  Map<String, dynamic> getSamples(
    String connectionId, {
    bool visibleOnly = true,
    int limit = 100,
  });

  Map<String, dynamic> getAlerts({int limit = 50});

  Future<Map<String, dynamic>> getPorts(String connectionId);

  Future<Map<String, dynamic>> getApplications(String connectionId);

  Future<Map<String, dynamic>> startWithTargets(
    Map<String, ssh_core.SshTargetBinding> targets,
  );
}

/// 本地客户端系统工具 Port。
abstract interface class AiClientSystemPort {
  Map<String, dynamic> getClientTime();

  Map<String, dynamic> getClientDeviceInfo();

  Future<Map<String, dynamic>> getNetworkInfo();

  Future<Map<String, dynamic>> getBatteryStatus();

  Future<Map<String, dynamic>> getPermissionStatus();

  Future<Map<String, dynamic>> openAppSettings();

  Future<Map<String, dynamic>> setClipboard(String text);

  Future<Map<String, dynamic>> setAlarm({
    String? triggerAt,
    int? delaySeconds,
    int? delayMinutes,
    String? label,
    bool useSystemAlarm,
  });

  Future<Map<String, dynamic>> listAlarms();

  Future<Map<String, dynamic>> cancelAlarm(String alarmId);

  Future<Map<String, dynamic>> queryLogs({
    String? level,
    String? contains,
    int limit,
  });

  Future<Map<String, dynamic>> getLogCounts();

  Future<Map<String, dynamic>> deleteLogEntries(List<int> ids);

  Future<Map<String, dynamic>> clearLogs();

  Future<Map<String, dynamic>> saveBytesToFile({
    required String fileName,
    required List<int> bytes,
    String? dialogTitle,
  });

  Future<AiPickedFile?> pickFile({
    List<String>? allowedExtensions,
    String? dialogTitle,
  });
}

/// 本地文件选择结果；正文只在当前调用内存中传递。
final class AiPickedFile {
  const AiPickedFile({required this.name, required this.bytes, this.localPath});

  final String name;
  final Uint8List bytes;
  final String? localPath;
}

/// 客户端运行环境健康检查结果。
abstract interface class AiHealthPort {
  Future<AiRuntimeHealthReport> check({
    AiHealthProfile profile = AiHealthProfile.general,
  });
}

enum AiHealthProfile { general, agentExecution, background }

final class AiRuntimeHealthReport {
  const AiRuntimeHealthReport({
    required this.status,
    required this.issues,
    required this.raw,
  });

  final AiRuntimeHealthStatus status;
  final List<AiRuntimeHealthIssue> issues;
  final Map<String, dynamic> raw;

  /// 阻塞状态不能继续执行 Agent；该字段保持工具 JSON 的兼容语义。
  bool get canProceed => status != AiRuntimeHealthStatus.blocking;

  Map<String, dynamic> toJson() {
    final recommendations = <String>[];
    for (final issue in issues) {
      if (issue.recommendation.isNotEmpty &&
          !recommendations.contains(issue.recommendation)) {
        recommendations.add(issue.recommendation);
      }
    }
    return {
      'execution': 'client',
      'target': 'client_device',
      'status': status.name,
      'canProceed': canProceed,
      'issues': issues.map((item) => item.toJson()).toList(growable: false),
      'recommendations': recommendations,
      'raw': raw,
    };
  }
}

enum AiRuntimeHealthStatus { ok, warning, blocking }

final class AiRuntimeHealthIssue {
  const AiRuntimeHealthIssue({
    required this.code,
    required this.severity,
    required this.title,
    required this.detail,
    required this.recommendation,
  });

  final String code;
  final AiRuntimeHealthStatus severity;
  final String title;
  final String detail;
  final String recommendation;

  Map<String, dynamic> toJson() => {
    'code': code,
    'severity': severity.name,
    'title': title,
    'detail': detail,
    'recommendation': recommendation,
  };
}

/// AI 访问 WebView 的 Port；WebView Controller 和安全策略实现留在 Step19。
abstract interface class AiWebViewPort {
  Future<AiWebViewSnapshot> readPlainText(String chatId, {int maxChars});

  Future<AiWebViewSearchResult> searchWeb(
    String chatId,
    String query, {
    int maxResults,
    String? engine,
  });

  Future<AiWebViewStateSnapshot> getState(String chatId);

  Future<AiWebViewNavigationResult> navigate(
    String chatId, {
    required String action,
    String? input,
  });

  void interruptAiBrowsing(String chatId);

  void clearSession(String chatId);
}

/// App Shell 提供的服务端目录和诊断能力，避免 AI 直接依赖旧 Service。
abstract interface class AiServerCatalogPort {
  List<Map<String, dynamic>> listServerSummaries();

  Map<String, dynamic>? getServerDetails(String connectionId);

  ConnectionConfig buildUpdateCandidate(
    ConnectionConfig current,
    Map<String, dynamic> changes,
  );

  Future<Map<String, dynamic>> updateServerMetadata({
    required String connectionId,
    required Map<String, dynamic> changes,
    ssh_core.SshTargetBinding? approvedTarget,
    ConnectionConfig? approvedCurrent,
    ConnectionConfig? approvedCandidate,
  });

  Future<Map<String, dynamic>> deleteServer(String connectionId);

  Future<Map<String, dynamic>> reorderServers(List<String> orderedIds);
}

abstract interface class AiServerDiagnosticsPort {
  Future<Map<String, dynamic>> detectOs(String connectionId);

  Future<Map<String, dynamic>> getStatus({
    required String connectionId,
    String? mode,
  });

  Future<Map<String, dynamic>> generateOpsReport(String connectionId);
}

/// AI 日志能力；由 AppRuntime 的 AppLogService 适配。
abstract interface class AiLoggerPort {
  void info(String message, {String? details});

  void warning(String message, {String? details});

  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  });
}

/// AI 兼容日志静态入口的生命周期上下文。
///
/// 新代码通过 [AiLoggerPort] 注入；迁移期间仍有少量旧实现使用静态
/// `AppLogService` 外观，因此由 [AiModule] 在注册时安装、销毁时移除
/// 当前 App Scope logger，避免 Feature 直接依赖 App Shell 的日志实现。
abstract final class AiLoggerContext {
  static AiLoggerPort? _current;

  static AiLoggerPort get current => _current ?? const _NoopAiLogger();

  /// 安装当前 App Scope 的 AI logger。
  static void install(AiLoggerPort logger) {
    _current = logger;
  }

  /// 仅移除仍由本 Module 持有的 logger，避免旧 Module 销毁时清掉新实例。
  static void reset(AiLoggerPort logger) {
    if (identical(_current, logger)) _current = null;
  }
}

/// 未完成 App 组合或测试未安装 logger 时的安全空实现。
final class _NoopAiLogger implements AiLoggerPort {
  const _NoopAiLogger();

  @override
  void info(String message, {String? details}) {}

  @override
  void warning(String message, {String? details}) {}

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {}
}

String _shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";
