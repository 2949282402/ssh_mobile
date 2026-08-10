import 'dart:convert';
import '../test_utils/ai_port_adapters.dart';
import '../test_utils/ai_tool_test_adapters.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:feature_ai/ai_tools.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/client_system_tool_service.dart';
import 'package:feature_ai/ai_chat.dart';
import 'package:ssh_mobile/services/server_diagnostics_service.dart';
import '../test_utils/test_storage_adapter.dart';
import 'package:feature_ai/ai_agent.dart';
import 'package:feature_playbook/feature_playbook.dart';
import 'package:connection_core/connection_core.dart';

part 'tool_loop_core_tests.dart';
part 'tool_loop_gate_tests.dart';
part 'tool_loop_test_fakes.dart';

late TestStorageAdapter storage;
late AiToolService tools;
late LlmChatService llm;

void main() {
  group('ToolLoopController integration tests', () {
    setUp(() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});

      storage = TestStorageAdapter();
      await storage.init();
      attachTestAiRepository(storage);

      await storage.saveAiConnectionSettings(
        baseUrl: 'https://api.example.com',
        model: 'demo-model',
        apiKey: 'dummy-key',
      );

      final ssh = createTestSshService(storage);
      final sftp = createTestSftpService(storage);
      final diagnostics = ServerDiagnosticsService(
        connectionRepository: storage.connectionRepository,
        sshService: ssh,
      );
      final monitor = createTestPerformanceMonitorService(ssh, storage);
      tools = createAiToolServiceFromLegacy(
        storageService: storage,
        sshService: ssh,
        sftpService: sftp,
        // 保持旧测试默认使用 App 客户端系统能力的行为，避免占位 Port 产生
        // “能力不可用”的工具错误。
        clientSystemToolService: ClientSystemToolService.instance,
        serverDiagnosticsService: diagnostics,
        performanceMonitorToolService: monitor,
      );

      llm = LlmChatService(
        storageService: aiStoragePort(storage),
        toolService: tools,
      );
    });

    tearDown(() async {
      await storage.shutdown();
      storage.dispose();
      debugDefaultTargetPlatformOverride = null;
    });

    _registerToolLoopCoreTests();
    _registerToolLoopGateTests();
  });
}
