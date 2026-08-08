part of '../ai_tool_service.dart';

List<AiTool> _getClientTools(
  ClientToolsProvider provider,
  AiToolService service,
  AiConnectionSettings searchSettings,
) {
  final webSearchMaxResults = AiWebSearchMaxResults.normalize(
    searchSettings.webSearchMaxResults,
  );
  return [
    if (searchSettings.webSearchEnabled)
      AiTool(
        name: 'web_search',
        description:
            'Search the public web from the SSH Mobile client WebView bound to the current chat session. Return cited result URLs. Use this before answering questions about current, latest, news, or external information. Current app setting returns up to $webSearchMaxResults results by default.',
        properties: {
          'query': _string('Search query. Keep it concise.'),
          'limit': _int(
            'Maximum number of results to return. Omit this to use the current app setting of $webSearchMaxResults results.',
            minimum: 1,
            maximum: webSearchMaxResults,
            defaultValue: webSearchMaxResults,
          ),
        },
        required: const ['query'],
        requiresWebViewSession: true,
        capabilities: const {AiToolCapability.web, AiToolCapability.client},
        cacheTtl: const Duration(seconds: 30),
        handler: (args) => _webSearch(provider, service, args),
      ),
    AiTool(
      name: 'client_get_time',
      description:
          'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Get the client system time, UTC time, timezone, and locale.',
      properties: const {},
      parallelSafeReadOnly: true,
      handler: (_) async =>
          jsonEncode(provider.clientSystemToolService.getClientTime()),
    ),
    AiTool(
      name: 'client_get_device_info',
      description:
          'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Get client OS/platform, locale, timezone, hostname, CPU count, and supported client integrations.',
      properties: const {},
      parallelSafeReadOnly: true,
      handler: (_) async =>
          jsonEncode(provider.clientSystemToolService.getClientDeviceInfo()),
    ),
    AiTool(
      name: 'client_get_network_info',
      description:
          'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Get client network status such as connectivity, transport, Wi-Fi details where available, and proxy or VPN indicators.',
      properties: const {},
      parallelSafeReadOnly: true,
      handler: (_) async =>
          jsonEncode(await provider.clientSystemToolService.getNetworkInfo()),
    ),
    AiTool(
      name: 'client_get_battery_status',
      description:
          'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Get client battery level, charging state, battery saver, and app battery-optimization exemption status where available.',
      properties: const {},
      parallelSafeReadOnly: true,
      handler: (_) async =>
          jsonEncode(await provider.clientSystemToolService.getBatteryStatus()),
    ),
    AiTool(
      name: 'client_get_permission_status',
      description:
          'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Get client notification permission, background-service support, and Android battery-optimization exemption status where available.',
      properties: const {},
      parallelSafeReadOnly: true,
      handler: (_) async => jsonEncode(
        await provider.clientSystemToolService.getPermissionStatus(),
      ),
    ),
    AiTool(
      name: 'client_check_runtime_health',
      description:
          'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Check whether the Android/client runtime is healthy enough for long agent execution, SSH keep-alive, SFTP transfers, or monitoring. Returns ok, warning, or blocking issues plus recommendations.',
      properties: {
        'profile': {
          'type': 'string',
          'enum': const ['general', 'agent_execution', 'background'],
          'description':
              'Optional health profile. Use agent_execution before approved plan execution; use background for SSH keep-alive or monitor sampling. Defaults to agent_execution.',
          'default': 'agent_execution',
        },
      },
      parallelSafeReadOnly: true,
      capabilities: const {AiToolCapability.client},
      cacheTtl: const Duration(seconds: 10),
      handler: (args) => _clientCheckRuntimeHealth(provider, service, args),
    ),
    AiTool(
      name: 'client_open_app_settings',
      description:
          'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Open the operating system app settings page so the user can grant notifications, battery, or background permissions.',
      properties: const {},
      executionMode: AiToolExecutionMode.stateChanging,
      handler: (_) async =>
          jsonEncode(await provider.clientSystemToolService.openAppSettings()),
    ),
    AiTool(
      name: 'client_set_clipboard',
      description:
          'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Copy text to the client clipboard.',
      properties: {'text': _string('Text to place on the client clipboard.')},
      required: const ['text'],
      executionMode: AiToolExecutionMode.stateChanging,
      handler: (args) => _clientSetClipboard(provider, service, args),
    ),
    AiTool(
      name: 'client_save_experience_skill',
      description:
          'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Save a summarized user experience into a local AI skill so it can be reused by future chats.',
      properties: {
        'summary': _string(
          'Mandatory summarized experience text. Keep it concise, ideally 1-3 short lines.',
        ),
        'title': _string(
          'Optional short skill title. If omitted, a title is generated automatically.',
        ),
        'content': _string(
          'Optional detailed content such as steps, caveats, commands, and lessons.',
        ),
        'references': {
          'type': 'array',
          'description':
              'Optional structured list of references containing description/title and concrete rule content.',
          'items': {
            'type': 'object',
            'properties': {
              'title': _string('The title or purpose of this reference.'),
              'content': _string(
                'The detailed instructions or commands of this reference.',
              ),
            },
            'required': const ['title', 'content'],
          },
        },
      },
      required: const ['summary'],
      executionMode: AiToolExecutionMode.stateChanging,
      handler: (args) => _clientSaveExperienceSkill(
        provider,
        service,
        args,
        approvedWrite: false,
      ),
    ),
    AiTool(
      name: 'client_list_skills',
      description:
          'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. List all saved local AI experience skills/notes that future chat sessions can load or reuse.',
      properties: const {},
      executionMode: AiToolExecutionMode.readOnly,
      handler: (args) => _clientListSkills(provider, service, args),
    ),
    AiTool(
      name: 'client_update_skill',
      description:
          'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Update an existing saved AI experience skill/note by id.',
      properties: {
        'skillId': _string(
          'The unique skillId of the experience skill/note to update.',
        ),
        'name': _string('Optional new short title for the skill.'),
        'description': _string(
          'Optional new concise summary of the experience.',
        ),
        'content': _string(
          'Optional new detailed content, commands, or lessons.',
        ),
        'enabled': _bool('Optional flag to enable/disable the skill.'),
        'references': {
          'type': 'array',
          'description':
              'Optional new structured list of references containing description/title and concrete rule content.',
          'items': {
            'type': 'object',
            'properties': {
              'title': _string('The title or purpose of this reference.'),
              'content': _string(
                'The detailed instructions or commands of this reference.',
              ),
            },
            'required': const ['title', 'content'],
          },
        },
      },
      required: const ['skillId'],
      executionMode: AiToolExecutionMode.stateChanging,
      handler: (arguments) => _clientUpdateSkill(
        provider,
        service,
        arguments,
        approvedWrite: false,
      ),
    ),
    AiTool(
      name: 'client_set_alarm',
      description:
          'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Set a client-side alarm or reminder.',
      properties: {
        'triggerAt': _string(
          'Optional local ISO-8601 datetime, or a 24-hour time like 08:30.',
        ),
        'delaySeconds': _int('Optional delay in seconds.'),
        'delayMinutes': _int('Optional delay in minutes.'),
        'label': _string('Optional alarm or reminder label.'),
        'useSystemAlarm': _bool(
          'Optional. Default true. On Android request a system Clock alarm when supported.',
        ),
      },
      executionMode: AiToolExecutionMode.stateChanging,
      handler: (args) => _clientSetAlarm(provider, service, args),
    ),
    AiTool(
      name: 'client_list_alarms',
      description:
          'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. List in-app client reminders created by client_set_alarm during this app process.',
      properties: const {},
      handler: (_) async =>
          jsonEncode(await provider.clientSystemToolService.listAlarms()),
    ),
    AiTool(
      name: 'client_cancel_alarm',
      description:
          'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Cancel an in-app client reminder created by client_set_alarm.',
      properties: {
        'alarmId': _string('Alarm id returned by client_set_alarm.'),
      },
      required: const ['alarmId'],
      executionMode: AiToolExecutionMode.stateChanging,
      handler: (args) => _clientCancelAlarm(provider, service, args),
    ),
    AiTool(
      name: 'client_query_logs',
      description:
          'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Read recent redacted app logs from this client for SSH, SFTP, LLM, AI tool, WebView, and background diagnostics.',
      properties: {
        'level': {
          'type': 'string',
          // 日志筛选使用稳定字符串，避免 AI Package 依赖 App Shell 的展示枚举。
          'enum': const [
            'all',
            'error',
            'warning',
            'info',
            'service',
            'debug',
            'flutter',
            'platform',
            'app',
          ],
          'description': 'Optional log level filter. Defaults to all.',
        },
        'contains': _string(
          'Optional case-insensitive text filter that matches the redacted log text.',
        ),
        'limit': _int(
          'Maximum number of newest-first log entries to return. Defaults to 50.',
          minimum: 1,
          maximum: 200,
          defaultValue: 50,
        ),
      },
      capabilities: const {AiToolCapability.client, AiToolCapability.logs},
      cacheTtl: const Duration(seconds: 8),
      handler: (args) => _clientQueryLogs(provider, service, args),
    ),
    AiTool(
      name: 'client_get_log_counts',
      description:
          'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Return redacted app log counts grouped by level.',
      properties: const {},
      handler: (_) async =>
          jsonEncode(await provider.clientSystemToolService.getLogCounts()),
    ),
    AiTool(
      name: 'client_delete_log_entries',
      description:
          'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Delete specific client log entries by id. This changes local app state and requires user approval.',
      properties: {
        'ids': _intArray('Log entry ids to delete.', minimumItems: 1),
      },
      required: const ['ids'],
      executionMode: AiToolExecutionMode.stateChanging,
      handler: (arguments) => _clientDeleteLogEntries(
        provider,
        service,
        arguments,
        approvedWrite: false,
      ),
    ),
    AiTool(
      name: 'client_clear_logs',
      description:
          'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Clear all client log entries. This changes local app state and requires user approval.',
      properties: const {},
      executionMode: AiToolExecutionMode.stateChanging,
      handler: (arguments) =>
          _clientClearLogs(provider, service, arguments, approvedWrite: false),
    ),
    AiTool(
      name: 'client_export_app_backup',
      description:
          'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Export a credential-free app backup file to the client device. The tool saves the file locally and returns only summary metadata.',
      properties: const {},
      executionMode: AiToolExecutionMode.stateChanging,
      handler: (args) => _clientExportAppBackup(provider, service, args),
    ),
    AiTool(
      name: 'client_import_app_backup',
      description:
          'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Import an app backup file chosen through the client file picker. Credential fields in the backup are ignored and never exposed to the model. This replaces local saved data and requires user approval.',
      properties: const {},
      executionMode: AiToolExecutionMode.stateChanging,
      handler: (arguments) => _clientImportAppBackup(
        provider,
        service,
        arguments,
        approvedWrite: false,
      ),
    ),
    AiTool(
      name: 'client_webview_get_page_text',
      description:
          'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Read visible plain text from the WebView page bound to the current chat session.',
      properties: {
        'maxChars': _int(
          'Optional maximum characters to return. Defaults to 40000 and is capped at 100000.',
        ),
      },
      requiresWebViewSession: true,
      capabilities: const {AiToolCapability.web, AiToolCapability.client},
      handler: (args) => _clientWebViewGetPageText(provider, service, args),
    ),
    AiTool(
      name: 'client_webview_get_state',
      description:
          'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Get the current WebView state for the page bound to this chat session.',
      properties: const {},
      requiresWebViewSession: true,
      capabilities: const {AiToolCapability.web, AiToolCapability.client},
      handler: (args) => _clientWebViewGetState(provider, service, args),
    ),
    AiTool(
      name: 'client_webview_navigate',
      description:
          'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Navigate the current chat session WebView using open, back, forward, or refresh without interrupting an active AI-browsing lock.',
      properties: {
        'action': {
          'type': 'string',
          'enum': const ['open', 'back', 'forward', 'refresh'],
          'description': 'Navigation action to perform.',
        },
        'input': _string(
          'Required when action=open. Accepts an HTTP(S) URL or search query.',
        ),
      },
      required: const ['action'],
      executionMode: AiToolExecutionMode.stateChanging,
      requiresWebViewSession: true,
      capabilities: const {AiToolCapability.web, AiToolCapability.client},
      handler: (args) => _clientWebViewNavigate(provider, service, args),
    ),
    AiTool(
      name: 'app_get_operational_settings',
      description:
          'Return app operational settings that affect tools and server operations, including SFTP limits, secret-cache settings, AI timeout, web-search settings, multi-agent settings, and the per-request tool call budget. Does not reveal API keys.',
      properties: const {},
      handler: (args) => _appGetOperationalSettings(provider, service, args),
    ),
    AiTool(
      name: 'app_update_operational_settings',
      description:
          'Update app operational settings that affect tools and server operations, including SFTP limits, secret-cache settings, AI timeout, web-search settings, multi-agent settings, and the per-request tool call budget. This changes local app state and requires user approval.',
      properties: {
        'sftpDownloadLimitBytes': _int(
          'Optional SFTP download limit in bytes.',
        ),
        'sftpTextEditLimitBytes': _int(
          'Optional SFTP text edit limit in bytes.',
        ),
        'secretCacheEnabled': _bool(
          'Optional in-memory secret cache enabled flag.',
        ),
        'secretCacheTtlMinutes': _int(
          'Optional in-memory secret cache TTL in minutes.',
        ),
        'aiRequestTimeoutSeconds': _int(
          'Optional AI request timeout in seconds.',
        ),
        'webSearchEnabled': _bool('Optional AI web search enabled flag.'),
        'webSearchMaxResults': _int(
          'Optional AI web search max results setting.',
        ),
        'multiAgentEnabled': _bool(
          'Optional automatic multi-agent collaboration flag.',
        ),
        'postToolReviewEnabled': _bool(
          'Optional post-tool recovery review agent flag.',
        ),
        'multiAgentMaxAgents': _int(
          'Optional maximum helper agents for automatic multi-agent collaboration.',
          minimum: AiMultiAgentMaxAgents.values.first,
          maximum: AiMultiAgentMaxAgents.values.last,
        ),
        'toolCallBudget': _int(
          'Optional default per-request tool call budget before budget guardrails extend or audit the run.',
          minimum: AiToolCallBudget.values.first,
          maximum: AiToolCallBudget.values.last,
        ),
      },
      executionMode: AiToolExecutionMode.stateChanging,
      handler: (arguments) => _appUpdateOperationalSettings(
        provider,
        service,
        arguments,
        approvedWrite: false,
      ),
    ),
    AiTool(
      name: 'app_clear_secret_cache',
      description:
          'Clear the in-memory secret cache for saved SSH credentials and the active LLM API key without revealing any secret values.',
      properties: const {},
      executionMode: AiToolExecutionMode.stateChanging,
      handler: (args) => _appClearSecretCache(provider, service, args),
    ),
    AiTool(
      name: 'client_set_plan_mode',
      description:
          'CLIENT tool. Toggle Plan Mode for the active chat thread. Set enabled=true to enter read-only planning when you need to replan. Set enabled=false to exit to execution mode ONLY after you have outlined a structured step-by-step execution plan beforehand.',
      properties: {
        'enabled': _bool(
          'true to enter plan mode, false to exit to execution mode.',
        ),
      },
      required: const ['enabled'],
      executionMode: AiToolExecutionMode.planControl,
      preferredInPlanMode: true,
      capabilities: const {AiToolCapability.planning, AiToolCapability.client},
      handler: (args) => _clientSetPlanMode(provider, service, args),
    ),
    AiTool(
      name: 'client_task_create',
      description:
          'CLIENT tool. Create a new step in the chat-bound TODO execution plan for the current request. This tool is ONLY allowed during Plan Mode (read-only stage). Returns a generated unique taskId. Complex planning flows may also persist todoSteps from a valid ```playbook JSON block without calling this tool. This does not create a saved reusable Playbook record.',
      properties: {
        'name': _string('The name/title of the planned step.'),
        'command': _string(
          'The exact shell/remote command recommended for execution in this step.',
        ),
        'description': _string(
          'The purpose or explanation of what this step accomplishes.',
        ),
        'connectionId': _string(
          'Optional. The unique connectionId of the server to execute this step on. Use list_servers to find available ids.',
        ),
      },
      required: const ['name'],
      executionMode: AiToolExecutionMode.planOnly,
      preferredInPlanMode: true,
      capabilities: const {AiToolCapability.planning, AiToolCapability.client},
      handler: (args) => _clientTaskCreate(provider, service, args),
    ),
    AiTool(
      name: 'client_task_update',
      description:
          'CLIENT tool. Update the execution status and output logs of a planned TODO task. This tool is ONLY allowed during Execution Mode, and only for pre-existing taskIds. Use running as the canonical in-progress status; the legacy alias in_progress is still accepted.',
      properties: {
        'taskId': _string('The unique taskId of the step to update.'),
        'status': {
          'type': 'string',
          'enum': const ['pending', 'running', 'success', 'failed', 'skipped'],
          'description':
              'The new execution status of the step. The legacy alias in_progress is still accepted.',
        },
        'stdout': _string(
          'Optional stdout log response from executing the command.',
        ),
        'stderr': _string('Optional stderr log response if execution failed.'),
        'reason': _string(
          'Required when status is skipped. Explain why skipping this step is safe.',
        ),
        'errorSummary': _string(
          'Optional summary of the error when status is failed.',
        ),
      },
      required: const ['taskId', 'status'],
      executionMode: AiToolExecutionMode.executionOnly,
      capabilities: const {AiToolCapability.planning, AiToolCapability.client},
      handler: (args) => _clientTaskUpdate(provider, service, args),
    ),
    AiTool(
      name: 'client_task_retry',
      description:
          'CLIENT tool. Reset a failed step in the execution plan back to pending so that it can be retried. This tool is ONLY allowed during Execution Mode.',
      properties: {
        'taskId': _string('The unique taskId of the failed step to retry.'),
        'reason': _string('Optional explanation or reason for the retry.'),
      },
      required: const ['taskId'],
      executionMode: AiToolExecutionMode.executionOnly,
      capabilities: const {AiToolCapability.planning, AiToolCapability.client},
      handler: (args) => _clientTaskRetry(provider, service, args),
    ),
    AiTool(
      name: 'client_task_skip',
      description:
          'CLIENT tool. Skip a pending or failed step in the execution plan. Skipping is only allowed if a reason is provided. This tool is ONLY allowed during Execution Mode.',
      properties: {
        'taskId': _string('The unique taskId of the step to skip.'),
        'reason': _string(
          'Clear justification of why it is safe to skip this step.',
        ),
      },
      required: const ['taskId', 'reason'],
      executionMode: AiToolExecutionMode.executionOnly,
      capabilities: const {AiToolCapability.planning, AiToolCapability.client},
      // Approval-aware tools must be executed through AiToolService.execute,
      // which routes to provider.execute with the approvedWrite flag.
      // This handler fallback intentionally passes approvedWrite=false so
      // direct handler invocation cannot bypass approval.
      handler: (args) =>
          _clientTaskSkip(provider, service, args, approvedWrite: false),
    ),
  ];
}
