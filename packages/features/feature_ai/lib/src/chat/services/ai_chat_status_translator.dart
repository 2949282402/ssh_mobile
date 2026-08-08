import 'package:feature_ai/src/domain/ai_compat.dart';
import 'llm_chat_service.dart';

enum AgentStatusString {
  preparing,
  thinking,
  responding,
  processingToolResult,
  processingApproval,
  collaborating,
  stopped,
}

class AiChatStatusTranslator {
  final AppLanguage language;

  const AiChatStatusTranslator(this.language);

  bool get isEn => language == AppLanguage.en;

  String translateStatus(AgentStatusString status) {
    switch (status) {
      case AgentStatusString.preparing:
        return isEn ? 'Preparing...' : '模型正在准备回答...';
      case AgentStatusString.thinking:
        return isEn ? 'Thinking...' : '模型正在思考...';
      case AgentStatusString.responding:
        return isEn ? 'Responding...' : '正在输出回答...';
      case AgentStatusString.processingToolResult:
        return isEn ? 'Processing result...' : '正在处理工具结果...';
      case AgentStatusString.processingApproval:
        return isEn ? 'Processing approval...' : '正在处理审批结果...';
      case AgentStatusString.collaborating:
        return isEn ? 'Collaborating...' : '正在协调多 Agent 协作...';
      case AgentStatusString.stopped:
        return isEn ? 'Stopped.' : '输出已停止。';
    }
  }

  String translateTrace(LlmTraceEvent event) {
    switch (event.kind) {
      case 'reasoning':
        return translateStatus(AgentStatusString.thinking);
      case 'tool_request':
        return translateRunningTool(translateToolName(event.title));
      case 'tool_result':
        return translateStatus(AgentStatusString.processingToolResult);
      case 'approval':
        return translateStatus(AgentStatusString.processingApproval);
      case 'multi_agent':
        return translateStatus(AgentStatusString.collaborating);
      case 'budget':
        final lowerTitle = event.title.toLowerCase();
        if (lowerTitle.contains('running')) {
          return isEn ? 'Auditing tool...' : '继续前正在审计工具调用...';
        }
        if (lowerTitle.contains('rejected')) {
          return isEn ? 'Tool blocked by audit.' : '安全审计后已停止继续调用工具...';
        }
        return isEn ? 'Budget extended.' : '工具预算已扩展，请留意工具调用是否合理...';
      default:
        return translateStatus(AgentStatusString.preparing);
    }
  }

  String translateToolName(String title) {
    final index = title.indexOf(':');
    if (index < 0 || index == title.length - 1) return title;
    return title.substring(index + 1).trim();
  }

  String translateRunningTool(String toolName) {
    final name = toolName.trim();
    if (isEn) {
      return name.isEmpty ? 'Running tool...' : 'Running $name...';
    }
    return name.isEmpty ? '正在调用工具...' : '正在调用工具：$name';
  }

  String translateAwaitingApproval(String serverName) {
    final name = serverName.trim();
    if (isEn) {
      return name.isEmpty
          ? 'Waiting for tool approval...'
          : 'Awaiting approval ($name)...';
    }
    return name.isEmpty ? '等待确认工具操作...' : '等待确认 $name 上的工具操作...';
  }

  String translateFailed(Object e) {
    return isEn ? 'Request failed: $e' : '请求失败: $e';
  }
}
