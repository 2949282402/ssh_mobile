import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/core/services/ssh_host_key_policy.dart';
import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/client_system_tool_service.dart';
import 'package:ssh_mobile/services/client_webview_service.dart';
import 'package:ssh_mobile/services/performance_monitor_tool_service.dart';
import 'package:ssh_mobile/services/server_catalog_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/server_diagnostics_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storage;
  late SshService ssh;
  late _FakeSftpClient sftp;
  late _FakeClientSystemToolService clientSystem;
  late _FakeClientWebViewAdapter clientWebView;
  late _FakeServerCatalogService serverCatalog;
  late _FakePerformanceMonitorToolService performanceMonitor;
  late _FakeServerDiagnosticsService diagnostics;
  late AppSettings appSettings;
  late AiToolService tools;
  late AiToolService toolsWithoutChatSession;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({
      'sftp_download_limit_bytes': 8,
      'sftp_text_edit_limit_bytes': 4,
    });
    FlutterSecureStorage.setMockInitialValues({});

    storage = StorageService();
    await storage.init();
    await storage.addConnection(
      ConnectionConfig(
        id: 'server-1',
        name: 'Demo Server',
        host: 'example.com',
        username: 'root',
        launchMode: TerminalLaunchMode.ssh,
        serverPlatform: ServerPlatform.linux,
      ),
    );
    ssh = SshService(storage);
    sftp = _FakeSftpClient();
    clientSystem = _FakeClientSystemToolService();
    clientWebView = _FakeClientWebViewAdapter();
    serverCatalog = _FakeServerCatalogService();
    performanceMonitor = _FakePerformanceMonitorToolService();
    diagnostics = _FakeServerDiagnosticsService();
    appSettings = AppSettings();
    await appSettings.init();

    tools = _buildTools(
      storage: storage,
      ssh: ssh,
      sftp: sftp,
      clientSystem: clientSystem,
      clientWebView: clientWebView,
      serverCatalog: serverCatalog,
      performanceMonitor: performanceMonitor,
      diagnostics: diagnostics,
      appSettings: appSettings,
      chatId: 'chat-1',
    );
    toolsWithoutChatSession = _buildTools(
      storage: storage,
      ssh: ssh,
      sftp: sftp,
      clientSystem: clientSystem,
      clientWebView: clientWebView,
      serverCatalog: serverCatalog,
      performanceMonitor: performanceMonitor,
      diagnostics: diagnostics,
      appSettings: appSettings,
    );
  });

  tearDown(() {
    AppLogService.instance.clear();
    ssh.dispose();
    storage.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  test('allows Linux read-only diagnostics', () {
    final review = tools.reviewCommand(
      'df -h',
      platform: ServerPlatform.linux,
    );

    expect(review.blocked, isFalse);
    expect(review.requiresApproval, isFalse);
  });

  test('requires approval for Linux command chaining', () {
    final review = tools.reviewCommand(
      'cat /etc/os-release | grep PRETTY',
      platform: ServerPlatform.linux,
    );

    expect(review.blocked, isFalse);
    expect(review.requiresApproval, isTrue);
  });

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
    final review = tools.reviewCommand(
      'dir',
      platform: ServerPlatform.windows,
    );

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
    final raw = await toolsWithoutChatSession.execute(
      'web_search',
      {'query': 'flutter'},
    );
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
          (definition) => (definition['function']
              as Map<String, dynamic>)['name'] as String,
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
    final queryLogsParams = (queryLogs['function']
        as Map<String, dynamic>)['parameters'] as Map<String, dynamic>;
    final queryLogsProps =
        queryLogsParams['properties'] as Map<String, dynamic>;
    expect((queryLogsProps['limit'] as Map<String, dynamic>)['default'], 50);
    expect((queryLogsProps['limit'] as Map<String, dynamic>)['maximum'], 200);

    final navigate = definitions.firstWhere(
      (definition) =>
          (definition['function'] as Map<String, dynamic>)['name'] ==
          'client_webview_navigate',
    );
    final navigateParams = (navigate['function']
        as Map<String, dynamic>)['parameters'] as Map<String, dynamic>;
    final navigateProps = navigateParams['properties'] as Map<String, dynamic>;
    expect(navigateParams['required'], ['action']);
    expect(
      (navigateProps['action'] as Map<String, dynamic>)['enum'],
      ['open', 'back', 'forward', 'refresh'],
    );
  });

  test('client permission tool delegates to the client system adapter',
      () async {
    final raw = await tools.execute('client_get_permission_status', {});
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded['execution'], 'client');
    expect(decoded['notificationGranted'], isTrue);
  });

  test('client log query uses default limit and passes filters', () async {
    final raw = await tools.execute(
      'client_query_logs',
      {'level': 'warning', 'contains': 'ssh'},
    );
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(clientSystem.lastQueryLevel, 'warning');
    expect(clientSystem.lastQueryContains, 'ssh');
    expect(clientSystem.lastQueryLimit, 50);
    expect(decoded['limit'], 50);
  });

  test('client log count tool delegates to the client system adapter',
      () async {
    final raw = await tools.execute('client_get_log_counts', {});
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(clientSystem.getLogCountsCalled, isTrue);
    expect((decoded['counts'] as Map<String, dynamic>)['warning'], 2);
  });

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

  test('webview navigate tool preserves blocked AI browsing responses',
      () async {
    clientWebView.navigationResult = ClientWebViewNavigationResult(
      chatId: 'chat-1',
      supported: true,
      action: 'back',
      navigated: false,
      blocked: true,
      error: 'AI WebView browsing is active.',
    );

    final raw = await tools.execute(
      'client_webview_navigate',
      {'action': 'back'},
    );
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(clientWebView.lastNavigateChatId, 'chat-1');
    expect(clientWebView.lastNavigateAction, 'back');
    expect(decoded['blocked'], isTrue);
    expect(decoded['error'], contains('AI WebView browsing'));
  });

  group('AI Experience Skills tools management', () {
    test(
        'client_save_experience_skill, client_list_skills, and client_update_skill tools CRUD flow',
        () async {
      final rawSave = await tools.execute(
          'client_save_experience_skill',
          {
            'summary': 'Short summary rule of deployment',
            'title': 'Deploy Skill',
            'content': 'Check server state first',
            'references': [
              {'title': 'Nginx restart', 'content': 'systemctl restart nginx'},
              {'title': 'Service check', 'content': 'systemctl status nginx'}
            ]
          },
          approvedWrite: true);
      final decodedSave = jsonDecode(rawSave) as Map<String, dynamic>;
      expect(decodedSave['saved'], isTrue);
      final skillId = decodedSave['skillId'] as String;

      final savedSkills = await storage.loadAiSkills();
      expect(savedSkills, hasLength(1));
      final skill = savedSkills.first;
      expect(skill.id, skillId);
      expect(skill.name, 'Deploy Skill');
      expect(skill.references, hasLength(2));
      expect(skill.references[0].title, equals('Nginx restart'));
      expect(skill.references[0].content, equals('systemctl restart nginx'));

      final rawList = await tools.execute('client_list_skills', {});
      final decodedList = jsonDecode(rawList) as Map<String, dynamic>;
      final skillItems = decodedList['skills'] as List<dynamic>;
      expect(skillItems, hasLength(1));
      expect(skillItems.first['id'], skillId);

      final rawUpdate = await tools.execute(
        'client_update_skill',
        {
          'skillId': skillId,
          'name': 'Updated Deploy Title',
          'enabled': false,
          'references': [
            {
              'title': 'New backup step',
              'content': 'tar -czf backup.tar.gz /var/www'
            }
          ]
        },
        approvedWrite: true,
      );
      final decodedUpdate = jsonDecode(rawUpdate) as Map<String, dynamic>;
      expect(decodedUpdate['updated'], isTrue);

      final updatedSkills = await storage.loadAiSkills();
      expect(updatedSkills, hasLength(1));
      final updatedSkill = updatedSkills.first;
      expect(updatedSkill.name, 'Updated Deploy Title');
      expect(updatedSkill.enabled, isFalse);
      expect(updatedSkill.references, hasLength(1));
      expect(updatedSkill.references.first.title, equals('New backup step'));
    });
  });

  test('sftp write approval request includes path, bytes, and preview',
      () async {
    final request = await tools.approvalRequestFor('sftp_write_text', {
      'connectionId': 'server-1',
      'path': '/etc/nginx/nginx.conf',
      'content': 'worker_processes auto;',
    });

    expect(request, isNotNull);
    expect(request!.command, 'SFTP WRITE /etc/nginx/nginx.conf (22 bytes)');
    expect(request.targetPath, '/etc/nginx/nginx.conf');
    expect(request.byteLength, 22);
    expect(request.contentPreview, 'worker_processes auto;');
  });

  test('ssh session and terminal history tools require approval metadata',
      () async {
    final openRequest = await tools.approvalRequestFor('ssh_open_session', {
      'connectionId': 'server-1',
      'displayName': 'Ops Shell',
    });
    final closeAllRequest = await tools.approvalRequestFor(
      'ssh_close_server_sessions',
      {
        'connectionId': 'server-1',
      },
    );
    final restoreRequest =
        await tools.approvalRequestFor('ssh_restore_tmux_sessions', {});
    final deleteHistoryRequest =
        await tools.approvalRequestFor('ssh_delete_terminal_history_record', {
      'sessionId': 'session-1',
    });

    expect(openRequest, isNotNull);
    expect(openRequest!.approvalType, 'ssh_session_change');
    expect(openRequest.contentPreview, 'Ops Shell');
    expect(closeAllRequest, isNotNull);
    expect(closeAllRequest!.approvalType, 'ssh_session_change');
    expect(restoreRequest, isNotNull);
    expect(restoreRequest!.approvalType, 'ssh_session_change');
    expect(deleteHistoryRequest, isNotNull);
    expect(deleteHistoryRequest!.approvalType, 'terminal_history_change');
    expect(deleteHistoryRequest.destructive, isTrue);
  });

  test('ssh session tool refuses execution without approval', () async {
    final raw = await tools.execute('ssh_open_session', {
      'connectionId': 'server-1',
    });
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded['error'], contains('requires user approval'));
  });

  test('blocks secret-bearing SFTP paths before read', () async {
    final raw = await tools.execute('sftp_read_text', {
      'connectionId': 'server-1',
      'path': '/home/demo/.ssh/id_rsa',
    });
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded['blockedBy'], 'tool_secret_policy');
    expect(decoded['error'], contains('secret policy'));
  });

  test('sftp read approval request includes remote read metadata', () async {
    final request = await tools.approvalRequestFor('sftp_read_text', {
      'connectionId': 'server-1',
      'path': '/tmp/demo.txt',
    });

    expect(request, isNotNull);
    expect(request!.approvalType, 'remote_read');
    expect(request.command, 'SFTP READ /tmp/demo.txt');
    expect(request.targetPath, '/tmp/demo.txt');
  });

  test('sftp read requires approval before execution', () async {
    final raw = await tools.execute('sftp_read_text', {
      'connectionId': 'server-1',
      'path': '/tmp/demo.txt',
    });
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded['error'], contains('requires user approval'));
  });

  test('sftp write requires approval before execution', () async {
    final raw = await tools.execute('sftp_write_text', {
      'connectionId': 'server-1',
      'path': '/tmp/demo.txt',
      'content': 'abcd',
    });
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded['error'], contains('requires user approval'));
    expect(sftp.lastWritePath, isNull);
  });

  test('sftp write executes after approval and uses app settings limit',
      () async {
    final raw = await tools.execute(
      'sftp_write_text',
      {
        'connectionId': 'server-1',
        'path': '/tmp/demo.txt',
        'content': 'abcd',
      },
      approvedWrite: true,
    );
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded['written'], isTrue);
    expect(decoded['bytes'], 4);
    expect(sftp.lastWriteConnectionId, 'server-1');
    expect(sftp.lastWritePath, '/tmp/demo.txt');
    expect(sftp.lastWriteText, 'abcd');
    expect(sftp.lastWriteMaxBytes, AppSettings.minSftpLimitBytes);
  });

  test('sftp write fails when content exceeds the edit limit', () async {
    final oversizedText = 'a' * (AppSettings.minSftpLimitBytes + 1);
    await expectLater(
      () => tools.execute(
        'sftp_write_text',
        {
          'connectionId': 'server-1',
          'path': '/tmp/demo.txt',
          'content': oversizedText,
        },
        approvedWrite: true,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('sftp download saves file metadata on the client device', () async {
    final raw = await tools.execute(
      'sftp_download_file',
      {
        'connectionId': 'server-1',
        'path': '/var/log/app.log',
      },
      approvedWrite: true,
    );
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(sftp.lastDownloadConnectionId, 'server-1');
    expect(sftp.lastDownloadPath, '/var/log/app.log');
    expect(sftp.lastDownloadMaxBytes, AppSettings.minSftpLimitBytes);
    expect(clientSystem.lastSavedFileName, 'app.log');
    expect(decoded['saved'], isTrue);
    expect(decoded['remotePath'], '/var/log/app.log');
  });

  test('tool result redacts secret-like output content', () async {
    sftp.readTextResult = 'password=supersecret';

    final raw = await tools.execute(
      'sftp_read_text',
      {
        'connectionId': 'server-1',
        'path': '/tmp/demo.txt',
      },
      approvedWrite: true,
    );
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded['content'], contains('[REDACTED]'));
    expect(decoded['content'], isNot(contains('supersecret')));
  });

  test('sftp download treats user cancel as a normal result', () async {
    clientSystem.cancelNextSave = true;

    final raw = await tools.execute(
      'sftp_download_file',
      {
        'connectionId': 'server-1',
        'path': '/var/log/app.log',
      },
      approvedWrite: true,
    );
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded['saved'], isFalse);
    expect(decoded['cancelled'], isTrue);
    expect(decoded['note'], contains('cancelled'));
  });

  test('sftp download fails when detached transfer exceeds limit', () async {
    sftp.downloadBytes = Uint8List.fromList(
      List<int>.filled(AppSettings.minSftpLimitBytes + 1, 1),
    );

    await expectLater(
      () => tools.execute(
        'sftp_download_file',
        {
          'connectionId': 'server-1',
          'path': '/var/log/app.log',
        },
        approvedWrite: true,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('server status and ops report keep their public names and delegate',
      () async {
    final statusRaw = await tools.execute('get_server_status', {
      'connectionId': 'server-1',
      'mode': 'performance',
    });
    final reportRaw = await tools.execute('generate_ops_report', {
      'connectionId': 'server-1',
    });
    final status = jsonDecode(statusRaw) as Map<String, dynamic>;
    final report = jsonDecode(reportRaw) as Map<String, dynamic>;

    expect(diagnostics.lastStatusConnectionId, 'server-1');
    expect(diagnostics.lastStatusMode, 'performance');
    expect(status['performance']['memoryPercent'], 32.0);
    expect(diagnostics.lastReportConnectionId, 'server-1');
    expect(report['health']['level'], 'healthy');
  });

  test('composite diagnostic tools return structured JSON payloads', () async {
    final incidentRaw = await tools.execute('collect_incident_context', {
      'connectionId': 'server-1',
      'focus': 'nginx',
      'path': '/var/log/nginx/error.log',
    });
    final compareRaw = await tools.execute('compare_server_states', {
      'connectionIds': ['server-1', 'server-1'],
      'mode': 'performance',
    });

    final incident = jsonDecode(incidentRaw) as Map<String, dynamic>;
    final compare = jsonDecode(compareRaw) as Map<String, dynamic>;

    expect(incident['focus'], 'nginx');
    expect(incident['pathContext'], isNotNull);
    expect(compare['compared'], 2);
    expect(compare['mode'], 'performance');
  });

  test('server detail tool uses the injected server catalog adapter', () async {
    final raw = await tools.execute('get_server_details', {
      'connectionId': 'server-1',
    });
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(serverCatalog.lastDetailsConnectionId, 'server-1');
    expect((decoded['server'] as Map<String, dynamic>)['name'], 'Demo Server');
  });

  test('monitor state tool uses the injected monitor adapter', () async {
    final raw = await tools.execute('monitor_get_state', {});
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded['isRunning'], isFalse);
    expect(performanceMonitor.getStateCalled, isTrue);
  });

  test('app settings tool does not expose API key material', () async {
    final raw = await tools.execute('app_get_operational_settings', {});
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded.containsKey('activeApiKeyMasked'), isFalse);
    expect(decoded.containsKey('apiKey'), isFalse);
    expect(decoded.containsKey('hasApiKeyConfigured'), isTrue);
    expect(decoded['multiAgentEnabled'], isTrue);
    expect(decoded['multiAgentMaxAgents'], 3);
    expect(decoded['postToolReviewEnabled'], isTrue);
    expect(decoded['toolCallBudget'], 20);
  });

  test('app settings tool updates postToolReviewEnabled setting with approval',
      () async {
    final raw = await tools.execute(
      'app_update_operational_settings',
      {
        'postToolReviewEnabled': false,
      },
      approvedWrite: true,
    );
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final settings = await storage.loadAiConnectionSettings();

    expect(decoded['postToolReviewEnabled'], isFalse);
    expect(settings.postToolReviewEnabled, isFalse);
  });

  test('app settings tool updates multi-agent settings with approval',
      () async {
    final raw = await tools.execute(
      'app_update_operational_settings',
      {
        'multiAgentEnabled': false,
        'multiAgentMaxAgents': 4,
        'toolCallBudget': 40,
      },
      approvedWrite: true,
    );
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final settings = await storage.loadAiConnectionSettings();

    expect(decoded['multiAgentEnabled'], isFalse);
    expect(decoded['multiAgentMaxAgents'], 4);
    expect(decoded['toolCallBudget'], 40);
    expect(settings.multiAgentEnabled, isFalse);
    expect(settings.multiAgentMaxAgents, 4);
    expect(settings.toolCallBudget, 40);
  });

  group('client_set_plan_mode tool', () {
    test(
        'switches planMode to true, clears approved plan, and exits only with persisted latest todo steps',
        () async {
      final now = DateTime.now();
      var chat = AiChatRecord(
        id: 'chat-1',
        title: 'Draft',
        model: 'deepseek-v4-flash',
        messages: const [],
        createdAt: now,
        updatedAt: now,
        planMode: false,
        approvedPlan: AiApprovedPlanRef(
          assistantCreatedAt: now,
          approvedAt: now,
        ),
      );
      await storage.saveAiChat(chat);

      // 1. 开启 planMode
      final rawTrue =
          await tools.execute('client_set_plan_mode', {'enabled': true});
      final decodedTrue = jsonDecode(rawTrue) as Map<String, dynamic>;
      expect(decodedTrue['status'], 'success');
      expect(decodedTrue['planMode'], isTrue);

      final chatTrue =
          (await storage.loadAiChats()).firstWhere((c) => c.id == 'chat-1');
      expect(chatTrue.planMode, isTrue);
      expect(chatTrue.approvedPlan, isNull);

      // 2. 尝试关闭 planMode（因为没有任何 playbook 计划，应该被拦截报错）
      final rawFalse =
          await tools.execute('client_set_plan_mode', {'enabled': false});
      final decodedFalse = jsonDecode(rawFalse) as Map<String, dynamic>;
      expect(
          decodedFalse['error'],
          anyOf(
            contains('Cannot exit Plan Mode'),
            contains('无法退出规划模式'),
          ));

      final chatStillTrue =
          (await storage.loadAiChats()).firstWhere((c) => c.id == 'chat-1');
      expect(chatStillTrue.planMode, isTrue);

      // 3. 往会话中添加一条带有 playbook 计划步骤的消息
      final updatedChat = chatStillTrue.copyWith(
        messages: [
          AiChatMessageRecord(
            role: 'assistant',
            text: 'Earlier valid plan',
            createdAt: now.subtract(const Duration(minutes: 1)),
            todoSteps: const [
              AiTodoStep(
                id: 'task-old',
                name: 'Earlier plan',
                command: 'echo old',
                description: 'old',
              ),
            ],
          ),
          AiChatMessageRecord(
            role: 'assistant',
            text: 'Latest executable plan',
            createdAt: now,
            todoSteps: const [
              AiTodoStep(
                id: 'task-new',
                name: 'Step 1',
                command: 'echo ok',
                description: 'Persisted plan step',
              ),
            ],
          ),
        ],
      );
      await storage.saveAiChat(updatedChat);

      // 4. 再次尝试关闭 planMode（此时符合条件，应允许退出）
      final rawExit =
          await tools.execute('client_set_plan_mode', {'enabled': false});
      final decodedExit = jsonDecode(rawExit) as Map<String, dynamic>;
      expect(decodedExit['status'], 'success');
      expect(decodedExit['planMode'], isFalse);

      final chatFalse =
          (await storage.loadAiChats()).firstWhere((c) => c.id == 'chat-1');
      expect(chatFalse.planMode, isFalse);
    });
  });

  group('client_task_create and client_task_update flow and constraints', () {
    test('enforces planMode時机限制与数据防篡改', () async {
      final now = DateTime.now();

      // 1. 初始化 ChatRecord，最后一客助理消息，并且处于 planMode = true
      var chat = AiChatRecord(
        id: 'chat-1',
        title: 'Draft',
        model: 'deepseek-v4-flash',
        messages: [
          AiChatMessageRecord(
            role: 'assistant',
            text: 'Let me plan...',
            createdAt: now,
          ),
        ],
        createdAt: now,
        updatedAt: now,
        planMode: true,
      );
      await storage.saveAiChat(chat);

      // 2. 处于 Plan Mode，调用 TaskCreate 应成功
      final rawCreate = await tools.execute('client_task_create', {
        'name': 'Install Docker',
        'command': 'curl -fsSL https://get.docker.com | sh',
        'description': 'Install docker engine',
      });
      final decodedCreate = jsonDecode(rawCreate) as Map<String, dynamic>;
      expect(decodedCreate['status'], 'success');
      final taskId = decodedCreate['taskId'] as String;
      expect(taskId, startsWith('task-'));

      // 验证是否已存入助理消息的 todoSteps
      final chatAfterCreate =
          (await storage.loadAiChats()).firstWhere((c) => c.id == 'chat-1');
      expect(chatAfterCreate.messages.last.todoSteps.length, 1);
      expect(chatAfterCreate.messages.last.todoSteps.first.id, taskId);

      // 3. 处于 Plan Mode，调用 TaskUpdate 应该被拦截报错
      final rawUpdateInPlan = await tools.execute('client_task_update', {
        'taskId': taskId,
        'status': 'success',
      });
      final decodedUpdateInPlan =
          jsonDecode(rawUpdateInPlan) as Map<String, dynamic>;
      expect(
          decodedUpdateInPlan['error'],
          contains(
              'client_task_update can ONLY be called during Execution Mode'));

      // 4. 将 Chat 设为 planMode = false (执行模式)
      final chatExecution = chatAfterCreate.copyWith(planMode: false);
      await storage.saveAiChat(chatExecution);

      // 5. 处于 Execution Mode，调用 TaskCreate 应该被拦截报错
      final rawCreateInExec = await tools.execute('client_task_create', {
        'name': 'Another Step',
      });
      final decodedCreateInExec =
          jsonDecode(rawCreateInExec) as Map<String, dynamic>;
      expect(decodedCreateInExec['error'],
          contains('client_task_create can ONLY be called during Plan Mode'));

      // 6. 处于 Execution Mode，调用 TaskUpdate 应该成功并更新状态
      final rawRunningAlias = await tools.execute('client_task_update', {
        'taskId': taskId,
        'status': 'in_progress',
      });
      final decodedRunningAlias =
          jsonDecode(rawRunningAlias) as Map<String, dynamic>;
      expect(decodedRunningAlias['status'], 'success');
      expect(decodedRunningAlias['newStatus'], 'running');

      final chatAfterAlias =
          (await storage.loadAiChats()).firstWhere((c) => c.id == 'chat-1');
      expect(
          chatAfterAlias.messages.last.todoSteps.first.status.name, 'running');

      final rawUpdate = await tools.execute('client_task_update', {
        'taskId': taskId,
        'status': 'success',
        'stdout': 'Docker version 24.0.7',
      });
      final decodedUpdate = jsonDecode(rawUpdate) as Map<String, dynamic>;
      expect(decodedUpdate['status'], 'success');
      expect(decodedUpdate['newStatus'], 'success');

      final chatAfterUpdate =
          (await storage.loadAiChats()).firstWhere((c) => c.id == 'chat-1');
      final updatedStep = chatAfterUpdate.messages.last.todoSteps.first;
      expect(updatedStep.status.name, 'success');
      expect(updatedStep.stdout, 'Docker version 24.0.7');

      // 7. 处于 Execution Mode，但调用不存在的 taskId 应该报错
      final rawUpdateInvalid = await tools.execute('client_task_update', {
        'taskId': 'invalid-id',
        'status': 'success',
      });
      final decodedUpdateInvalid =
          jsonDecode(rawUpdateInvalid) as Map<String, dynamic>;
      expect(decodedUpdateInvalid['error'], contains('Task step not found'));
    });
  });

  group('client_update_skill approval and security flow', () {
    test('requires approval before execution and succeeds after approved',
        () async {
      final now = DateTime.now();
      final skill = AiSkillRecord(
        id: 'skill-test-1',
        name: 'Original Name',
        description: 'Original Desc',
        content: 'Original Content',
        enabled: true,
        createdAt: now,
        updatedAt: now,
      );
      await storage.saveAiSkill(skill);

      // 1. 验证 approvalRequestFor 能生成正确的 local_skill_change 请求
      final request = await tools.approvalRequestFor('client_update_skill', {
        'skillId': 'skill-test-1',
        'name': 'Updated Name',
        'description': 'Updated Desc',
      });
      expect(request, isNotNull);
      expect(request!.approvalType, equals('local_skill_change'));
      expect(request.connectionName, contains('client'));
      expect(request.contentPreview, contains('Updated Name'));

      // 2. 未通过审批执行，应当返回报错
      final rawBlocked = await tools.execute('client_update_skill', {
        'skillId': 'skill-test-1',
        'name': 'Updated Name',
      });
      final decodedBlocked = jsonDecode(rawBlocked) as Map<String, dynamic>;
      expect(decodedBlocked['error'], contains('requires user approval'));

      // 3. 审批通过后执行，应当修改成功
      final rawSuccess = await tools.execute(
        'client_update_skill',
        {
          'skillId': 'skill-test-1',
          'name': 'Updated Name',
        },
        approvedWrite: true,
      );
      final decodedSuccess = jsonDecode(rawSuccess) as Map<String, dynamic>;
      expect(decodedSuccess['updated'], isTrue);

      final updated = (await storage.loadAiSkills())
          .firstWhere((s) => s.id == 'skill-test-1');
      expect(updated.name, equals('Updated Name'));

      // 4. 验证 client_save_experience_skill 也需要审批且未审批报错
      final saveRequest =
          await tools.approvalRequestFor('client_save_experience_skill', {
        'summary': 'New Exp Summary',
        'content': 'Details here',
      });
      expect(saveRequest, isNotNull);
      expect(saveRequest!.approvalType, equals('local_skill_change'));
      expect(saveRequest.contentPreview, contains('New Exp Summary'));

      final rawSaveBlocked =
          await tools.execute('client_save_experience_skill', {
        'summary': 'New Exp Summary',
      });
      expect(jsonDecode(rawSaveBlocked)['error'],
          contains('requires user approval'));

      final rawSaveSuccess = await tools.execute(
          'client_save_experience_skill',
          {
            'summary': 'New Exp Summary',
          },
          approvedWrite: true);
      expect(jsonDecode(rawSaveSuccess)['saved'], isTrue);

      // 5. 验证 client_list_skills 仍然不需要审批
      final rawList = await tools.execute('client_list_skills', {});
      expect(jsonDecode(rawList)['skills'], isNotNull);
    });

    test('client_save_experience_skill approval preview redacts secrets',
        () async {
      final request =
          await tools.approvalRequestFor('client_save_experience_skill', {
        'summary': 'Add password config',
        'content':
            'Use secret admin password: "my-super-secret-password-123" to login, and check Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ token.',
      });

      expect(request, isNotNull);
      expect(request!.contentPreview,
          isNot(contains('my-super-secret-password-123')));
      expect(request.contentPreview,
          isNot(contains('eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9')));
      expect(request.contentPreview, contains('password=[REDACTED]'));
    });
  });

  group('needsServerSelection tools connectionId boundary check tests', () {
    test('server tool without connectionId returns connection_required',
        () async {
      final raw = await tools.execute('get_server_details', {});
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      expect(
          decoded['error'], contains('requires a selected server connection'));
      expect(decoded['code'], 'connection_required');
      expect(decoded['tool'], 'get_server_details');
    });

    test('sftp write without connectionId returns connection_required',
        () async {
      final raw = await tools.execute('sftp_write_text', {
        'path': '/tmp/test.txt',
        'content': 'hello',
      });
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      expect(
          decoded['error'], contains('requires a selected server connection'));
      expect(decoded['code'], 'connection_required');
      expect(decoded['tool'], 'sftp_write_text');
    });

    test('ssh run_command without connectionId returns connection_required',
        () async {
      final raw = await tools.execute('run_command', {
        'command': 'ls -la',
      });
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      expect(
          decoded['error'], contains('requires a selected server connection'));
      expect(decoded['code'], 'connection_required');
      expect(decoded['tool'], 'run_command');
    });

    test('ssh run_command with local connectionId returns connection_required',
        () async {
      final raw = await tools.execute('run_command', {
        'connectionId': 'local',
        'command': 'ls -la',
      });
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      expect(
          decoded['error'], contains('requires a selected server connection'));
      expect(decoded['code'], 'connection_required');
      expect(decoded['tool'], 'run_command');
    });

    test('monitor汇总工具不需要选中服务器连接就可以执行', () async {
      // monitor_get_state
      final rawState = await tools.execute('monitor_get_state', {});
      final decodedState = jsonDecode(rawState) as Map<String, dynamic>;
      expect(decodedState['error'], isNull);

      // monitor_get_health
      final rawHealth = await tools.execute('monitor_get_health', {});
      final decodedHealth = jsonDecode(rawHealth) as Map<String, dynamic>;
      expect(decodedHealth['error'], isNull);

      // monitor_get_alerts
      final rawAlerts = await tools.execute('monitor_get_alerts', {});
      final decodedAlerts = jsonDecode(rawAlerts) as Map<String, dynamic>;
      expect(decodedAlerts['error'], isNull);
    });

    test('其他monitor工具和停止监视工具依然必须有服务器连接', () async {
      final toolsToTest = [
        'monitor_get_samples',
        'monitor_get_ports',
        'monitor_get_applications',
        'monitor_stop_for_connection'
      ];
      for (final toolName in toolsToTest) {
        final raw = await tools.execute(toolName, {});
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        expect(
          decoded['error'],
          contains('requires a selected server connection'),
          reason: 'Tool $toolName should require a server connection.',
        );
        expect(
          decoded['code'],
          'connection_required',
          reason: 'Tool $toolName should fail with connection_required.',
        );
      }
    });
  });
}

AiToolService _buildTools({
  required StorageService storage,
  required SshService ssh,
  required SftpClientAdapter sftp,
  required ClientSystemToolAdapter clientSystem,
  required ClientWebViewAdapter clientWebView,
  required ServerCatalogAdapter serverCatalog,
  required PerformanceMonitorToolAdapter performanceMonitor,
  required ServerDiagnosticsAdapter diagnostics,
  required AppSettings appSettings,
  String? chatId,
}) {
  return AiToolService(
    storageService: storage,
    sshService: ssh,
    sftpService: sftp,
    clientSystemToolService: clientSystem,
    clientWebViewService: clientWebView,
    serverCatalogService: serverCatalog,
    performanceMonitorToolService: performanceMonitor,
    serverDiagnosticsService: diagnostics,
    appSettings: appSettings,
    clientWebViewSessionId: chatId,
  );
}

class _FakeClientSystemToolService implements ClientSystemToolAdapter {
  String? lastQueryLevel;
  String? lastQueryContains;
  int? lastQueryLimit;
  String? lastSavedFileName;
  List<int>? lastSavedBytes;
  String? lastSaveDialogTitle;
  bool cancelNextSave = false;
  bool getLogCountsCalled = false;
  List<int>? deletedLogIds;
  bool clearLogsCalled = false;
  ClientPickedFile? nextPickedFile;

  @override
  Map<String, dynamic> getClientTime() => {'execution': 'client'};

  @override
  Map<String, dynamic> getClientDeviceInfo() => {'execution': 'client'};

  @override
  Future<Map<String, dynamic>> getNetworkInfo() async => {
        'execution': 'client',
        'target': 'client_device',
      };

  @override
  Future<Map<String, dynamic>> getBatteryStatus() async => {
        'execution': 'client',
        'target': 'client_device',
      };

  @override
  Future<Map<String, dynamic>> getPermissionStatus() async => {
        'execution': 'client',
        'target': 'client_device',
        'notificationGranted': true,
        'supportsBatteryOptimizationExemption': true,
      };

  @override
  Future<Map<String, dynamic>> openAppSettings() async => {
        'execution': 'client',
        'opened': true,
      };

  @override
  Future<Map<String, dynamic>> setClipboard(String text) async => {
        'execution': 'client',
        'updated': true,
        'textLength': text.length,
      };

  @override
  Future<Map<String, dynamic>> setAlarm({
    String? triggerAt,
    int? delaySeconds,
    int? delayMinutes,
    String? label,
    bool useSystemAlarm = true,
  }) async =>
      {'execution': 'client', 'created': true};

  @override
  Future<Map<String, dynamic>> listAlarms() async => {
        'execution': 'client',
        'alarms': const [],
      };

  @override
  Future<Map<String, dynamic>> cancelAlarm(String alarmId) async => {
        'execution': 'client',
        'cancelled': true,
        'alarmId': alarmId,
      };

  @override
  Future<Map<String, dynamic>> queryLogs({
    String? level,
    String? contains,
    int limit = 50,
  }) async {
    lastQueryLevel = level;
    lastQueryContains = contains;
    lastQueryLimit = limit;
    return {
      'execution': 'client',
      'target': 'client_logs',
      'level': level ?? 'all',
      'contains': contains,
      'limit': limit,
      'matched': 1,
      'truncated': false,
      'entries': const [
        {'message': 'warning: ssh retry'},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> getLogCounts() async {
    getLogCountsCalled = true;
    return {
      'execution': 'client',
      'target': 'client_logs',
      'counts': {
        'all': 3,
        'warning': 2,
        'error': 1,
      },
    };
  }

  @override
  Future<Map<String, dynamic>> deleteLogEntries(List<int> ids) async {
    deletedLogIds = List<int>.from(ids);
    return {
      'execution': 'client',
      'target': 'client_logs',
      'deleted': ids.length,
      'remaining': 0,
    };
  }

  @override
  Future<Map<String, dynamic>> clearLogs() async {
    clearLogsCalled = true;
    return {
      'execution': 'client',
      'target': 'client_logs',
      'cleared': 3,
      'remaining': 0,
    };
  }

  @override
  Future<Map<String, dynamic>> saveBytesToFile({
    required String fileName,
    required List<int> bytes,
    String? dialogTitle,
  }) async {
    lastSavedFileName = fileName;
    lastSavedBytes = List<int>.from(bytes);
    lastSaveDialogTitle = dialogTitle;
    final cancelled = cancelNextSave;
    cancelNextSave = false;
    return {
      'execution': 'client',
      'target': 'client_device',
      'saved': !cancelled,
      'cancelled': cancelled,
      'localPath': cancelled ? null : 'C:/Downloads/$fileName',
      'fileName': fileName,
      'bytes': bytes.length,
      'note': cancelled
          ? 'The user cancelled the local save dialog.'
          : 'The file was saved on the client device running SSH Mobile.',
    };
  }

  @override
  Future<ClientPickedFile?> pickFile({
    List<String>? allowedExtensions,
    String? dialogTitle,
  }) async {
    final picked = nextPickedFile;
    nextPickedFile = null;
    return picked;
  }
}

class _FakeClientWebViewAdapter implements ClientWebViewAdapter {
  ClientWebViewStateSnapshot? state;
  ClientWebViewNavigationResult? navigationResult;
  String? lastStateChatId;
  String? lastNavigateChatId;
  String? lastNavigateAction;
  String? lastNavigateInput;

  @override
  Future<ClientWebViewSnapshot> readPlainText(
    String chatId, {
    int maxChars = ClientWebViewService.defaultMaxChars,
  }) async {
    return ClientWebViewSnapshot(
      chatId: chatId,
      supported: true,
      hasPage: true,
      text: 'example',
      textLength: 7,
      maxChars: maxChars,
      truncated: false,
    );
  }

  @override
  Future<ClientWebViewSearchResult> searchWeb(
    String chatId,
    String query, {
    int maxResults = 5,
    String? engine,
  }) async {
    return ClientWebViewSearchResult(
      chatId: chatId,
      supported: true,
      query: query,
      results: const [],
      engine: engine ?? 'baidu',
    );
  }

  @override
  Future<ClientWebViewStateSnapshot> getState(String chatId) async {
    lastStateChatId = chatId;
    return state ??
        ClientWebViewStateSnapshot(
          chatId: chatId,
          supported: true,
          hasPage: true,
          progress: 100,
          isLoading: false,
          isAiBrowsing: false,
          canGoBack: false,
          canGoForward: false,
          lastTextLength: 0,
          lastTextTruncated: false,
        );
  }

  @override
  Future<ClientWebViewNavigationResult> navigate(
    String chatId, {
    required String action,
    String? input,
  }) async {
    lastNavigateChatId = chatId;
    lastNavigateAction = action;
    lastNavigateInput = input;
    return navigationResult ??
        ClientWebViewNavigationResult(
          chatId: chatId,
          supported: true,
          action: action,
          input: input,
          navigated: true,
          blocked: false,
          state: await getState(chatId),
        );
  }

  @override
  void interruptAiBrowsing(String chatId) {}

  @override
  void clearSession(String chatId) {}
}

class _FakeSftpClient implements SftpClientAdapter {
  Uint8List downloadBytes = Uint8List.fromList([1, 2, 3, 4]);
  String readTextResult = 'text';
  String? lastDownloadConnectionId;
  String? lastDownloadPath;
  int? lastDownloadMaxBytes;
  String? lastWriteConnectionId;
  String? lastWritePath;
  String? lastWriteText;
  int? lastWriteMaxBytes;
  String? lastUploadConnectionId;
  String? lastUploadPath;
  Uint8List? lastUploadBytes;
  String? lastRenamePath;
  String? lastRenameNewPath;
  String? lastDeletePath;
  String? lastMkdirPath;

  @override
  String? get connectionId => null;

  @override
  String? get connectionName => null;

  @override
  String get currentPath => '.';

  @override
  SftpConnectionState get state => SftpConnectionState.disconnected;

  @override
  String? get errorMessage => null;

  @override
  int get entriesRevision => 0;

  @override
  List<SftpEntry> get entries => const [];

  @override
  bool get isConnected => false;

  @override
  bool get isBusy => false;

  @override
  bool isConnectionBusy(String connectionId) => false;

  @override
  bool isConnectionOpen(String connectionId) => false;

  @override
  Future<void> connect(
    String connectionId, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {}

  @override
  Future<void> refresh() async {}

  @override
  Future<void> uploadBytes({
    required String filename,
    required Uint8List bytes,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteEntry(
    SftpEntry entry, {
    required String confirmedName,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<List<SftpEntry>> listDirectoryForConnection(
    String connectionId,
    String path,
  ) async {
    return const [];
  }

  @override
  Future<String> readTextPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = SftpService.maxTextPreviewBytes,
  }) async {
    return readTextResult;
  }

  @override
  Future<Uint8List> downloadPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = SftpService.maxDownloadBytes,
  }) async {
    lastDownloadConnectionId = connectionId;
    lastDownloadPath = path;
    lastDownloadMaxBytes = maxBytes;
    if (downloadBytes.length > maxBytes) {
      throw StateError('Download exceeds maxBytes');
    }
    return downloadBytes;
  }

  @override
  Future<SftpPathInfo> statPathForConnection({
    required String connectionId,
    required String path,
  }) async {
    return SftpPathInfo(
      path: path,
      isDirectory: false,
      isLink: false,
      size: 4,
      sizeLabel: '4 B',
      modifiedAt: DateTime.utc(2025, 1, 1),
    );
  }

  @override
  Future<void> writeTextPathForConnection({
    required String connectionId,
    required String path,
    required String text,
    int maxBytes = SftpService.maxTextEditBytes,
  }) async {
    lastWriteConnectionId = connectionId;
    lastWritePath = path;
    lastWriteText = text;
    lastWriteMaxBytes = maxBytes;
    if (text.length > maxBytes) {
      throw StateError('Text exceeds maxBytes');
    }
  }

  @override
  Future<void> uploadBytesPathForConnection({
    required String connectionId,
    required String path,
    required Uint8List bytes,
    int maxBytes = SftpService.maxUploadBytes,
  }) async {
    lastUploadConnectionId = connectionId;
    lastUploadPath = path;
    lastUploadBytes = bytes;
  }

  @override
  Future<void> createDirectoryPathForConnection({
    required String connectionId,
    required String path,
  }) async {
    lastMkdirPath = path;
  }

  @override
  Future<void> renamePathForConnection({
    required String connectionId,
    required String path,
    required String newPath,
  }) async {
    lastRenamePath = path;
    lastRenameNewPath = newPath;
  }

  @override
  Future<void> deletePathForConnection({
    required String connectionId,
    required String path,
  }) async {
    lastDeletePath = path;
  }

  @override
  Future<void> openPath(String path) async {}

  @override
  Future<void> openParent() async {}

  @override
  Future<void> disconnect({bool notify = true}) async {}

  @override
  Future<void> disconnectConnection(
    String connectionId, {
    bool notify = true,
    bool forgetPath = false,
  }) async {}

  @override
  Future<void> disconnectAll({bool notify = true}) async {}

  @override
  SftpTransferState? get activeTransfer => null;

  @override
  bool get hasActiveTransfer => false;

  @override
  void cancelActiveTransfer() {}

  @override
  Future<void> uploadFile({
    required String localPath,
    required String filename,
  }) async {}

  @override
  Future<void> downloadFile(
    SftpEntry entry, {
    required String localPath,
    int maxBytes = SftpService.maxDownloadBytes,
  }) async {}
}

class _FakeServerDiagnosticsService implements ServerDiagnosticsAdapter {
  String? lastStatusConnectionId;
  String? lastStatusMode;
  String? lastReportConnectionId;

  @override
  Future<Map<String, dynamic>> detectOs(String connectionId) async => {
        'os': 'linux',
        'method': 'saved_server_platform',
      };

  @override
  Future<Map<String, dynamic>> getStatus({
    required String connectionId,
    String? mode,
  }) async {
    lastStatusConnectionId = connectionId;
    lastStatusMode = mode;
    return {
      'connectionId': connectionId,
      'performance': {'memoryPercent': 32.0},
    };
  }

  @override
  Future<Map<String, dynamic>> generateOpsReport(String connectionId) async {
    lastReportConnectionId = connectionId;
    return {
      'connectionId': connectionId,
      'health': {
        'score': 92,
        'level': 'healthy',
      },
    };
  }
}

class _FakeServerCatalogService implements ServerCatalogAdapter {
  String? lastDetailsConnectionId;

  @override
  Future<Map<String, dynamic>> deleteServer(String connectionId) async => {
        'deleted': true,
        'connectionId': connectionId,
      };

  @override
  Map<String, dynamic>? getServerDetails(String connectionId) {
    lastDetailsConnectionId = connectionId;
    return {
      'server': {
        'id': connectionId,
        'name': 'Demo Server',
        'host': 'example.com',
      },
    };
  }

  @override
  List<Map<String, dynamic>> listServerSummaries() => const [
        {
          'id': 'server-1',
          'name': 'Demo Server',
          'host': 'example.com',
        },
      ];

  @override
  Future<Map<String, dynamic>> reorderServers(List<String> orderedIds) async =>
      {
        'reordered': true,
        'orderedIds': orderedIds,
      };

  @override
  Future<Map<String, dynamic>> updateServerMetadata({
    required String connectionId,
    required Map<String, dynamic> changes,
  }) async =>
      {
        'updated': true,
        'server': {
          'id': connectionId,
          ...changes,
        },
      };
}

class _FakePerformanceMonitorToolService
    implements PerformanceMonitorToolAdapter {
  bool getStateCalled = false;

  @override
  Map<String, dynamic> clearSelection() => getState();

  @override
  Future<Map<String, dynamic>> getApplications(String connectionId) async =>
      {'connectionId': connectionId, 'applications': const []};

  @override
  Map<String, dynamic> getAlerts({int limit = 50}) =>
      {'alerts': const [], 'limit': limit};

  @override
  Map<String, dynamic> getHealth({List<String>? connectionIds}) =>
      {'health': const {}};

  @override
  Future<Map<String, dynamic>> getPorts(String connectionId) async =>
      {'connectionId': connectionId, 'ports': const []};

  @override
  Map<String, dynamic> getSamples(
    String connectionId, {
    bool visibleOnly = true,
    int limit = 100,
  }) =>
      {
        'connectionId': connectionId,
        'visibleOnly': visibleOnly,
        'limit': limit,
        'samples': const [],
      };

  @override
  Map<String, dynamic> getState() {
    getStateCalled = true;
    return {
      'isRunning': false,
      'isSampling': false,
      'selectedConnectionIds': const <String>[],
      'monitoringConnectionIds': const <String>[],
    };
  }

  @override
  Map<String, dynamic> setHistoryWindow(Duration window) => getState();

  @override
  Map<String, dynamic> setInterval(Duration interval) => getState();

  @override
  Map<String, dynamic> setSelectedServers(List<String> connectionIds) =>
      getState();

  @override
  Future<Map<String, dynamic>> start() async => getState();

  @override
  Map<String, dynamic> stop() => getState();

  @override
  Map<String, dynamic> stopForConnection(String connectionId) => getState();
}
