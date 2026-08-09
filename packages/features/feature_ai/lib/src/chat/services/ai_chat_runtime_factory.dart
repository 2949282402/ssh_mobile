// AI Chat 运行时工厂；集中组装聊天编排器和工具服务，避免页面自行创建跨层依赖。

import 'package:feature_ai/src/tools/ai_tool_service.dart';
import 'package:app_core/app_core.dart' as app_core;
import 'package:feature_playbook/feature_playbook.dart';
import 'package:feature_ai/src/domain/ai_compat.dart';
import 'package:feature_ai/src/chat/chat_context_assembler.dart';
import 'package:feature_ai/src/chat/chat_orchestrator.dart';
import 'llm_chat_service.dart';
import 'package:feature_ai/src/chat/operational_memory_retriever.dart';
import 'package:feature_ai/src/skills/skill_index_service.dart';

class AiChatRuntimeFactory {
  final AiStoragePort storageService;
  final SshService sshService;
  final SftpService sftpService;
  final PerformanceMonitorService performanceMonitorService;
  final PlaybookAutomationPort playbookService;
  final app_core.RagCapability ragService;
  final AppSettings appSettings;
  final AgentTraceRepository? traceRepository;
  final ClientSystemToolAdapter? clientSystemToolService;
  final ClientHealthAdvisorAdapter? clientHealthAdvisor;
  final ClientWebViewAdapter? clientWebViewService;
  final ServerCatalogAdapter? serverCatalogService;
  final ServerDiagnosticsAdapter? serverDiagnosticsService;
  final SkillIndexService _skillIndexService = SkillIndexService();

  AiChatRuntimeFactory({
    required this.storageService,
    required this.sshService,
    required this.sftpService,
    required this.performanceMonitorService,
    required this.playbookService,
    required this.ragService,
    required this.appSettings,
    this.traceRepository,
    this.clientSystemToolService,
    this.clientHealthAdvisor,
    this.clientWebViewService,
    this.serverCatalogService,
    this.serverDiagnosticsService,
  });

  ChatOrchestrator createOrchestrator() {
    return ChatOrchestrator(
      storageService: storageService,
      contextAssembler: ChatContextAssembler(storageService: storageService),
      memoryRetriever: OperationalMemoryRetriever(
        storageService: storageService,
        ragService: ragService,
        skillIndexService: _skillIndexService,
      ),
    );
  }

  LlmChatService createLlmChatService({
    required AiConnectionSettings settings,
    required String model,
    required String chatId,
    AppLanguage language = AppLanguage.zh,
  }) {
    return LlmChatService(
      storageService: storageService,
      toolService: createToolService(chatId: chatId),
      language: language,
      useCustomPrompts: settings.useCustomPrompts,
      customSystemPrompt: settings.customSystemPrompt,
      customPlannerPrompt: settings.customPlannerPrompt,
      customOperatorPrompt: settings.customOperatorPrompt,
      customExplorePrompt: settings.customExplorePrompt,
      customReviewerPrompt: settings.customReviewerPrompt,
      customSummarizerPrompt: settings.customSummarizerPrompt,
      customCoordinatorPrompt: settings.customCoordinatorPrompt,
    );
  }

  AiToolService createToolService({String? chatId}) {
    return AiToolService(
      storageService: storageService,
      sshService: sshService,
      sftpService: sftpService,
      performanceMonitorToolService: PerformanceMonitorToolService(
        performanceMonitorService,
      ),
      appSettings: appSettings,
      playbookService: playbookService,
      clientSystemToolService: clientSystemToolService,
      clientHealthAdvisor: clientHealthAdvisor,
      clientWebViewService: clientWebViewService,
      serverCatalogService: serverCatalogService,
      serverDiagnosticsService: serverDiagnosticsService,
      clientWebViewSessionId: chatId,
    );
  }
}
