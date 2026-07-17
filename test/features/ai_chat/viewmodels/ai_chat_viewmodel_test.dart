import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/features/ai_chat/viewmodels/ai_chat_viewmodel.dart';
import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/client_health_advisor.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/playbook_service.dart';
import 'package:ssh_mobile/services/rag_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/utils/text_chunker.dart';
import 'package:ssh_mobile/features/ai_chat/services/ai_chat_runtime_factory.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/features/ai_chat/services/llm_chat_service.dart';
import 'package:ssh_mobile/services/llm_runtime/llm_runtime_types.dart';
import '../../../test_utils/wait_until.dart';

part 'ai_chat_viewmodel_core_tests.dart';
part 'ai_chat_viewmodel_generation_tests.dart';
part 'ai_chat_viewmodel_fakes.dart';

late StorageService storageService;
late SshService sshService;
late SftpService sftpService;
late PerformanceMonitorService performanceMonitorService;
late PlaybookService playbookService;
late RagService ragService;
late AppSettings appSettings;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storageService = _GateNextChatSaveStorage();
    await storageService.init();

    appSettings = AppSettings();
    await appSettings.init();

    sshService = SshService(storageService);
    sftpService = SftpService(storageService);
    performanceMonitorService = PerformanceMonitorService(
      sshService,
      storageService,
    );
    playbookService = PlaybookService(
      storageService: storageService,
      sshService: sshService,
    );
    ragService = RagService(storageService: storageService);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    storageService.dispose();
  });

  group('AiChatViewModel Tests', () {
    _registerAiChatViewModelCoreTests();
    _registerAiChatViewModelGenerationTests();
  });
}
