import 'package:feature_ai/ai_agent.dart';
import 'package:feature_ai/ai_chat.dart';
import 'package:feature_ai/ai_tools.dart';
import 'package:feature_ai/feature_ai.dart' as ai;
import 'package:feature_webview/feature_webview.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/client_system_tool_service.dart';
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:ssh_mobile/services/server_catalog_service.dart';
import 'package:ssh_mobile/services/server_diagnostics_service.dart';
import 'package:ssh_mobile/app/sftp_backend_adapters.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import '../test_utils/ai_port_adapters.dart';
import '../test_utils/ai_tool_test_adapters.dart';
import '../test_utils/test_storage_adapter.dart';

/// 验证 Step22 后各 App/Feature 入口仍通过公开 Port 协作，且不再依赖
/// 已删除的统一存储 Repository 类型。
void main() {
  late TestStorageAdapter storage;
  late SshService ssh;
  late SftpService sftp;
  late monitoring.MonitoringService monitor;
  late ServerDiagnosticsService diagnostics;
  late AiToolService tools;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    storage = TestStorageAdapter();
    await storage.init();
    ssh = createTestSshService(storage);
    sftp = createTestSftpService(storage);
    monitor = createTestPerformanceMonitorService(ssh, storage);
    diagnostics = ServerDiagnosticsService(
      connectionRepository: storage.connectionRepository,
      sshService: ssh,
    );
    tools = createAiToolServiceFromLegacy(
      storageService: storage,
      sshService: ssh,
      sftpService: sftp,
      serverDiagnosticsService: diagnostics,
      performanceMonitorToolService: monitor,
    );
  });

  tearDown(() async {
    sftp.dispose();
    ssh.dispose();
    await storage.shutdown();
    storage.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  test('services expose public capability contracts', () {
    final llm = LlmChatService(
      storageService: aiStoragePort(storage),
      toolService: tools,
    );

    expect(aiStoragePort(storage), isA<ai.AiStoragePort>());
    expect(ssh, isA<SshClientAdapter>());
    expect(sftp, isA<SftpClientAdapter>());
    expect(ClientSystemToolService.instance, isA<ClientSystemToolAdapter>());
    final webViewService = ClientWebViewService(logger: AppLogService.instance);
    addTearDown(webViewService.dispose);
    expect(webViewService, isA<ClientWebViewAdapter>());

    expect(
      ServerCatalogService(
        connectionRepository: storage.connectionRepository,
        credentialRepository: storage.credentialRepository,
        hostKeyRepository: storage.hostKeyRepository,
        sshService: ssh,
        sftpService: sftp,
      ),
      isA<ServerCatalogAdapter>(),
    );
    expect(diagnostics, isA<ServerDiagnosticsAdapter>());
    expect(aiMonitoringPort(monitor), isA<ai.AiMonitoringPort>());
    expect(tools, isA<AiToolExecutor>());
    expect(llm, isA<LlmClientAdapter>());
    expect(const MultiAgentCoordinator(), isA<MultiAgentCoordinatorAdapter>());
  });
}
