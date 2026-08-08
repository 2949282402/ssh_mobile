import 'dart:convert';

import 'package:feature_playbook/feature_playbook.dart';
import 'chat_context_assembler.dart';
import 'package:feature_ai/src/domain/ai_compat.dart';
import 'operational_memory_retriever.dart';

class ChatTurnPreparation {
  final AiChatMessageRecord userMessage;
  final AiChatMessageRecord assistantMessage;
  final List<String> memorySources;
  final int ragHits;

  const ChatTurnPreparation({
    required this.userMessage,
    required this.assistantMessage,
    this.memorySources = const [],
    this.ragHits = 0,
  });
}

class ChatTurnCompletion {
  final AiChatMessageRecord assistantMessage;
  final bool shouldExitPlanMode;

  const ChatTurnCompletion({
    required this.assistantMessage,
    required this.shouldExitPlanMode,
  });
}

class ChatOrchestrator {
  final StorageService storageService;
  final ChatContextAssembler contextAssembler;
  final OperationalMemoryRetriever memoryRetriever;

  const ChatOrchestrator({
    required this.storageService,
    required this.contextAssembler,
    required this.memoryRetriever,
  });

  Future<ChatTurnPreparation> prepareTurn({
    required AiChatRecord chat,
    required String text,
    required DateTime createdAt,
    required AppLanguage language,
    required List<AiChatAttachment> attachments,
    Set<String> selectedConnectionIds = const {},
    Map<String, ConnectionTargetBinding> connectionTargets = const {},
    AiApprovedPlanRef? approvedPlanRef,
    bool ragEnabled = false,
    String ragSearchMode = 'bm25',
    int ragLimit = 3,
    String ragAliyunApiKey = '',
  }) async {
    final memory = await memoryRetriever.retrieve(
      query: text,
      selectedConnectionIds: selectedConnectionIds,
      ragEnabled: ragEnabled,
      ragSearchMode: ragSearchMode,
      ragLimit: ragLimit,
      ragAliyunApiKey: ragAliyunApiKey,
    );
    final approvedPlanMessage = approvedPlanRef == null
        ? null
        : approvedPlanMessageForChat(
            chat.copyWith(approvedPlan: approvedPlanRef),
          );
    final userContextText = await contextAssembler.buildUserContext(
      userText: text,
      language: language,
      selectedConnectionIds: selectedConnectionIds,
      connectionTargets: connectionTargets,
      ragChunks: memory.ragChunks,
      memoryHits: memory.hits,
      approvedPlanMessage: approvedPlanMessage,
    );

    final traces = <AiMessageTrace>[];
    if (memory.ragChunks.isNotEmpty) {
      traces.add(
        AiMessageTrace.create(
          kind: 'rag_context',
          title: language == AppLanguage.en
              ? 'Knowledge Base Retrieval (RAG)'
              : '知识库检索 (RAG)',
          content: memory.ragChunks
              .map((chunk) {
                return ['Source: ${chunk.documentName}', chunk.text].join('\n');
              })
              .join('\n\n---\n\n'),
          createdAt: createdAt,
        ),
      );
    }
    if (memory.hits.isNotEmpty) {
      traces.add(
        AiMessageTrace.create(
          kind: 'memory_context',
          title: language == AppLanguage.en ? 'Operational Memory' : '运维记忆召回',
          content: memory.hits
              .map((hit) => '[${hit.sourceType}] ${hit.title}\n${hit.content}')
              .join('\n\n---\n\n'),
          createdAt: createdAt,
        ),
      );
    }

    return ChatTurnPreparation(
      userMessage: AiChatMessageRecord(
        role: 'user',
        text: text,
        contextText: userContextText,
        attachments: attachments,
        createdAt: createdAt,
      ),
      assistantMessage: AiChatMessageRecord(
        role: 'assistant',
        text: '',
        traces: traces,
        createdAt: createdAt,
      ),
      memorySources: memory.sourceTypes,
      ragHits: memory.ragChunks.length,
    );
  }

  ChatTurnCompletion finalizeAssistantTurn({
    required AiChatRecord initialChat,
    required AiChatMessageRecord assistantMessage,
    required String answerText,
    required List<AiMessageTrace> traces,
  }) {
    final existingSteps = assistantMessage.todoSteps;
    final parsedSteps = initialChat.planMode
        ? _parseTodoStepsFromText(
            answerText,
            assistantCreatedAt: assistantMessage.createdAt,
          )
        : const <AiTodoStep>[];
    final todoSteps = existingSteps.isNotEmpty ? existingSteps : parsedSteps;
    final nextTraces = [...traces];
    if (initialChat.planMode && todoSteps.isEmpty) {
      nextTraces.add(
        AiMessageTrace.create(
          kind: 'plan_error',
          title: 'Plan persistence failed',
          content:
              'The response did not persist any executable todoSteps. Return a valid ```playbook JSON block or call client_task_create before leaving Plan Mode.',
        ),
      );
    }

    final finalizedAssistant = assistantMessage.copyWith(
      text: answerText,
      contextText: contextAssembler.buildAssistantContext(
        answerText,
        traces: nextTraces,
      ),
      traces: nextTraces,
      todoSteps: todoSteps,
    );
    return ChatTurnCompletion(
      assistantMessage: finalizedAssistant,
      shouldExitPlanMode: initialChat.planMode && todoSteps.isNotEmpty,
    );
  }

  List<AiTodoStep> _parseTodoStepsFromText(
    String text, {
    required DateTime assistantCreatedAt,
  }) {
    final reg = RegExp(r'```playbook\s*([\s\S]*?)\s*```');
    final matches = reg.allMatches(text);
    for (final match in matches) {
      try {
        final rawJson = match.group(1);
        if (rawJson == null || rawJson.trim().isEmpty) continue;
        final decoded = jsonDecode(rawJson);
        if (decoded is! Map<String, dynamic>) continue;
        final stepsList = decoded['steps'];
        if (stepsList is! List || stepsList.isEmpty) continue;

        final parsedSteps = <AiTodoStep>[];
        var isPlaybookValid = true;

        for (var idx = 0; idx < stepsList.length; idx++) {
          final item = stepsList[idx];
          if (item is! Map) {
            isPlaybookValid = false;
            break;
          }
          final name = item['name']?.toString().trim();
          if (name == null || name.isEmpty) {
            isPlaybookValid = false;
            break;
          }
          parsedSteps.add(
            AiTodoStep(
              id: buildStableTodoStepId(assistantCreatedAt, idx),
              name: name,
              command: item['command']?.toString() ?? '',
              description: item['description']?.toString() ?? '',
              status: StepStatus.pending,
              connectionId: item['connectionId']?.toString(),
            ),
          );
        }

        if (isPlaybookValid && parsedSteps.isNotEmpty) {
          return parsedSteps;
        }
      } catch (_) {
        // Continue to the next match if JSON parsing fails or steps missing
      }
    }
    return const [];
  }
}
