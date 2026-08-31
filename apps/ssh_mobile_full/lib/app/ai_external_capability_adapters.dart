// AI Feature 的外部能力适配器。
//
// 客户端系统、WebView、服务端目录、诊断和日志实现由 App Shell 组装。
// 本文件只做类型转换和委托；WebView Controller、页面安全策略及生命周期
// 由 feature_webview Package 持有，AI 只看到自己的能力 Port。

import 'package:feature_ai/feature_ai.dart' as ai;
import 'package:connection_core/connection_core.dart' as connection_core;
import 'package:feature_webview/feature_webview.dart' as webview;
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import '../core/services/data_protection_service.dart';
import '../services/app_log_service.dart';
import '../services/client_health_advisor.dart' as legacy_health;
import '../services/client_system_tool_service.dart' as legacy_system;
import '../services/connection_target_binding.dart';
import '../services/server_catalog_service.dart' as legacy_catalog;
import '../services/server_diagnostics_service.dart' as legacy_diagnostics;
import '../services/sftp_service.dart';
import '../services/ssh_service.dart';

/// App 的 AES-GCM 数据保护服务到 AI 数据库加密 Port 的适配器。
final class AppAiDataProtectionAdapter implements ai.AiTextProtectionPort {
  const AppAiDataProtectionAdapter(this._delegate);

  final DataProtectionService _delegate;

  @override
  Future<String> encrypt(String plainText) =>
      _delegate.encryptString(plainText);

  @override
  Future<String> decrypt(String storedText) =>
      _delegate.decryptString(storedText);
}

/// 将客户端系统工具转换为 AI 的客户端能力 Port。
final class AppAiClientSystemAdapter implements ai.AiClientSystemPort {
  AppAiClientSystemAdapter({legacy_system.ClientSystemToolService? delegate})
    : _delegate = delegate ?? legacy_system.ClientSystemToolService.instance;

  final legacy_system.ClientSystemToolService _delegate;

  @override
  Map<String, dynamic> getClientTime() => _delegate.getClientTime();

  @override
  Map<String, dynamic> getClientDeviceInfo() => _delegate.getClientDeviceInfo();

  @override
  Future<Map<String, dynamic>> getNetworkInfo() => _delegate.getNetworkInfo();

  @override
  Future<Map<String, dynamic>> getBatteryStatus() =>
      _delegate.getBatteryStatus();

  @override
  Future<Map<String, dynamic>> getPermissionStatus() =>
      _delegate.getPermissionStatus();

  @override
  Future<Map<String, dynamic>> openAppSettings() => _delegate.openAppSettings();

  @override
  Future<Map<String, dynamic>> setClipboard(String text) =>
      _delegate.setClipboard(text);

  @override
  Future<Map<String, dynamic>> setAlarm({
    String? triggerAt,
    int? delaySeconds,
    int? delayMinutes,
    String? label,
    bool useSystemAlarm = true,
  }) => _delegate.setAlarm(
    triggerAt: triggerAt,
    delaySeconds: delaySeconds,
    delayMinutes: delayMinutes,
    label: label,
    useSystemAlarm: useSystemAlarm,
  );

  @override
  Future<Map<String, dynamic>> listAlarms() => _delegate.listAlarms();

  @override
  Future<Map<String, dynamic>> cancelAlarm(String alarmId) =>
      _delegate.cancelAlarm(alarmId);

  @override
  Future<Map<String, dynamic>> queryLogs({
    String? level,
    String? contains,
    int limit = 50,
  }) => _delegate.queryLogs(level: level, contains: contains, limit: limit);

  @override
  Future<Map<String, dynamic>> getLogCounts() => _delegate.getLogCounts();

  @override
  Future<Map<String, dynamic>> deleteLogEntries(List<int> ids) =>
      _delegate.deleteLogEntries(ids);

  @override
  Future<Map<String, dynamic>> clearLogs() => _delegate.clearLogs();

  @override
  Future<Map<String, dynamic>> saveBytesToFile({
    required String fileName,
    required List<int> bytes,
    String? dialogTitle,
  }) => _delegate.saveBytesToFile(
    fileName: fileName,
    bytes: bytes,
    dialogTitle: dialogTitle,
  );

  @override
  Future<ai.AiPickedFile?> pickFile({
    List<String>? allowedExtensions,
    String? dialogTitle,
  }) async {
    final file = await _delegate.pickFile(
      allowedExtensions: allowedExtensions,
      dialogTitle: dialogTitle,
    );
    if (file == null) return null;
    return ai.AiPickedFile(
      name: file.name,
      bytes: file.bytes,
      localPath: file.localPath,
    );
  }
}

/// 将旧健康检查服务的结果转换为 AI 领域模型。
final class AppAiHealthAdapter implements ai.AiHealthPort {
  AppAiHealthAdapter(ai.AiClientSystemPort clientSystem)
    : _delegate = legacy_health.ClientHealthAdvisor(
        clientSystemToolService: _LegacyClientSystemAdapter(clientSystem),
      );

  final legacy_health.ClientHealthAdvisor _delegate;

  @override
  Future<ai.AiRuntimeHealthReport> check({
    ai.AiHealthProfile profile = ai.AiHealthProfile.general,
  }) async {
    final result = await _delegate.check(
      profile: switch (profile) {
        ai.AiHealthProfile.agentExecution =>
          legacy_health.ClientHealthCheckProfile.agentExecution,
        ai.AiHealthProfile.background =>
          legacy_health.ClientHealthCheckProfile.background,
        ai.AiHealthProfile.general =>
          legacy_health.ClientHealthCheckProfile.general,
      },
    );
    return ai.AiRuntimeHealthReport(
      status: _status(result.status),
      issues: result.issues
          .map(
            (item) => ai.AiRuntimeHealthIssue(
              code: item.code,
              severity: _status(item.severity),
              title: item.title,
              detail: item.detail,
              recommendation: item.recommendation,
            ),
          )
          .toList(growable: false),
      raw: result.raw,
    );
  }

  ai.AiRuntimeHealthStatus _status(
    legacy_health.ClientRuntimeHealthStatus status,
  ) => switch (status) {
    legacy_health.ClientRuntimeHealthStatus.ok => ai.AiRuntimeHealthStatus.ok,
    legacy_health.ClientRuntimeHealthStatus.warning =>
      ai.AiRuntimeHealthStatus.warning,
    legacy_health.ClientRuntimeHealthStatus.blocking =>
      ai.AiRuntimeHealthStatus.blocking,
  };
}

/// 把 AI 客户端 Port 临时桥接到旧健康检查器需要的接口。
///
/// `ClientHealthAdvisor` 只消费 permission/network/battery 三个探测，其余
/// `ClientSystemToolAdapter` 成员在 App 侧没有调用方；逐个转发既无法被任何
/// 公共适配器触达（无法满足新文件 90% 覆盖率门禁），又增加无意义的维护面。
/// 因此仅显式转发实际使用的成员，其余成员 fail-closed：任何意外调用都会在
/// 测试或 CI 中立即暴露为编程错误。
final class _LegacyClientSystemAdapter
    implements legacy_system.ClientSystemToolAdapter {
  const _LegacyClientSystemAdapter(this._delegate);

  final ai.AiClientSystemPort _delegate;

  @override
  Future<Map<String, dynamic>> getNetworkInfo() => _delegate.getNetworkInfo();

  @override
  Future<Map<String, dynamic>> getBatteryStatus() =>
      _delegate.getBatteryStatus();

  @override
  Future<Map<String, dynamic>> getPermissionStatus() =>
      _delegate.getPermissionStatus();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    '${invocation.memberName} is not forwarded: ClientHealthAdvisor '
    'only consumes permission, network, and battery probes.',
  );
}

/// 将 WebView Feature 的公开服务转换为 AI Port。
final class AppAiWebViewAdapter implements ai.AiWebViewPort {
  AppAiWebViewAdapter({required this._delegate});

  final webview.ClientWebViewAdapter _delegate;

  @override
  Future<ai.AiWebViewSnapshot> readPlainText(
    String chatId, {
    int maxChars = ai.aiWebViewDefaultMaxChars,
  }) async =>
      _toSnapshot(await _delegate.readPlainText(chatId, maxChars: maxChars));

  @override
  Future<ai.AiWebViewSearchResult> searchWeb(
    String chatId,
    String query, {
    int maxResults = 5,
    String? engine,
  }) async => _toSearchResult(
    await _delegate.searchWeb(
      chatId,
      query,
      maxResults: maxResults,
      engine: engine,
    ),
  );

  @override
  Future<ai.AiWebViewStateSnapshot> getState(String chatId) async =>
      _toState(await _delegate.getState(chatId));

  @override
  Future<ai.AiWebViewNavigationResult> navigate(
    String chatId, {
    required String action,
    String? input,
  }) async {
    final result = await _delegate.navigate(
      chatId,
      action: action,
      input: input,
    );
    return ai.AiWebViewNavigationResult(
      chatId: result.chatId,
      supported: result.supported,
      action: result.action,
      input: result.input,
      navigated: result.navigated,
      blocked: result.blocked,
      error: result.error,
      state: result.state == null ? null : _toState(result.state!),
    );
  }

  @override
  void interruptAiBrowsing(String chatId) =>
      _delegate.interruptAiBrowsing(chatId);

  @override
  void clearSession(String chatId) => _delegate.clearSession(chatId);

  ai.AiWebViewSnapshot _toSnapshot(webview.ClientWebViewSnapshot item) =>
      ai.AiWebViewSnapshot(
        chatId: item.chatId,
        supported: item.supported,
        hasPage: item.hasPage,
        text: item.text,
        textLength: item.textLength,
        maxChars: item.maxChars,
        truncated: item.truncated,
        blocked: item.blocked,
        sensitiveFormDetected: item.sensitiveFormDetected,
        url: item.url,
        title: item.title,
        capturedAt: item.capturedAt,
        error: item.error,
      );

  ai.AiWebViewSearchResult _toSearchResult(
    webview.ClientWebViewSearchResult item,
  ) => ai.AiWebViewSearchResult(
    chatId: item.chatId,
    supported: item.supported,
    query: item.query,
    engine: item.engine,
    searchUrl: item.searchUrl,
    title: item.title,
    results: item.results
        .map(
          (result) => ai.AiWebViewSearchItem(
            title: result.title,
            url: result.url,
            snippet: result.snippet,
          ),
        )
        .toList(growable: false),
    capturedAt: item.capturedAt,
    error: item.error,
  );

  ai.AiWebViewStateSnapshot _toState(webview.ClientWebViewStateSnapshot item) =>
      ai.AiWebViewStateSnapshot(
        chatId: item.chatId,
        supported: item.supported,
        hasPage: item.hasPage,
        progress: item.progress,
        isLoading: item.isLoading,
        isAiBrowsing: item.isAiBrowsing,
        canGoBack: item.canGoBack,
        canGoForward: item.canGoForward,
        lastTextLength: item.lastTextLength,
        lastTextTruncated: item.lastTextTruncated,
        url: item.url,
        title: item.title,
        aiBrowsingLabel: item.aiBrowsingLabel,
        aiBrowsingStartedAt: item.aiBrowsingStartedAt,
        lastError: item.lastError,
        lastTextCapturedAt: item.lastTextCapturedAt,
        updatedAt: item.updatedAt,
        error: item.error,
      );
}

/// 将服务端目录能力桥接为 AI Port，并保留原有审批快照校验。
final class AppAiServerCatalogAdapter implements ai.AiServerCatalogPort {
  AppAiServerCatalogAdapter({
    required connection_core.ConnectionRepository connectionRepository,
    required connection_core.CredentialRepository credentialRepository,
    required connection_core.HostKeyRepository hostKeyRepository,
    required SshService ssh,
    required SftpService sftp,
  }) : _delegate = legacy_catalog.ServerCatalogService(
         connectionRepository: connectionRepository,
         credentialRepository: credentialRepository,
         hostKeyRepository: hostKeyRepository,
         sshService: ssh,
         sftpService: sftp,
       );

  final legacy_catalog.ServerCatalogService _delegate;

  @override
  List<Map<String, dynamic>> listServerSummaries() =>
      _delegate.listServerSummaries();

  @override
  Map<String, dynamic>? getServerDetails(String connectionId) =>
      _delegate.getServerDetails(connectionId);

  @override
  connection_core.ConnectionConfig buildUpdateCandidate(
    connection_core.ConnectionConfig current,
    Map<String, dynamic> changes,
  ) => legacy_catalog.ServerCatalogService.buildUpdateCandidate(
    current,
    changes,
  );

  @override
  Future<Map<String, dynamic>> updateServerMetadata({
    required String connectionId,
    required Map<String, dynamic> changes,
    ssh_core.SshTargetBinding? approvedTarget,
    connection_core.ConnectionConfig? approvedCurrent,
    connection_core.ConnectionConfig? approvedCandidate,
  }) => _delegate.updateServerMetadata(
    connectionId: connectionId,
    changes: changes,
    approvedTarget: approvedTarget == null
        ? null
        : ConnectionTargetBinding.fromConfig(approvedTarget.config),
    approvedCurrent: approvedCurrent,
    approvedCandidate: approvedCandidate,
  );

  @override
  Future<Map<String, dynamic>> deleteServer(String connectionId) =>
      _delegate.deleteServer(connectionId);

  @override
  Future<Map<String, dynamic>> reorderServers(List<String> orderedIds) =>
      _delegate.reorderServers(orderedIds);
}

/// 将旧服务端诊断服务转换为 AI Port。
final class AppAiServerDiagnosticsAdapter
    implements ai.AiServerDiagnosticsPort {
  AppAiServerDiagnosticsAdapter({
    required connection_core.ConnectionRepository connectionRepository,
    required SshService ssh,
  }) : _delegate = legacy_diagnostics.ServerDiagnosticsService(
         connectionRepository: connectionRepository,
         sshService: ssh,
       );

  final legacy_diagnostics.ServerDiagnosticsService _delegate;

  @override
  Future<Map<String, dynamic>> detectOs(String connectionId) =>
      _delegate.detectOs(connectionId);

  @override
  Future<Map<String, dynamic>> getStatus({
    required String connectionId,
    String? mode,
  }) => _delegate.getStatus(connectionId: connectionId, mode: mode);

  @override
  Future<Map<String, dynamic>> generateOpsReport(String connectionId) =>
      _delegate.generateOpsReport(connectionId);
}

/// 将 AppLogService 限制为 AI 使用的最小日志 Port。
final class AppAiLoggerAdapter implements ai.AiLoggerPort {
  const AppAiLoggerAdapter(this._logger);

  final AppLogService _logger;

  @override
  void info(String message, {String? details}) =>
      _logger.info(message, details: details);

  @override
  void warning(String message, {String? details}) =>
      _logger.warning(message, details: details);

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) => _logger.error(
    message,
    error: error,
    stackTrace: stackTrace,
    details: details,
  );
}
