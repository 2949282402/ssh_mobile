part of 'ai_tool_service_test.dart';

void _registerAiToolCoreTests() {
  test('allows Linux read-only diagnostics', () {
    final review = tools.reviewCommand('df -h', platform: ServerPlatform.linux);

    expect(review.blocked, isFalse);
    expect(review.requiresApproval, isFalse);
  });

  test('read-only command names require an exact token boundary', () {
    for (final command in [
      'lswhatever',
      'freezer',
      'pwdx',
      'topical',
      'unamex',
      'uptimectl',
      'whoamix',
      'ls\u2028whatever',
    ]) {
      final review = tools.reviewCommand(
        command,
        platform: ServerPlatform.linux,
      );
      expect(review.blocked, isFalse, reason: command);
      expect(review.requiresApproval, isTrue, reason: command);
    }

    for (final command in [
      'cmd /c dirx',
      'cmd /c echoes',
      'cmd /c tasklistx',
      'cmd /c whoamix',
    ]) {
      final review = tools.reviewCommand(
        command,
        platform: ServerPlatform.windows,
      );
      expect(review.blocked, isFalse, reason: command);
      expect(review.requiresApproval, isTrue, reason: command);
    }

    expect(
      tools
          .reviewCommand('ls -la', platform: ServerPlatform.linux)
          .requiresApproval,
      isFalse,
    );
    expect(
      tools
          .reviewCommand('cmd /c dir /b', platform: ServerPlatform.windows)
          .requiresApproval,
      isFalse,
    );
  });

  test('PowerShell diagnostics use cmdlet and pipeline allowlists', () {
    for (final command in [
      'powershell -NoProfile -Command Get-Process',
      'pwsh Get-Service | Select-Object Name | ConvertTo-Json',
      r'powershell $PSVersionTable.PSVersion',
    ]) {
      final review = tools.reviewCommand(
        command,
        platform: ServerPlatform.windows,
      );
      expect(review.blocked, isFalse, reason: command);
      expect(review.requiresApproval, isFalse, reason: command);
    }

    for (final command in [
      'powershell -EncodedCommand ZABhAG4AZwBlAHI=',
      r'powershell -File C:\Temp\script.ps1',
      r'powershell -Command Set-Content C:\Temp\owned.txt owned',
      r'powershell -Command Get-Process | Tee-Object C:\Temp\owned.txt',
      r'''powershell -Command "Get-Process; Set-Content C:\Temp\owned.txt owned"''',
      'powershell Get-Process\u2028Set-Content C:\\Temp\\owned.txt owned',
      'powershell Get-ChildItem',
    ]) {
      final review = tools.reviewCommand(
        command,
        platform: ServerPlatform.windows,
      );
      expect(review.blocked, isFalse, reason: command);
      expect(review.requiresApproval, isTrue, reason: command);
    }
  });

  test('requires approval for Linux command chaining', () {
    final review = tools.reviewCommand(
      'cat /etc/os-release | grep PRETTY',
      platform: ServerPlatform.linux,
    );

    expect(review.blocked, isFalse);
    expect(review.requiresApproval, isTrue);
  });

  test('requires approval for shell redirection and command substitution', () {
    final cases = <({String command, ServerPlatform platform})>[
      (
        command: 'cat /etc/os-release > /tmp/ai-owned',
        platform: ServerPlatform.linux,
      ),
      (command: r'ls $(touch /tmp/ai-owned)', platform: ServerPlatform.linux),
      (command: 'ls `touch /tmp/ai-owned`', platform: ServerPlatform.linux),
      (
        command: r'cmd /c echo owned > C:\Temp\ai-owned.txt',
        platform: ServerPlatform.windows,
      ),
      (
        command: r'powershell Get-Process | Tee-Object C:\Temp\processes.txt',
        platform: ServerPlatform.windows,
      ),
    ];

    for (final item in cases) {
      final review = tools.reviewCommand(item.command, platform: item.platform);

      expect(review.blocked, isFalse, reason: item.command);
      expect(review.requiresApproval, isTrue, reason: item.command);
    }
  });

  test('run_command approval requests cover shell-control syntax', () async {
    for (final command in [
      'cat /etc/os-release > /tmp/ai-owned',
      r'ls $(touch /tmp/ai-owned)',
      'ls `touch /tmp/ai-owned`',
    ]) {
      final request = await tools.approvalRequestFor('run_command', {
        'connectionId': 'server-1',
        'command': command,
      });

      expect(request, isNotNull, reason: command);
      expect(request?.approvalType, 'remote_write', reason: command);
    }
  });

  test('known-safe reads require every file operand to be safe', () {
    final safe = tools.reviewCommand(
      'cat /etc/os-release',
      platform: ServerPlatform.linux,
    );
    final mixed = tools.reviewCommand(
      'cat /etc/os-release /home/app/config.yml',
      platform: ServerPlatform.linux,
    );
    final windowsFileRead = tools.reviewCommand(
      r'cmd /c type C:\Users\demo\config.txt',
      platform: ServerPlatform.windows,
    );

    expect(safe.requiresApproval, isFalse);
    expect(mixed.blocked, isFalse);
    expect(mixed.requiresApproval, isTrue);
    expect(windowsFileRead.blocked, isFalse);
    expect(windowsFileRead.requiresApproval, isTrue);
  });

  test('remote approval binding changes with connection target', () async {
    final request = await tools.approvalRequestFor('sftp_write_text', {
      'connectionId': 'server-1',
      'path': '/tmp/example.txt',
      'content': 'hello',
    });
    expect(request, isNotNull);

    expect(request!.executionBinding?.connectionTargets, contains('server-1'));
    expect(await tools.isApprovalTargetCurrent(request), isTrue);

    final current = storage.getConnection('server-1')!;
    await storage.updateConnection(
      current.copyWith(host: 'replacement.example.com', port: 2222),
    );

    expect(await tools.isApprovalTargetCurrent(request), isFalse);
  });

  test(
    'MCP-only approval metadata does not change built-in Agent approval',
    () async {
      expect(
        await tools.approvalRequestFor('app_clear_secret_cache', const {}),
        isNull,
      );

      final mcpProvider = tools as McpApprovalRequestProvider;
      final request = await mcpProvider.mcpApprovalRequestFor(
        'app_clear_secret_cache',
        const {},
      );
      expect(request, isNotNull);
      expect(request!.approvalType, 'local_app_change');
      expect(request.executionBinding, isNotNull);
    },
  );

  test('read-only remote tool cannot drift outside the turn target', () async {
    final original = storage.getConnection('server-1')!;
    tools.bindConnectionTargets({
      original.id: ssh_core.SshTargetBinding.fromConfig(original),
    });
    await storage.updateConnection(
      original.copyWith(host: 'replacement.example.com', port: 2222),
    );

    final result =
        jsonDecode(
              await tools.execute('get_server_details', {
                'connectionId': original.id,
              }),
            )
            as Map<String, dynamic>;

    expect(result['code'], 'approval_target_changed');
    expect(serverCatalog.lastDetailsConnectionId, isNull);
  });

  test(
    'approved execution revalidates at the remote side-effect edge',
    () async {
      final provider = _GatedRemoteProvider();
      final guardedTools = createAiToolServiceFromLegacy(
        providers: [provider],
        storageService: storage,
        sshService: ssh,
        sftpService: sftp,
      );
      final original = storage.getConnection('server-1')!;
      final binding = ssh_core.SshTargetBinding.fromConfig(original);
      guardedTools.bindConnectionTargets({original.id: binding});
      final request = AiToolApprovalRequest(
        toolName: _GatedRemoteProvider.toolName,
        approvalType: 'remote_write',
        connectionId: original.id,
        connectionName: original.name,
        command: 'GATED WRITE',
        reason: 'test',
        executionBinding: AiToolApprovalExecutionBinding(
          connectionTargets: {original.id: binding},
        ),
      );

      final execution = guardedTools.executeApproved(request, {
        'connectionId': original.id,
      });
      await provider.started.future;
      await storage.updateConnection(
        original.copyWith(host: 'replacement.example.com', port: 2222),
      );
      provider.release.complete();

      final result = jsonDecode(await execution) as Map<String, dynamic>;
      expect(result['code'], 'approval_target_changed');
      expect(provider.sideEffectCount, 0);
    },
  );

  test('monitor start approval binds the exact selected target set', () async {
    performanceMonitor.selectedConnectionIds = ['server-1'];
    final request = await tools.approvalRequestFor('monitor_start', {});

    expect(request, isNotNull);
    expect(
      request!.executionBinding?.connectionTargets.keys,
      contains('server-1'),
    );
    expect(request.contentPreview, contains('Demo Server'));
    expect(await tools.isApprovalTargetCurrent(request), isTrue);

    performanceMonitor.selectedConnectionIds = [];
    expect(await tools.isApprovalTargetCurrent(request), isFalse);
  });

  test('monitor start with no selected target fails closed', () async {
    performanceMonitor.selectedConnectionIds = [];

    final request = await tools.approvalRequestFor('monitor_start', {});

    expect(request, isNotNull);
    expect(request!.executionBinding?.connectionTargets, isEmpty);
    expect(await tools.isApprovalTargetCurrent(request), isFalse);
    final result =
        jsonDecode(await tools.executeApproved(request, {}))
            as Map<String, dynamic>;
    expect(result['code'], 'approval_target_changed');
    expect(performanceMonitor.startCalls, 0);
  });

  test(
    'monitor start fails closed when a selected target is missing',
    () async {
      performanceMonitor.selectedConnectionIds = ['server-1'];
      await storage.deleteConnection('server-1');

      final request = await tools.approvalRequestFor('monitor_start', {});

      expect(request, isNotNull);
      expect(request!.executionBinding?.connectionTargets, isEmpty);
      expect(await tools.isApprovalTargetCurrent(request), isFalse);
      final result =
          jsonDecode(await tools.executeApproved(request, {}))
              as Map<String, dynamic>;
      expect(result['code'], 'approval_target_changed');
      expect(performanceMonitor.startCalls, 0);
    },
  );

  test('blocks delete-style commands on all platforms', () {
    final linux = tools.reviewCommand(
      'rm -rf /tmp/demo',
      platform: ServerPlatform.linux,
    );
    final windows = tools.reviewCommand(
      'powershell Remove-Item C:\\temp\\demo -Recurse',
      platform: ServerPlatform.windows,
    );

    expect(linux.blocked, isTrue);
    expect(windows.blocked, isTrue);
  });

  test('blocks environment dumps through run_command secret policy', () {
    final review = tools.reviewCommand(
      'printenv',
      platform: ServerPlatform.linux,
    );

    expect(review.blocked, isTrue);
    expect(review.reason, contains('Environment variable dumps'));
  });

  test('blocks sensitive server file reads through run_command policy', () {
    final privateKey = tools.reviewCommand(
      'cat ~/.ssh/id_rsa',
      platform: ServerPlatform.linux,
    );
    final shadow = tools.reviewCommand(
      'cat /etc/shadow',
      platform: ServerPlatform.linux,
    );
    final grepEnv = tools.reviewCommand(
      'grep token .env',
      platform: ServerPlatform.linux,
    );

    expect(privateKey.blocked, isTrue);
    expect(shadow.blocked, isTrue);
    expect(grepEnv.blocked, isTrue);
  });

  test('requires approval for server log reads', () {
    final review = tools.reviewCommand(
      'journalctl -u ssh',
      platform: ServerPlatform.linux,
    );

    expect(review.blocked, isFalse);
    expect(review.requiresApproval, isTrue);
    expect(review.reason, contains('logs'));
  });

  test('blocks cross-platform command mismatch', () {
    final review = tools.reviewCommand(
      'cmd /c dir',
      platform: ServerPlatform.linux,
    );

    expect(review.blocked, isTrue);
    expect(review.reason, contains('Windows command'));
  });

  test('requires explicit shell prefix for Windows commands', () {
    final review = tools.reviewCommand('dir', platform: ServerPlatform.windows);

    expect(review.blocked, isTrue);
    expect(review.reason, contains('explicit'));
  });

  test('exposes local web search by default', () async {
    final names = (await tools.tools()).map((tool) => tool.name);

    expect(names, contains('web_search'));
  });

  test('web search tool definition embeds configured result limit', () async {
    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'demo-model',
      webSearchMaxResults: 8,
    );

    final definitions = await tools.toolDefinitions();
    final webSearch = definitions.firstWhere(
      (definition) =>
          (definition['function'] as Map<String, dynamic>)['name'] ==
          'web_search',
    );
    final function = webSearch['function'] as Map<String, dynamic>;
    final parameters = function['parameters'] as Map<String, dynamic>;
    final properties = parameters['properties'] as Map<String, dynamic>;
    final limit = properties['limit'] as Map<String, dynamic>;

    expect(function['description'], contains('8 results'));
    expect(limit['default'], 8);
    expect(limit['maximum'], 8);
    expect(limit['minimum'], 1);
    expect(limit['description'], contains('8 results'));
  });

  test(
    'OpenAI strict tool definition strips unsupported schema keywords',
    () async {
      final settings = (await storage.loadAiConnectionSettings()).copyWith(
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-4o-2024-08-06',
      );
      final tool = AiTool(
        name: 'demo_tool',
        description: 'Demo tool',
        properties: {
          'limit': {
            'type': 'integer',
            'description': 'Optional limit.',
            'minimum': 1,
            'maximum': 10,
            'default': 5,
          },
          'tags': {
            'type': 'array',
            'description': 'Optional tags.',
            'items': {'type': 'string', 'minLength': 2},
            'minItems': 1,
          },
          'mode': {
            'type': 'string',
            'description': 'Required mode.',
            'enum': ['fast', 'safe'],
          },
        },
        required: const ['mode'],
        handler: (args) async => '{}',
      );

      final definition = tool.definitionFor(settings);
      final function = definition['function'] as Map<String, dynamic>;
      final parameters = function['parameters'] as Map<String, dynamic>;
      final properties = parameters['properties'] as Map<String, dynamic>;
      final limit = properties['limit'] as Map<String, dynamic>;
      final tags = properties['tags'] as Map<String, dynamic>;
      final tagItems = tags['items'] as Map<String, dynamic>;
      final mode = properties['mode'] as Map<String, dynamic>;

      expect(function['strict'], isTrue);
      expect(parameters['required'], ['limit', 'tags', 'mode']);
      expect(limit.keys, isNot(contains('minimum')));
      expect(limit.keys, isNot(contains('maximum')));
      expect(limit.keys, isNot(contains('default')));
      expect(limit['type'], contains('null'));
      expect(tags.keys, isNot(contains('minItems')));
      expect(tagItems.keys, isNot(contains('minLength')));
      expect(tags['type'], contains('null'));
      expect(mode['type'], 'string');
      expect(mode['enum'], ['fast', 'safe']);
    },
  );

  test(
    'OpenAI strict tool definition is disabled for fine-tuned models',
    () async {
      final settings = (await storage.loadAiConnectionSettings()).copyWith(
        baseUrl: 'https://api.openai.com/v1',
        model: 'ft:gpt-4o-mini:org:suffix:id',
      );
      final tool = AiTool(
        name: 'demo_tool',
        description: 'Demo tool',
        properties: {
          'limit': {
            'type': 'integer',
            'description': 'Optional limit.',
            'minimum': 1,
          },
        },
        handler: (args) async => '{}',
      );

      final definition = tool.definitionFor(settings);
      final function = definition['function'] as Map<String, dynamic>;
      final parameters = function['parameters'] as Map<String, dynamic>;
      final properties = parameters['properties'] as Map<String, dynamic>;
      final limit = properties['limit'] as Map<String, dynamic>;

      expect(function.containsKey('strict'), isFalse);
      expect(limit['minimum'], 1);
    },
  );

  test('hides local web search when disabled by the user', () async {
    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'demo-model',
      webSearchEnabled: false,
    );

    final names = (await tools.tools()).map((tool) => tool.name);

    expect(names, isNot(contains('web_search')));
  });

  test('local web search reports missing chat session', () async {
    final raw = await toolsWithoutChatSession.execute('web_search', {
      'query': 'flutter',
    });
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded['provider'], 'local_webview');
    expect(decoded['error'], contains('No current chat session'));
  });

  test('local web search payload identifies lightweight engine', () {
    final payload = const ClientWebViewSearchResult(
      chatId: 'chat-1',
      supported: true,
      query: 'flutter',
      results: [],
    ).toJson();

    expect(payload['provider'], 'local_webview');
    expect(payload['engine'], 'baidu_html');
  });

  test('defines the new client and sftp tools', () async {
    final definitions = await tools.toolDefinitions();
    final names = definitions
        .map(
          (definition) =>
              (definition['function'] as Map<String, dynamic>)['name']
                  as String,
        )
        .toList();

    expect(
      names,
      containsAll([
        'client_get_permission_status',
        'client_query_logs',
        'client_get_log_counts',
        'client_delete_log_entries',
        'client_clear_logs',
        'client_export_app_backup',
        'client_import_app_backup',
        'client_webview_get_state',
        'client_webview_navigate',
        'get_server_details',
        'update_server_metadata',
        'delete_server',
        'reorder_servers',
        'inspect_service_health',
        'collect_incident_context',
        'compare_server_states',
        'ssh_list_sessions',
        'sftp_download_file',
        'sftp_write_text',
        'sftp_upload_local_file',
        'sftp_create_directory',
        'sftp_rename_entry',
        'sftp_delete_entry',
        'get_server_status',
        'generate_ops_report',
        'monitor_get_state',
        'monitor_start',
        'app_get_operational_settings',
        'app_update_operational_settings',
        'app_clear_secret_cache',
      ]),
    );

    final queryLogs = definitions.firstWhere(
      (definition) =>
          (definition['function'] as Map<String, dynamic>)['name'] ==
          'client_query_logs',
    );
    final queryLogsParams =
        (queryLogs['function'] as Map<String, dynamic>)['parameters']
            as Map<String, dynamic>;
    final queryLogsProps =
        queryLogsParams['properties'] as Map<String, dynamic>;
    expect((queryLogsProps['limit'] as Map<String, dynamic>)['default'], 50);
    expect((queryLogsProps['limit'] as Map<String, dynamic>)['maximum'], 200);

    final navigate = definitions.firstWhere(
      (definition) =>
          (definition['function'] as Map<String, dynamic>)['name'] ==
          'client_webview_navigate',
    );
    final navigateParams =
        (navigate['function'] as Map<String, dynamic>)['parameters']
            as Map<String, dynamic>;
    final navigateProps = navigateParams['properties'] as Map<String, dynamic>;
    expect(navigateParams['required'], ['action']);
    expect((navigateProps['action'] as Map<String, dynamic>)['enum'], [
      'open',
      'back',
      'forward',
      'refresh',
    ]);
  });

  test(
    'update server metadata ignores strict-schema null optional fields',
    () async {
      final arguments = {
        'connectionId': 'server-1',
        'name': 'Renamed Server',
        'serverPlatform': null,
        'launchMode': null,
        'jumpHost': null,
        'jumpPort': null,
        'jumpUsername': null,
      };
      final approval = await tools.approvalRequestFor(
        'update_server_metadata',
        arguments,
      );
      final result = await tools.execute(
        'update_server_metadata',
        arguments,
        approvedWrite: true,
      );

      final decoded = jsonDecode(result) as Map<String, dynamic>;
      final changes = serverCatalog.lastMetadataChanges!;

      expect(approval?.command, 'UPDATE SERVER TARGET root@example.com:22');
      expect(
        approval?.contentPreview,
        contains('name: Demo Server -> Renamed Server'),
      );
      expect(decoded['updated'], isTrue);
      expect(changes, {'name': 'Renamed Server'});
      expect(changes.containsKey('serverPlatform'), isFalse);
      expect(changes.containsKey('launchMode'), isFalse);
    },
  );

  test('server metadata approval freezes the exact proposed target', () async {
    final arguments = <String, dynamic>{
      'connectionId': 'server-1',
      'host': 'approved.example.com',
      'port': 2222,
      'username': 'deploy',
    };
    final approval = await tools.approvalRequestFor(
      'update_server_metadata',
      arguments,
    );
    expect(approval, isNotNull);
    expect(
      approval!.contentPreview,
      contains('root@example.com:22 -> deploy@approved.example.com:2222'),
    );

    arguments['host'] = 'unreviewed.example.com';
    final decoded =
        jsonDecode(await tools.executeApproved(approval, arguments))
            as Map<String, dynamic>;

    expect(decoded['updated'], isTrue);
    expect(serverCatalog.lastMetadataChanges, isEmpty);
    expect(serverCatalog.lastApprovedCandidate?.host, 'approved.example.com');
    expect(serverCatalog.lastApprovedCandidate?.port, 2222);
    expect(serverCatalog.lastApprovedCandidate?.username, 'deploy');
  });

  test(
    'server metadata approval preserves concurrent non-target edits',
    () async {
      final approval = await tools.approvalRequestFor(
        'update_server_metadata',
        {'connectionId': 'server-1', 'host': 'approved.example.com'},
      );
      expect(approval, isNotNull);
      final current = storage.getConnection('server-1')!;
      await storage.updateConnection(current.copyWith(group: 'User edit'));

      expect(await tools.isApprovalTargetCurrent(approval!), isFalse);
      final decoded =
          jsonDecode(
                await tools.executeApproved(approval, {
                  'connectionId': 'server-1',
                  'host': 'approved.example.com',
                }),
              )
              as Map<String, dynamic>;

      expect(decoded['code'], 'approval_target_changed');
      expect(serverCatalog.lastApprovedCandidate, isNull);
      expect(storage.getConnection('server-1')!.group, 'User edit');
    },
  );

  test(
    'client permission tool delegates to the client system adapter',
    () async {
      final raw = await tools.execute('client_get_permission_status', {});
      final decoded = jsonDecode(raw) as Map<String, dynamic>;

      expect(decoded['execution'], 'client');
      expect(decoded['notificationGranted'], isTrue);
    },
  );

  test(
    'client runtime health tool exposes schema and blocking result',
    () async {
      final definitions = await tools.toolDefinitions();
      final names = definitions
          .map((definition) => (definition['function'] as Map)['name'])
          .toList();
      expect(names, contains('client_check_runtime_health'));

      clientSystem.networkInfo = {
        'execution': 'client',
        'target': 'client_device',
        'supported': true,
        'connected': true,
        'validated': false,
      };
      final raw = await tools.execute('client_check_runtime_health', {
        'profile': 'agent_execution',
      });
      final decoded = jsonDecode(raw) as Map<String, dynamic>;

      expect(decoded['status'], 'blocking');
      expect(decoded['canProceed'], isFalse);
      final issues = decoded['issues'] as List<dynamic>;
      expect(
        issues.map((issue) => (issue as Map)['code']),
        contains('network_not_validated'),
      );
      expect(decoded['raw'], isA<Map<String, dynamic>>());
    },
  );

  test('client log query uses default limit and passes filters', () async {
    final raw = await tools.execute('client_query_logs', {
      'level': 'warning',
      'contains': 'ssh',
    });
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(clientSystem.lastQueryLevel, 'warning');
    expect(clientSystem.lastQueryContains, 'ssh');
    expect(clientSystem.lastQueryLimit, 50);
    expect(decoded['limit'], 50);
  });

  test(
    'client log count tool delegates to the client system adapter',
    () async {
      final raw = await tools.execute('client_get_log_counts', {});
      final decoded = jsonDecode(raw) as Map<String, dynamic>;

      expect(clientSystem.getLogCountsCalled, isTrue);
      expect((decoded['counts'] as Map<String, dynamic>)['warning'], 2);
    },
  );

  test('webview state tool requires a bound chat session', () async {
    final raw = await toolsWithoutChatSession.execute(
      'client_webview_get_state',
      {},
    );
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded['error'], contains('No current chat session'));
  });

  test('webview state tool returns current session state', () async {
    clientWebView.state = ClientWebViewStateSnapshot(
      chatId: 'chat-1',
      supported: true,
      hasPage: true,
      url: 'https://example.com',
      title: 'Example',
      progress: 100,
      isLoading: false,
      isAiBrowsing: false,
      canGoBack: true,
      canGoForward: false,
      lastTextLength: 120,
      lastTextTruncated: false,
    );

    final raw = await tools.execute('client_webview_get_state', {});
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(clientWebView.lastStateChatId, 'chat-1');
    expect(decoded['url'], 'https://example.com');
    expect(decoded['canGoBack'], isTrue);
  });

  test(
    'webview navigate tool preserves blocked AI browsing responses',
    () async {
      clientWebView.navigationResult = ClientWebViewNavigationResult(
        chatId: 'chat-1',
        supported: true,
        action: 'back',
        navigated: false,
        blocked: true,
        error: 'AI WebView browsing is active.',
      );

      final raw = await tools.execute('client_webview_navigate', {
        'action': 'back',
      });
      final decoded = jsonDecode(raw) as Map<String, dynamic>;

      expect(clientWebView.lastNavigateChatId, 'chat-1');
      expect(clientWebView.lastNavigateAction, 'back');
      expect(decoded['blocked'], isTrue);
      expect(decoded['error'], contains('AI WebView browsing'));
    },
  );
}
