import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/ai_chat/services/ai_chat_status_translator.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/features/ai_chat/services/llm_chat_service.dart';

void main() {
  group('AiChatStatusTranslator Chinese Tests', () {
    const translator = AiChatStatusTranslator(AppLanguage.zh);

    test('translateStatus translates correctly', () {
      expect(
        translator.translateStatus(AgentStatusString.preparing),
        '模型正在准备回答...',
      );
      expect(
        translator.translateStatus(AgentStatusString.thinking),
        '模型正在思考...',
      );
      expect(
        translator.translateStatus(AgentStatusString.responding),
        '正在输出回答...',
      );
      expect(
        translator.translateStatus(AgentStatusString.processingToolResult),
        '正在处理工具结果...',
      );
      expect(
        translator.translateStatus(AgentStatusString.processingApproval),
        '正在处理审批结果...',
      );
      expect(
        translator.translateStatus(AgentStatusString.collaborating),
        '正在协调多 Agent 协作...',
      );
      expect(translator.translateStatus(AgentStatusString.stopped), '输出已停止。');
    });

    test('translateTrace translates correctly', () {
      expect(
        translator.translateTrace(
          LlmTraceEvent(kind: 'reasoning', title: '', content: ''),
        ),
        '模型正在思考...',
      );
      expect(
        translator.translateTrace(
          LlmTraceEvent(kind: 'tool_request', title: 'Call: ls', content: ''),
        ),
        '正在调用工具：ls',
      );
      expect(
        translator.translateTrace(
          LlmTraceEvent(kind: 'tool_result', title: '', content: ''),
        ),
        '正在处理工具结果...',
      );
      expect(
        translator.translateTrace(
          LlmTraceEvent(kind: 'approval', title: '', content: ''),
        ),
        '正在处理审批结果...',
      );
      expect(
        translator.translateTrace(
          LlmTraceEvent(kind: 'multi_agent', title: '', content: ''),
        ),
        '正在协调多 Agent 协作...',
      );
    });

    test('translateTrace budget translations', () {
      expect(
        translator.translateTrace(
          LlmTraceEvent(
            kind: 'budget',
            title: 'Running safety check',
            content: '',
          ),
        ),
        '继续前正在审计工具调用...',
      );
      expect(
        translator.translateTrace(
          LlmTraceEvent(
            kind: 'budget',
            title: 'Safety check rejected',
            content: '',
          ),
        ),
        '安全审计后已停止继续调用工具...',
      );
      expect(
        translator.translateTrace(
          LlmTraceEvent(kind: 'budget', title: 'Extended info', content: ''),
        ),
        '工具预算已扩展，请留意工具调用是否合理...',
      );
    });

    test('translateToolName extracts correctly', () {
      expect(translator.translateToolName('Call: run_command'), 'run_command');
      expect(translator.translateToolName('run_command'), 'run_command');
    });

    test('translateRunningTool handles blank or names', () {
      expect(translator.translateRunningTool(''), '正在调用工具...');
      expect(translator.translateRunningTool('grep'), '正在调用工具：grep');
    });

    test('translateAwaitingApproval handles blank or names', () {
      expect(translator.translateAwaitingApproval(''), '等待确认工具操作...');
      expect(
        translator.translateAwaitingApproval('prod-server'),
        '等待确认 prod-server 上的工具操作...',
      );
    });

    test('translateFailed translates correctly', () {
      expect(translator.translateFailed('Timeout'), '请求失败: Timeout');
    });
  });

  group('AiChatStatusTranslator English Tests', () {
    const translator = AiChatStatusTranslator(AppLanguage.en);

    test('translateStatus translates correctly', () {
      expect(
        translator.translateStatus(AgentStatusString.preparing),
        'Preparing...',
      );
      expect(
        translator.translateStatus(AgentStatusString.thinking),
        'Thinking...',
      );
      expect(
        translator.translateStatus(AgentStatusString.responding),
        'Responding...',
      );
      expect(
        translator.translateStatus(AgentStatusString.processingToolResult),
        'Processing result...',
      );
      expect(
        translator.translateStatus(AgentStatusString.processingApproval),
        'Processing approval...',
      );
      expect(
        translator.translateStatus(AgentStatusString.collaborating),
        'Collaborating...',
      );
      expect(translator.translateStatus(AgentStatusString.stopped), 'Stopped.');
    });

    test('translateTrace translates budget correctly', () {
      expect(
        translator.translateTrace(
          LlmTraceEvent(
            kind: 'budget',
            title: 'Running safety check',
            content: '',
          ),
        ),
        'Auditing tool...',
      );
      expect(
        translator.translateTrace(
          LlmTraceEvent(
            kind: 'budget',
            title: 'Safety check rejected',
            content: '',
          ),
        ),
        'Tool blocked by audit.',
      );
      expect(
        translator.translateTrace(
          LlmTraceEvent(kind: 'budget', title: 'Extended info', content: ''),
        ),
        'Budget extended.',
      );
    });
  });
}
