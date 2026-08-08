// AI Chat 的公共分类出口。
//
// App Shell 和测试只依赖本文件，不直接访问 feature_ai/src；聊天页面、
// ViewModel、编排器、LLM 聊天服务及其子控件由同一个 Feature 维护。
library;

export 'src/domain/ai_models.dart';
export 'src/domain/ai_webview_models.dart';
export 'src/application/ai_chat_runtime_factory.dart';
export 'src/chat/chat_context_assembler.dart';
export 'src/chat/chat_orchestrator.dart';
export 'src/chat/operational_memory_retriever.dart';
export 'src/chat/pages/agent_trace_debug_page.dart';
export 'src/chat/services/agent_trace_recorder.dart';
export 'src/chat/services/ai_chat_context_builder.dart';
export 'src/chat/services/ai_chat_generation_runner.dart';
export 'src/chat/services/ai_chat_message_mapper.dart';
export 'src/chat/services/ai_chat_run_metrics_recorder.dart';
export 'src/chat/services/ai_chat_run_state_reconciler.dart';
export 'src/chat/services/ai_chat_status_translator.dart';
export 'src/chat/services/ai_chat_token_estimator.dart';
export 'src/chat/services/llm_chat_service.dart';
export 'src/chat/services/plan_approval_eligibility.dart';
export 'src/chat/services/plan_command_parser.dart';
export 'src/chat/viewmodels/ai_chat_viewmodel.dart'
    hide buildApprovedPlanExecutionContext;
export 'src/chat/views/llm_chat_screen.dart';
export 'src/chat/views/widgets/ai_strings.dart';
export 'src/chat/views/widgets/attachment_image_thumbnail.dart';
export 'src/chat/views/widgets/history_action_sheet.dart';
export 'src/chat/views/widgets/message_attachments_wrap.dart';
export 'src/chat/views/widgets/message_bubble.dart';
export 'src/chat/views/widgets/trace_panel.dart';
