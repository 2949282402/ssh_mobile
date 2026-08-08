// AI 测试适配器。
//
// 旧 App Service 的行为测试仍需要真实的 Storage/SSH/SFTP/监控实例；本文件
// 只在测试边界把它们转换为 feature_ai 的公共 Port，避免测试直接依赖 src。

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:app_core/app_core.dart' as app_core;
import 'package:feature_ai/feature_ai.dart' as ai;
import 'package:flutter_test/flutter_test.dart';

import 'package:ssh_mobile/app/ai_feature_adapters.dart';
import 'package:ssh_mobile/app/rag_feature_adapters.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/client_health_advisor.dart'
    as legacy_health;
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/playbook_service.dart';
import 'package:ssh_mobile/services/rag_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

final Expando<ai.AiStoragePort> _storageAdapters = Expando<ai.AiStoragePort>(
  'aiStoragePort',
);
final Expando<ai.AiSettingsPort> _settingsAdapters = Expando<ai.AiSettingsPort>(
  'aiSettingsPort',
);
final Expando<ai.AiSshPort> _sshAdapters = Expando<ai.AiSshPort>('aiSshPort');
final Expando<ai.AiSftpPort> _sftpAdapters = Expando<ai.AiSftpPort>(
  'aiSftpPort',
);
final Expando<ai.AiMonitoringPort> _monitoringAdapters =
    Expando<ai.AiMonitoringPort>('aiMonitoringPort');
final Expando<app_core.RagCapability> _ragAdapters =
    Expando<app_core.RagCapability>('aiRagCapability');
final Expando<ai.AiHealthPort> _healthAdapters = Expando<ai.AiHealthPort>(
  'aiHealthPort',
);

ai.AiStoragePort aiStoragePort(StorageService service) {
  return _storageAdapters[service] ??= AppAiStorageAdapter(service);
}

ai.AiSettingsPort aiSettingsPort(AppSettings settings) {
  return _settingsAdapters[settings] ??= AppAiSettingsAdapter(settings);
}

ai.AiSshPort aiSshPort(SshService service) {
  return _sshAdapters[service] ??= AppAiSshAdapter(service);
}

ai.AiSftpPort aiSftpPort(SftpService service) {
  return _sftpAdapters[service] ??= AppAiSftpAdapter(service);
}

ai.AiMonitoringPort aiMonitoringPort(PerformanceMonitorService service) {
  return _monitoringAdapters[service] ??= AppAiMonitoringAdapter(
    service.delegate,
  );
}

app_core.RagCapability aiRagCapability(RagService service) {
  return _ragAdapters[service] ??= AppAiRagCapabilityAdapter(service);
}

ai.AiHealthPort aiHealthPort(legacy_health.ClientHealthAdvisorAdapter service) {
  if (service is ai.AiHealthPort) return service as ai.AiHealthPort;
  return _healthAdapters[service] ??= _LegacyHealthAdapter(service);
}

/// 将 App 测试中的 AppLogService 接到 AI 的公共 logger Port。
///
/// AI 包内的旧日志外观只允许通过 AiLoggerContext 访问当前注入实例；
/// 测试显式安装它，结束时恢复空实现，避免跨测试污染全局上下文。
void installTestAiLogger() {
  final logger = _TestAiLogger(AppLogService.instance);
  ai.AiLoggerContext.install(logger);
  addTearDown(() => ai.AiLoggerContext.reset(logger));
}

/// 为仍通过旧 [StorageService] 外观执行 AI 持久化测试的夹具注册独立仓库。
///
/// 生产路径由 AppRuntime 注入 AiModule；测试只能使用显式的内存执行器，
/// 并在当前测试结束时关闭数据库，避免把测试数据库生命周期偷偷放回旧
/// AppDatabase 或在 StorageService 中增加隐式回退。
ai.AiDatabase attachTestAiRepository(StorageService storage) {
  final database = ai.AiDatabase.forTesting(NativeDatabase.memory());
  final repository = ai.DriftAiRepository(
    database,
    const _TestAiTextProtection(),
  );
  storage.attachAiRepositoryLoader(() async => repository);
  addTearDown(database.dispose);
  return database;
}

/// 测试专用的可逆编码器，只用于验证 Repository 的加解密调用边界。
///
/// 生产数据保护仍由 App Shell 的 AES-GCM 适配器负责；这里使用 Base64
/// 是为了保证原文不会直接出现在内存 Drift 的测试表中，同时不依赖平台
/// Secure Storage 插件。
final class _TestAiTextProtection implements ai.AiTextProtectionPort {
  const _TestAiTextProtection();

  @override
  Future<String> encrypt(String plainText) async {
    return 'test-encrypted:${base64Encode(utf8.encode(plainText))}';
  }

  @override
  Future<String> decrypt(String storedText) async {
    const prefix = 'test-encrypted:';
    if (!storedText.startsWith(prefix)) return storedText;
    return utf8.decode(base64Decode(storedText.substring(prefix.length)));
  }
}

final class _TestAiLogger implements ai.AiLoggerPort {
  const _TestAiLogger(this._delegate);

  final AppLogService _delegate;

  @override
  void info(String message, {String? details}) =>
      _delegate.info(message, details: details);

  @override
  void warning(String message, {String? details}) =>
      _delegate.warning(message, details: details);

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) => _delegate.error(
    message,
    error: error,
    stackTrace: stackTrace,
    details: details,
  );
}

/// 将旧 App Service 测试夹具接到 AI Runtime Factory 的 Port 构造函数。
///
/// 生产代码由 AppRuntime 负责注入；测试保留原有夹具的资源初始化方式，
/// 只在 Package 边界完成一次类型转换，避免测试为了构造 ViewModel 而复制
/// Storage、SSH 或监控资源。
abstract class LegacyAiChatRuntimeFactory extends ai.AiChatRuntimeFactory {
  LegacyAiChatRuntimeFactory({
    required StorageService storageService,
    required SshService sshService,
    required SftpService sftpService,
    required PerformanceMonitorService performanceMonitorService,
    required PlaybookService playbookService,
    required RagService ragService,
    required AppSettings appSettings,
  }) : super(
         storageService: aiStoragePort(storageService),
         sshService: aiSshPort(sshService),
         sftpService: aiSftpPort(sftpService),
         performanceMonitorService: aiMonitoringPort(performanceMonitorService),
         playbookService: playbookService,
         ragService: aiRagCapability(ragService),
         appSettings: aiSettingsPort(appSettings),
       );
}

/// 用旧 App Service 构造默认 AI Runtime Factory，供迁移中的测试复用。
ai.AiChatRuntimeFactory createAiChatRuntimeFactory({
  required StorageService storageService,
  required SshService sshService,
  required SftpService sftpService,
  required PerformanceMonitorService performanceMonitorService,
  required PlaybookService playbookService,
  required RagService ragService,
  required AppSettings appSettings,
}) {
  return ai.AiChatRuntimeFactory(
    storageService: aiStoragePort(storageService),
    sshService: aiSshPort(sshService),
    sftpService: aiSftpPort(sftpService),
    performanceMonitorService: aiMonitoringPort(performanceMonitorService),
    playbookService: playbookService,
    ragService: aiRagCapability(ragService),
    appSettings: aiSettingsPort(appSettings),
  );
}

/// 用旧 App 测试夹具创建 AI ViewModel；ViewModel 本身仍只接收公开 Port。
ai.AiChatViewModel createAiChatViewModel({
  required StorageService storageService,
  required SshService sshService,
  required SftpService sftpService,
  required PerformanceMonitorService performanceMonitorService,
  required PlaybookService playbookService,
  required RagService ragService,
  required AppSettings appSettings,
  ai.AiChatRuntimeFactory? runtimeFactory,
  legacy_health.ClientHealthAdvisorAdapter? clientHealthAdvisor,
}) {
  return ai.AiChatViewModel(
    storageService: aiStoragePort(storageService),
    sshService: aiSshPort(sshService),
    sftpService: aiSftpPort(sftpService),
    performanceMonitorService: aiMonitoringPort(performanceMonitorService),
    playbookService: playbookService,
    ragService: aiRagCapability(ragService),
    appSettings: aiSettingsPort(appSettings),
    runtimeFactory: runtimeFactory,
    clientHealthAdvisor: clientHealthAdvisor == null
        ? null
        : aiHealthPort(clientHealthAdvisor),
  );
}

/// 用旧 App Service 构造 AI Skills ViewModel。
ai.AiSkillsViewModel createAiSkillsViewModel({
  required StorageService storageService,
  required AppSettings appSettings,
}) {
  return ai.AiSkillsViewModel(
    storageService: aiStoragePort(storageService),
    appSettings: aiSettingsPort(appSettings),
  );
}

/// 将旧健康报告转换为 AI 专用的脱敏模型；只转换值，不保留旧服务引用以外的资源。
final class _LegacyHealthAdapter implements ai.AiHealthPort {
  const _LegacyHealthAdapter(this._delegate);

  final legacy_health.ClientHealthAdvisorAdapter _delegate;

  @override
  Future<ai.AiRuntimeHealthReport> check({
    ai.AiHealthProfile profile = ai.AiHealthProfile.general,
  }) async {
    final report = await _delegate.check(
      profile: switch (profile) {
        ai.AiHealthProfile.general =>
          legacy_health.ClientHealthCheckProfile.general,
        ai.AiHealthProfile.agentExecution =>
          legacy_health.ClientHealthCheckProfile.agentExecution,
        ai.AiHealthProfile.background =>
          legacy_health.ClientHealthCheckProfile.background,
      },
    );
    return ai.AiRuntimeHealthReport(
      status: switch (report.status) {
        legacy_health.ClientRuntimeHealthStatus.ok =>
          ai.AiRuntimeHealthStatus.ok,
        legacy_health.ClientRuntimeHealthStatus.warning =>
          ai.AiRuntimeHealthStatus.warning,
        legacy_health.ClientRuntimeHealthStatus.blocking =>
          ai.AiRuntimeHealthStatus.blocking,
      },
      issues: report.issues
          .map(
            (issue) => ai.AiRuntimeHealthIssue(
              code: issue.code,
              severity: switch (issue.severity) {
                legacy_health.ClientRuntimeHealthStatus.ok =>
                  ai.AiRuntimeHealthStatus.ok,
                legacy_health.ClientRuntimeHealthStatus.warning =>
                  ai.AiRuntimeHealthStatus.warning,
                legacy_health.ClientRuntimeHealthStatus.blocking =>
                  ai.AiRuntimeHealthStatus.blocking,
              },
              title: issue.title,
              detail: issue.detail,
              recommendation: issue.recommendation,
            ),
          )
          .toList(growable: false),
      raw: report.raw,
    );
  }
}
