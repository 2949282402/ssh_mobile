import '../../../services/ai_tool_service.dart';
import '../../../services/app_settings.dart';
import '../../../services/chat_context_assembler.dart';
import '../../../services/chat_orchestrator.dart';
import 'llm_chat_service.dart';
import '../../../services/operational_memory_retriever.dart';
import '../../../services/performance_monitor_service.dart';
import '../../../services/performance_monitor_tool_service.dart';
import '../../../services/playbook_service.dart';
import '../../../services/rag_service.dart';
import '../../../services/sftp_service.dart';
import '../../../services/ssh_service.dart';
import '../../../services/storage_service.dart';
import '../../../services/skill/skill_index_service.dart';

class AiChatRuntimeFactory {
  final StorageService storageService;
  final SshService sshService;
  final SftpService sftpService;
  final PerformanceMonitorService performanceMonitorService;
  final PlaybookService playbookService;
  final RagService ragService;
  final AppSettings appSettings;
  final SkillIndexService _skillIndexService = SkillIndexService();

  AiChatRuntimeFactory({
    required this.storageService,
    required this.sshService,
    required this.sftpService,
    required this.performanceMonitorService,
    required this.playbookService,
    required this.ragService,
    required this.appSettings,
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
      clientWebViewSessionId: chatId,
    );
  }
}
