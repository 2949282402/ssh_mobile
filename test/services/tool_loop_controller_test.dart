import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/features/ai_chat/services/llm_chat_service.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/performance_monitor_tool_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/server_diagnostics_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/multi_agent_coordinator.dart';
import 'package:ssh_mobile/services/agent/plan_execution_controller.dart';
import 'package:ssh_mobile/features/playbook/models/playbook.dart';
import 'package:ssh_mobile/features/connection/models/connection.dart';

part 'tool_loop_core_tests.dart';
part 'tool_loop_gate_tests.dart';
part 'tool_loop_test_fakes.dart';

late StorageService storage;
late AiToolService tools;
late LlmChatService llm;

void main() {
  group('ToolLoopController integration tests', () {
    setUp(() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});

      storage = StorageService();
      await storage.init();

      await storage.saveAiConnectionSettings(
        baseUrl: 'https://api.example.com',
        model: 'demo-model',
        apiKey: 'dummy-key',
      );

      final ssh = SshService(storage);
      final sftp = SftpService(storage);
      final diagnostics = ServerDiagnosticsService(
        storageService: storage,
        sshService: ssh,
      );
      final monitor = PerformanceMonitorService(ssh, storage);
      tools = AiToolService(
        storageService: storage,
        sshService: ssh,
        sftpService: sftp,
        serverDiagnosticsService: diagnostics,
        performanceMonitorToolService: PerformanceMonitorToolService(monitor),
      );

      llm = LlmChatService(storageService: storage, toolService: tools);
    });

    tearDown(() {
      storage.dispose();
      debugDefaultTargetPlatformOverride = null;
    });

    _registerToolLoopCoreTests();
    _registerToolLoopGateTests();
  });
}
