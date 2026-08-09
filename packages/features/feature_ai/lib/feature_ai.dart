// AI Feature 的唯一公共入口；调用方不得导入本 Package 的 src/。
//
// AI 的 UI、Agent Runtime、工具执行器和 ai.db 都由本 Package 持有；App
// Shell 只通过 Port、Capability 和 Module 注入基础设施。
library;

import 'package:app_core/app_core.dart';

export 'src/application/ai_module.dart';
export 'src/domain/ai_models.dart';
export 'src/domain/ai_ports.dart';
export 'src/domain/ai_webview_models.dart';
export 'src/agent/agent_model_profile.dart';
export 'src/agent/multi_agent_coordinator.dart';
export 'src/skills/skill_frontmatter.dart';
export 'src/data/database/ai_database.dart';
export 'src/data/repositories/ai_repository.dart';
export 'src/application/ai_chat_runtime_factory.dart';
export 'src/presentation/ai_feature_scope.dart';
export 'src/chat/views/llm_chat_screen.dart';
export 'src/chat/viewmodels/ai_chat_viewmodel.dart'
    hide buildApprovedPlanExecutionContext;
export 'src/skills/views/ai_skill_edit_screen.dart';
export 'src/skills/views/ai_skills_screen.dart';
export 'src/skills/viewmodels/ai_skills_viewmodel.dart';
export 'src/tools/ai_tool_service.dart';
export 'src/tools/tool_exposure_router.dart';
export 'src/tools/tool_secret_policy.dart';
export 'src/llm/provider/llm_api_format.dart';

/// AI Feature 对外公布的稳定路由名称。
abstract final class AiRouteNames {
  /// Skills 列表页面。
  static const skills = '/ai-skills';

  /// Skill 编辑页面。
  static const skillEdit = '/ai-skills/edit';
}

/// AI Feature 的路由元数据贡献；App Shell 负责解释页面构建。
final List<ModuleRouteContribution> aiRouteContributions = List.unmodifiable([
  ModuleRouteContribution(routeName: AiRouteNames.skills),
  ModuleRouteContribution(routeName: AiRouteNames.skillEdit),
]);
