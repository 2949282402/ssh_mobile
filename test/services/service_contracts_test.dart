import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/client_system_tool_service.dart';
import 'package:ssh_mobile/services/client_webview_service.dart';
import 'package:ssh_mobile/services/llm_chat_service.dart';
import 'package:ssh_mobile/services/multi_agent_coordinator.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/performance_monitor_tool_service.dart';
import 'package:ssh_mobile/services/server_catalog_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/server_diagnostics_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  late StorageService storage;
  late SshService ssh;
  late SftpService sftp;
  late ServerDiagnosticsService diagnostics;
  late PerformanceMonitorService monitor;
  late AiToolService tools;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    storage = StorageService();
    ssh = SshService(storage);
    sftp = SftpService(storage);
    diagnostics = ServerDiagnosticsService(
      storageService: storage,
      sshService: ssh,
    );
    monitor = PerformanceMonitorService(ssh, storage);
    tools = AiToolService(
      storageService: storage,
      sshService: ssh,
      sftpService: sftp,
      serverDiagnosticsService: diagnostics,
      performanceMonitorToolService: PerformanceMonitorToolService(monitor),
    );
  });

  tearDown(() {
    sftp.dispose();
    ssh.dispose();
    storage.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  test('core services expose injectable contracts', () {
    final llm = LlmChatService(
      storageService: storage,
      toolService: tools,
    );

    expect(storage, isA<AiChatRepository>());
    expect(storage, isA<AiSkillRepository>());
    expect(storage, isA<TerminalHistoryRepository>());
    expect(storage, isA<AppBackupRepository>());
    expect(ssh, isA<SshClientAdapter>());
    expect(sftp, isA<SftpClientAdapter>());
    expect(ClientSystemToolService.instance, isA<ClientSystemToolAdapter>());
    expect(ClientWebViewService.instance, isA<ClientWebViewAdapter>());
    expect(
      ServerCatalogService(
        storageService: storage,
        sshService: ssh,
        sftpService: sftp,
      ),
      isA<ServerCatalogAdapter>(),
    );
    expect(
      PerformanceMonitorToolService(monitor),
      isA<PerformanceMonitorToolAdapter>(),
    );
    expect(diagnostics, isA<ServerDiagnosticsAdapter>());
    expect(tools, isA<AiToolExecutor>());
    expect(llm, isA<LlmClientAdapter>());
    expect(const MultiAgentCoordinator(), isA<MultiAgentCoordinatorAdapter>());
  });
}
