// ignore_for_file: library_private_types_in_public_api
import '../test_utils/ai_tool_test_adapters.dart';
import '../test_utils/ai_port_adapters.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/features/playbook/models/playbook.dart';
import 'package:feature_ai/ai_tools.dart';
import 'package:feature_ai/ai_tools.dart' as ai_tools;
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/client_system_tool_service.dart';
import 'package:feature_webview/feature_webview.dart';
import 'package:ssh_mobile/services/connection_target_binding.dart';
import 'package:ssh_mobile/services/performance_monitor_tool_service.dart';
import 'package:ssh_mobile/services/server_catalog_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/server_diagnostics_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import '../test_utils/test_storage_adapter.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

part 'ai_tool_core_tests.dart';
part 'ai_tool_skill_tests.dart';
part 'ai_tool_plan_tests.dart';
part 'ai_tool_connection_tests.dart';
part 'ai_tool_test_fakes.dart';

late TestStorageAdapter storage;
late SshService ssh;
late _FakeSftpClient sftp;
late _FakeClientSystemToolService clientSystem;
late _FakeClientWebViewAdapter clientWebView;
late _FakeServerCatalogService serverCatalog;
late _FakePerformanceMonitorToolService performanceMonitor;
late _FakeServerDiagnosticsService diagnostics;
late AppSettings appSettings;
late AiToolService tools;
late AiToolService toolsWithoutChatSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({
      'sftp_download_limit_bytes': 8,
      'sftp_text_edit_limit_bytes': 4,
    });
    FlutterSecureStorage.setMockInitialValues({});

    storage = TestStorageAdapter();
    await storage.init();
    attachTestAiRepository(storage);
    await storage.addConnection(
      ConnectionConfig(
        id: 'server-1',
        name: 'Demo Server',
        host: 'example.com',
        username: 'root',
        launchMode: TerminalLaunchMode.ssh,
        serverPlatform: ServerPlatform.linux,
      ),
    );
    ssh = createTestSshService(storage);
    sftp = _FakeSftpClient();
    clientSystem = _FakeClientSystemToolService();
    clientWebView = _FakeClientWebViewAdapter();
    serverCatalog = _FakeServerCatalogService();
    performanceMonitor = _FakePerformanceMonitorToolService();
    diagnostics = _FakeServerDiagnosticsService();
    appSettings = AppSettings();
    await appSettings.init();

    tools = _buildTools(
      storage: storage,
      ssh: ssh,
      sftp: sftp,
      clientSystem: clientSystem,
      clientWebView: clientWebView,
      serverCatalog: serverCatalog,
      performanceMonitor: performanceMonitor,
      diagnostics: diagnostics,
      appSettings: appSettings,
      chatId: 'chat-1',
    );
    toolsWithoutChatSession = _buildTools(
      storage: storage,
      ssh: ssh,
      sftp: sftp,
      clientSystem: clientSystem,
      clientWebView: clientWebView,
      serverCatalog: serverCatalog,
      performanceMonitor: performanceMonitor,
      diagnostics: diagnostics,
      appSettings: appSettings,
    );
  });

  tearDown(() async {
    await storage.shutdown();
    storage.dispose();
    AppLogService.instance.clear();
    ssh.dispose();
    debugDefaultTargetPlatformOverride = null;
  });
  _registerAiToolCoreTests();
  _registerAiToolSkillTests();
  _registerAiToolPlanTests();
  _registerAiToolConnectionTests();
}
