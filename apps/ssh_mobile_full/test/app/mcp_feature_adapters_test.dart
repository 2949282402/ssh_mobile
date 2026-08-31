// Full App MCP feature adapter coverage.
//
// The MCP adapters are pure wiring between AppSettings/AppLogService/AI tool
// executors and the feature_mcp public contracts. Fakes record the delegate
// calls so assertion stays on the observable boundary without platform I/O.

import 'package:feature_ai/feature_ai.dart' as ai;
import 'package:feature_mcp/feature_mcp.dart' as mcp;
import 'package:connection_core/connection_core.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/app/mcp_feature_adapters.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    AppLogService.instance.clear();
  });

  tearDown(() {
    AppLogService.instance.clear();
  });

  test(
    'settings adapter forwards state, writes, and listener notifications',
    () async {
      final settings = AppSettings();
      final adapter = AppMcpSettingsAdapter(settings);
      var notifications = 0;
      adapter.addListener(() => notifications++);

      expect(adapter.mcpSettings.enabled, isFalse);
      expect(adapter.isEnglish, isFalse);

      await adapter.ensureCoreLoaded();
      await adapter.setMcpServerEnabled(true);
      expect(adapter.mcpSettings.enabled, isTrue);
      expect(adapter.mcpSettings.hasToken, isTrue);

      await adapter.setMcpServerPort(43210);
      expect(settings.mcpServerPort, 43210);

      await adapter.setMcpApprovalMode(mcp.McpApprovalMode.trustedAgent);
      expect(settings.mcpApprovalMode, mcp.McpApprovalMode.trustedAgent);

      await adapter.setMcpToolSecondaryReview('ssh_execute', true);
      expect(settings.mcpSecondaryReviewTools, contains('ssh_execute'));
      await adapter.setMcpSecondaryReviewTools(const <String>{'sftp_read'});
      expect(settings.mcpSecondaryReviewTools, <String>{'sftp_read'});

      await adapter.setMcpToolExposure(
        'get_server_status',
        true,
        availableToolNames: const <String>{'get_server_status'},
      );
      expect(settings.mcpExposedTools, contains('get_server_status'));

      final regenerated = await adapter.regenerateMcpServerToken();
      expect(regenerated, isNotEmpty);
      expect(settings.mcpServerToken, regenerated);
      expect(await adapter.ensureMcpServerToken(), regenerated);
      expect(notifications, greaterThan(0));

      adapter.dispose();
      final before = notifications;
      await settings.setMcpServerPort(44000);
      expect(notifications, before);
      settings.dispose();
    },
  );

  test('settings adapter never forwards notifications after dispose', () {
    final settings = AppSettings();
    final adapter = AppMcpSettingsAdapter(settings);
    var notifications = 0;
    adapter.addListener(() => notifications++);

    adapter.dispose();
    settings.notifyListeners();

    expect(notifications, 0);
    settings.dispose();
  });

  test('logger adapter sends info, warning, and error to the App log', () {
    final adapter = AppMcpLoggerAdapter(AppLogService.instance);

    adapter.info('mcp-info', details: 'info-details');
    adapter.warning('mcp-warning', details: 'warning-details');
    final stackTrace = StackTrace.current;
    adapter.error(
      'mcp-error',
      error: StateError('mcp-error-state'),
      stackTrace: stackTrace,
      details: 'error-details',
    );

    final entry = AppLogService.instance.entries.first;
    expect(entry.text, contains('mcp-error'));
    expect(
      AppLogService.instance.entries.any(
        (item) =>
            item.normalizedLevel == AppLogLevel.warning &&
            item.text.contains('mcp-warning'),
      ),
      isTrue,
    );
    expect(
      AppLogService.instance.entries.any(
        (item) =>
            item.normalizedLevel == AppLogLevel.info &&
            item.text.contains('mcp-info'),
      ),
      isTrue,
    );
    expect(entry.details, contains('error-details'));
  });

  test('tool runtime adapter lazily creates executors from the factory', () {
    final expected = _McpExecutorStub();
    final adapter = AppMcpToolRuntimeAdapter(() => expected);

    expect(adapter.createToolExecutor(), same(expected));
  });

  test('tool executor adapter maps tools, modes, and capabilities', () async {
    final delegate = _FullExecutorStub();
    final adapter = AppAiToolExecutorAdapter(delegate);

    final tools = await adapter.tools();
    expect(tools, hasLength(1));
    final tool = tools.single;
    expect(tool.name, 'gate_tool');
    expect(tool.description, 'A tool for all boundaries.');
    expect(tool.properties, <String, dynamic>{
      'id': <String, dynamic>{'type': 'string'},
    });
    expect(tool.required, <String>['id']);
    expect(tool.executionMode, mcp.McpToolExecutionMode.planControl);
    expect(tool.capabilities, mcp.McpToolCapability.values.toSet());
    expect(tool.requiresServerSelection, isTrue);
    expect(tool.requiresWebViewSession, isTrue);

    expect(await adapter.toolDefinitions(), <Map<String, dynamic>>[
      <String, dynamic>{'name': 'definition'},
    ]);
  });

  test('tool executor adapter forwards approvals and execution', () async {
    final delegate = _FullExecutorStub();
    final adapter = AppAiToolExecutorAdapter(delegate);

    final mcpRequest = await adapter.approvalRequestFor(
      'gate_tool',
      const <String, dynamic>{},
    );
    expect(mcpRequest, isNotNull);
    expect(mcpRequest!.toolName, 'gate_tool');
    expect(mcpRequest.opaqueHandle, isA<ai.AiToolApprovalRequest>());

    final external = await adapter.mcpApprovalRequestFor(
      'gate_tool',
      const <String, dynamic>{},
    );
    expect(external!.opaqueHandle, isA<ai.AiToolApprovalRequest>());
    expect(external.contentPreview, 'mcp preview');

    final current = await adapter.isApprovalTargetCurrent(mcpRequest);
    expect(current, isTrue);
    expect(
      await adapter.executeApproved(mcpRequest, const <String, dynamic>{
        'id': 'x',
      }),
      'approved-ok',
    );
    expect(
      await adapter.execute('gate_tool', const <String, dynamic>{
        'id': 'y',
      }, approvedWrite: true),
      'executed',
    );
  });

  test('tool executor adapter fails closed for plain delegates', () async {
    final delegate = _PlainExecutorStub();
    final adapter = AppAiToolExecutorAdapter(delegate);

    expect(adapter.hasChatSession, isFalse);
    expect(
      await adapter.mcpApprovalRequestFor('tool', const <String, dynamic>{}),
      isNull,
    );
    await expectLater(
      adapter.isApprovalTargetCurrent(
        mcp.McpApprovalRequest(
          toolName: 'tool',
          approvalType: 'read',
          connectionId: 'c',
          connectionName: 'C',
          command: 'cmd',
          reason: 'r',
          opaqueHandle: delegate.bindingHandle,
        ),
      ),
      completion(isFalse),
    );
    final result = await adapter.executeApproved(
      mcp.McpApprovalRequest(
        toolName: 'tool',
        approvalType: 'read',
        connectionId: 'c',
        connectionName: 'C',
        command: 'cmd',
        reason: 'r',
      ),
      const <String, dynamic>{},
    );
    expect(result, contains('approval_target_guard_unavailable'));
  });

  test(
    'tool executor adapter reports missing original approval bindings',
    () async {
      final delegate = _GuardedExecutorStub();
      final adapter = AppAiToolExecutorAdapter(delegate);
      final external = mcp.McpApprovalRequest(
        toolName: 'tool',
        approvalType: 'read',
        connectionId: 'c',
        connectionName: 'C',
        command: 'cmd',
        reason: 'r',
        opaqueHandle: delegate.approval,
      );

      expect(await adapter.isApprovalTargetCurrent(external), isTrue);
      expect(
        await adapter.executeApproved(external, const <String, dynamic>{}),
        'guarded-ok',
      );

      final detached = mcp.McpApprovalRequest(
        toolName: 'tool',
        approvalType: 'read',
        connectionId: 'c',
        connectionName: 'C',
        command: 'cmd',
        reason: 'r',
      );
      expect(await adapter.isApprovalTargetCurrent(detached), isFalse);
      expect(
        await adapter.executeApproved(detached, const <String, dynamic>{}),
        contains('approval_target_binding_unavailable'),
      );
    },
  );
}

final class _McpExecutorStub implements mcp.McpToolExecutor {
  @override
  Future<List<mcp.McpTool>> tools() async => const <mcp.McpTool>[];

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async =>
      const <Map<String, dynamic>>[];

  @override
  Future<mcp.McpApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async => null;

  @override
  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async => 'ok';
}

final class _PlainExecutorStub implements ai.AiToolExecutor {
  final Object bindingHandle = Object();

  @override
  Future<ai.AiToolApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async => null;

  @override
  Future<List<ai.AiTool>> tools() async => const <ai.AiTool>[];

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async =>
      const <Map<String, dynamic>>[];

  @override
  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async => 'ok';

  @override
  ai.AiCommandReview reviewCommand(
    String command, {
    ServerPlatform? platform,
  }) => ai.AiCommandReview.readOnly();
}

final class _GuardedExecutorStub
    implements ai.AiToolExecutor, ai.AiToolApprovalTargetGuard {
  final ai.AiToolApprovalRequest approval = const ai.AiToolApprovalRequest(
    toolName: 'tool',
    approvalType: 'read',
    connectionId: 'c',
    connectionName: 'C',
    command: 'cmd',
    reason: 'r',
  );

  @override
  Future<bool> isApprovalTargetCurrent(
    ai.AiToolApprovalRequest request,
  ) async => request == approval;

  @override
  Future<String> executeApproved(
    ai.AiToolApprovalRequest request,
    Map<String, dynamic> arguments,
  ) async => 'guarded-ok';

  @override
  Future<ai.AiToolApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async => null;

  @override
  Future<List<ai.AiTool>> tools() async => const <ai.AiTool>[];

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async =>
      const <Map<String, dynamic>>[];

  @override
  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async => 'ok';

  @override
  ai.AiCommandReview reviewCommand(
    String command, {
    ServerPlatform? platform,
  }) => ai.AiCommandReview.readOnly();
}

final class _FullExecutorStub
    implements
        ai.AiToolExecutor,
        ai.AiToolApprovalTargetGuard,
        ai.McpApprovalRequestProvider {
  ai.AiToolApprovalRequest? lastApproved;
  final ai.AiToolApprovalRequest approval = const ai.AiToolApprovalRequest(
    toolName: 'gate_tool',
    approvalType: 'remote_write',
    connectionId: 'server-a',
    connectionName: 'Server A',
    command: 'reboot',
    reason: 'test approval',
    targetPath: '/etc/hosts',
    byteLength: 12,
    contentPreview: 'hosts file',
    destructive: true,
  );

  @override
  Future<ai.AiToolApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async => approval;

  @override
  Future<List<ai.AiTool>> tools() async => <ai.AiTool>[
    ai.AiTool(
      name: 'gate_tool',
      description: 'A tool for all boundaries.',
      properties: <String, dynamic>{
        'id': <String, dynamic>{'type': 'string'},
      },
      required: <String>['id'],
      executionMode: ai.AiToolExecutionMode.planControl,
      capabilities: ai.AiToolCapability.values.toSet(),
      requiresServerSelection: true,
      requiresWebViewSession: true,
      handler: _noopHandler,
    ),
  ];

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async =>
      const <Map<String, dynamic>>[
        <String, dynamic>{'name': 'definition'},
      ];

  @override
  Future<ai.AiToolApprovalRequest?> mcpApprovalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async => const ai.AiToolApprovalRequest(
    toolName: 'gate_tool',
    approvalType: 'remote_write',
    connectionId: 'server-b',
    connectionName: 'Server B',
    command: 'restart',
    reason: 'external mcp',
    contentPreview: 'mcp preview',
  );

  @override
  Future<bool> isApprovalTargetCurrent(
    ai.AiToolApprovalRequest request,
  ) async => true;

  @override
  Future<String> executeApproved(
    ai.AiToolApprovalRequest request,
    Map<String, dynamic> arguments,
  ) async {
    lastApproved = request;
    return 'approved-ok';
  }

  @override
  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async => 'executed';

  @override
  ai.AiCommandReview reviewCommand(
    String command, {
    ServerPlatform? platform,
  }) => ai.AiCommandReview.readOnly();
}

Future<String> _noopHandler(Map<String, dynamic> arguments) async => '';
