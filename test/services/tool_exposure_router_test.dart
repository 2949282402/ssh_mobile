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
  });
}
