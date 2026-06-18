import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/tool_exposure_router.dart';

Future<String> _noop(Map<String, dynamic> _) async => '{}';

void main() {
  group('ToolExposureRouter', () {
    test('filters by webview session and approved plan state', () {
      const router = ToolExposureRouter();
      final tools = [
        AiTool(
          name: 'client_webview_get_state',
          description: 'Read webview state',
          properties: const {},
          requiresWebViewSession: true,
          capabilities: const {AiToolCapability.web},
          handler: _noop,
        ),
        AiTool(
          name: 'client_task_update',
          description: 'Update approved plan step',
          properties: const {},
          executionMode: AiToolExecutionMode.executionOnly,
          capabilities: const {AiToolCapability.planning},
          handler: _noop,
        ),
      ];

      final noContext = router.selectTools(
        tools,
        context: const ToolExposureContext(
          userRequest: 'show the current web page and update the task',
        ),
      );
      final withContext = router.selectTools(
        tools,
        context: const ToolExposureContext(
          userRequest: 'show the current web page and update the task',
          hasWebViewSession: true,
          hasApprovedPlan: true,
        ),
      );

      expect(noContext.selectedToolSet, isEmpty);
      expect(
        withContext.selectedToolSet,
        containsAll(['client_webview_get_state', 'client_task_update']),
      );
    });

    test('narrows tool exposure to relevant capabilities', () {
      const router = ToolExposureRouter();
      final tools = [
        AiTool(
          name: 'web_search',
          description: 'Search the web',
          properties: const {},
          capabilities: const {AiToolCapability.web},
          handler: _noop,
        ),
        AiTool(
          name: 'run_command',
          description: 'Run server command',
          properties: const {},
          requiresServerSelection: true,
          capabilities: const {AiToolCapability.server, AiToolCapability.ssh},
          handler: _noop,
        ),
        AiTool(
          name: 'list_servers',
          description: 'List saved servers',
          properties: const {},
          capabilities: const {AiToolCapability.server},
          handler: _noop,
        ),
      ];

      final selection = router.selectTools(
        tools,
        context: const ToolExposureContext(
          userRequest: 'search the latest nginx release notes on the web',
          hasWebViewSession: true,
        ),
      );

      expect(selection.selectedToolSet, contains('web_search'));
      expect(selection.selectedToolSet, contains('list_servers'));
      expect(selection.selectedToolSet, isNot(contains('run_command')));
    });

    test('keeps server tools when a server is already selected', () {
      const router = ToolExposureRouter();
      final tools = [
        AiTool(
          name: 'run_command',
          description: 'Run server command',
          properties: const {},
          requiresServerSelection: true,
          capabilities: const {AiToolCapability.server, AiToolCapability.ssh},
          handler: _noop,
        ),
      ];

      final selection = router.selectTools(
        tools,
        context: const ToolExposureContext(
          userRequest: 'check disk usage',
          selectedConnectionIds: {'server-1'},
        ),
      );

      expect(selection.selectedToolSet, contains('run_command'));
    });

    test('keeps saved playbook tools out of ordinary execution planning', () {
      const router = ToolExposureRouter();
      final tools = [
        AiTool(
          name: 'list_playbooks',
          description: 'List saved playbooks',
          properties: const {},
          handler: _noop,
        ),
        AiTool(
          name: 'create_playbook',
          description: 'Create saved playbook',
          properties: const {},
          executionMode: AiToolExecutionMode.stateChanging,
          handler: _noop,
        ),
      ];

      final normalPlan = router.selectTools(
        tools,
        context: const ToolExposureContext(
          userRequest: '请给我一个执行计划来排查 nginx 服务',
        ),
      );
      final explicitSave = router.selectTools(
        tools,
        context: const ToolExposureContext(
          userRequest: '请保存这次运维脚本，做成可复用 playbook',
        ),
      );

      expect(normalPlan.selectedToolSet, isNot(contains('list_playbooks')));
      expect(normalPlan.selectedToolSet, isNot(contains('create_playbook')));
      expect(explicitSave.selectedToolSet, contains('list_playbooks'));
      expect(explicitSave.selectedToolSet, contains('create_playbook'));
    });

    test(
        'contains explainable decisions showing why tools were selected or blocked',
        () {
      const router = ToolExposureRouter();
      final tools = [
        AiTool(
          name: 'client_webview_get_state',
          description: 'Read webview state',
          properties: const {},
          requiresWebViewSession: true,
          capabilities: const {AiToolCapability.web},
          handler: _noop,
        ),
        AiTool(
          name: 'client_task_update',
          description: 'Update approved plan step',
          properties: const {},
          executionMode: AiToolExecutionMode.executionOnly,
          capabilities: const {AiToolCapability.planning},
          handler: _noop,
        ),
      ];

      final selection = router.selectTools(
        tools,
        context: const ToolExposureContext(
          userRequest: 'show the current web page and update the task',
        ),
      );

      expect(selection.decisions, hasLength(2));

      final webviewDecision = selection.decisions
          .firstWhere((d) => d.toolName == 'client_webview_get_state');
      expect(webviewDecision.selected, isFalse);
      expect(webviewDecision.blockedBy, contains('webview_session_missing'));

      final taskUpdateDecision = selection.decisions
          .firstWhere((d) => d.toolName == 'client_task_update');
      expect(taskUpdateDecision.selected, isFalse);
      expect(taskUpdateDecision.blockedBy,
          contains('execution_only_without_approved_plan'));
    });
  });
}
