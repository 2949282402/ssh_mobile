import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/connection.dart';
import '../models/playbook.dart';
import 'app_log_service.dart';
import 'app_settings.dart';
import 'client_system_tool_service.dart';
import 'client_webview_service.dart';
import 'multi_agent_coordinator.dart';
import 'performance_monitor_tool_service.dart';
import 'playbook_service.dart';
import 'server_catalog_service.dart';
import 'server_diagnostics_service.dart';
import 'sftp_service.dart';
import 'ssh_service.dart';
import 'storage_service.dart';
import 'tool_secret_policy.dart';

part 'ai_tool/ai_tool_types.dart';
part 'ai_tool/client_tools.dart';
part 'ai_tool/server_tools.dart';
part 'ai_tool/ssh_tools.dart';
part 'ai_tool/sftp_tools.dart';
part 'ai_tool/monitor_tools.dart';
part 'ai_tool/playbook_tools.dart';
part 'ai_tool/security_policy.dart';

class AiToolService implements AiToolExecutor {
  static const String _clientScopeId = 'client';
  static const String _clientScopeName = 'SSH Mobile client';
  static const int _maxToolTextChars = 12000;

  final StorageService storageService;
  final SshClientAdapter sshService;
  final SftpClientAdapter sftpService;
  final ClientSystemToolAdapter clientSystemToolService;
  final ClientWebViewAdapter clientWebViewService;
  final ServerCatalogAdapter serverCatalogService;
  final PerformanceMonitorToolAdapter performanceMonitorToolService;
  final ServerDiagnosticsAdapter serverDiagnosticsService;
  final ToolSecretPolicy secretPolicy;
  final AppSettings? appSettings;
  final PlaybookService? playbookService;
  final String? clientWebViewSessionId;

  AiToolService({
    required this.storageService,
    required this.sshService,
    required this.sftpService,
    ClientSystemToolAdapter? clientSystemToolService,
    ClientWebViewAdapter? clientWebViewService,
    ServerCatalogAdapter? serverCatalogService,
    PerformanceMonitorToolAdapter? performanceMonitorToolService,
    ServerDiagnosticsAdapter? serverDiagnosticsService,
    ToolSecretPolicy? secretPolicy,
    this.appSettings,
    this.playbookService,
    this.clientWebViewSessionId,
  })  : clientSystemToolService =
            clientSystemToolService ?? ClientSystemToolService.instance,
        clientWebViewService =
            clientWebViewService ?? ClientWebViewService.instance,
        serverCatalogService = serverCatalogService ??
            ServerCatalogService(
              storageService: storageService,
              sshService: sshService,
              sftpService: sftpService,
            ),
        performanceMonitorToolService = performanceMonitorToolService ??
            const _UnavailablePerformanceMonitorToolService(),
        serverDiagnosticsService = serverDiagnosticsService ??
            ServerDiagnosticsService(
              storageService: storageService,
              sshService: sshService,
            ),
        secretPolicy = secretPolicy ?? const ToolSecretPolicy();

  @override
  Future<List<AiTool>> tools() async {
    final searchSettings = await storageService.loadAiConnectionSettings();
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
          handler: _webSearch,
        ),
      AiTool(
        name: 'client_get_time',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Get the client system time, UTC time, timezone, and locale.',
        properties: const {},
        handler: (_) async =>
            jsonEncode(clientSystemToolService.getClientTime()),
      ),
      AiTool(
        name: 'client_get_device_info',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Get client OS/platform, locale, timezone, hostname, CPU count, and supported client integrations.',
        properties: const {},
        handler: (_) async =>
            jsonEncode(clientSystemToolService.getClientDeviceInfo()),
      ),
      AiTool(
        name: 'client_get_network_info',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Get client network status such as connectivity, transport, Wi-Fi details where available, and proxy or VPN indicators.',
        properties: const {},
        handler: (_) async =>
            jsonEncode(await clientSystemToolService.getNetworkInfo()),
      ),
      AiTool(
        name: 'client_get_battery_status',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Get client battery level, charging state, battery saver, and app battery-optimization exemption status where available.',
        properties: const {},
        handler: (_) async =>
            jsonEncode(await clientSystemToolService.getBatteryStatus()),
      ),
      AiTool(
        name: 'client_get_permission_status',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Get client notification permission, background-service support, and Android battery-optimization exemption status where available.',
        properties: const {},
        handler: (_) async =>
            jsonEncode(await clientSystemToolService.getPermissionStatus()),
      ),
      AiTool(
        name: 'client_open_app_settings',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Open the operating system app settings page so the user can grant notifications, battery, or background permissions.',
        properties: const {},
        handler: (_) async =>
            jsonEncode(await clientSystemToolService.openAppSettings()),
      ),
      AiTool(
        name: 'client_set_clipboard',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Copy text to the client clipboard.',
        properties: {
          'text': _string('Text to place on the client clipboard.'),
        },
        required: const ['text'],
        handler: _clientSetClipboard,
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
        },
        required: const ['summary'],
        handler: _clientSaveExperienceSkill,
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
        handler: _clientSetAlarm,
      ),
      AiTool(
        name: 'client_list_alarms',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. List in-app client reminders created by client_set_alarm during this app process.',
        properties: const {},
        handler: (_) async =>
            jsonEncode(await clientSystemToolService.listAlarms()),
      ),
      AiTool(
        name: 'client_cancel_alarm',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Cancel an in-app client reminder created by client_set_alarm.',
        properties: {
          'alarmId': _string('Alarm id returned by client_set_alarm.'),
        },
        required: const ['alarmId'],
        handler: _clientCancelAlarm,
      ),
      AiTool(
        name: 'client_query_logs',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Read recent redacted app logs from this client for SSH, SFTP, LLM, AI tool, WebView, and background diagnostics.',
        properties: {
          'level': {
            'type': 'string',
            'enum': AppLogLevel.values.map((item) => item.name).toList(),
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
        handler: _clientQueryLogs,
      ),
      AiTool(
        name: 'client_get_log_counts',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Return redacted app log counts grouped by level.',
        properties: const {},
        handler: (_) async =>
            jsonEncode(await clientSystemToolService.getLogCounts()),
      ),
      AiTool(
        name: 'client_delete_log_entries',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Delete specific client log entries by id. This changes local app state and requires user approval.',
        properties: {
          'ids': _intArray('Log entry ids to delete.', minimumItems: 1),
        },
        required: const ['ids'],
        handler: (arguments) => _clientDeleteLogEntries(
          arguments,
          approvedWrite: false,
        ),
      ),
      AiTool(
        name: 'client_clear_logs',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Clear all client log entries. This changes local app state and requires user approval.',
        properties: const {},
        handler: (arguments) =>
            _clientClearLogs(arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'client_export_app_backup',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Export a credential-free app backup file to the client device. The tool saves the file locally and returns only summary metadata.',
        properties: const {},
        handler: _clientExportAppBackup,
      ),
      AiTool(
        name: 'client_import_app_backup',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Import an app backup file chosen through the client file picker. Credential fields in the backup are ignored and never exposed to the model. This replaces local saved data and requires user approval.',
        properties: const {},
        handler: (arguments) => _clientImportAppBackup(
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
        handler: _clientWebViewGetPageText,
      ),
      AiTool(
        name: 'client_webview_get_state',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Get the current WebView state for the page bound to this chat session.',
        properties: const {},
        handler: _clientWebViewGetState,
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
        handler: _clientWebViewNavigate,
      ),
      AiTool(
        name: 'list_servers',
        description: 'List saved SSH servers. Does not reveal credentials.',
        properties: const {},
        handler: (_) async =>
            jsonEncode({'servers': serverCatalogService.listServerSummaries()}),
      ),
      AiTool(
        name: 'get_server_details',
        description:
            'Get saved non-sensitive metadata for one SSH server, including session overview. Does not reveal credentials.',
        properties: {
          'connectionId': _string('Server connection id.'),
        },
        required: const ['connectionId'],
        handler: _getServerDetails,
      ),
      AiTool(
        name: 'update_server_metadata',
        description:
            'Update non-sensitive server metadata such as name, host, port, username, group, launch mode, platform, keep-alive settings, terminal size, or jump-host metadata. Passwords, private keys, and API keys are never readable or writable. This change requires user approval.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'name': _string('Optional server display name.'),
          'host': _string('Optional server hostname or IP address.'),
          'port': _int('Optional SSH port.'),
          'username': _string('Optional SSH username.'),
          'group': _string('Optional server group name.'),
          'serverPlatform': {
            'type': 'string',
            'enum': ServerPlatform.values.map((item) => item.name).toList(),
            'description': 'Optional saved server platform.',
          },
          'launchMode': {
            'type': 'string',
            'enum': TerminalLaunchMode.values.map((item) => item.name).toList(),
            'description': 'Optional terminal launch mode.',
          },
          'tmuxAutoDeleteSeconds': _int(
            'Optional tmux auto-delete idle timeout in seconds.',
          ),
          'keepAlive': _bool('Optional keep-alive enabled flag.'),
          'keepAliveInterval': _int(
            'Optional keep-alive interval in seconds.',
          ),
          'terminalWidth': _int('Optional default terminal width.'),
          'terminalHeight': _int('Optional default terminal height.'),
          'jumpHost': _string('Optional jump host hostname.'),
          'jumpPort': _int('Optional jump host port.'),
          'jumpUsername': _string('Optional jump host username.'),
        },
        required: const ['connectionId'],
        handler: (arguments) => _updateServerMetadata(
          arguments,
          approvedWrite: false,
        ),
      ),
      AiTool(
        name: 'delete_server',
        description:
            'Delete one saved SSH server from the client app. Credentials stored for that server are also removed locally. This is destructive and requires user approval.',
        properties: {
          'connectionId': _string('Server connection id.'),
        },
        required: const ['connectionId'],
        handler: (arguments) => _deleteServer(arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'reorder_servers',
        description:
            'Reorder the saved SSH servers by providing the full ordered server id list. This changes local app state and requires user approval.',
        properties: {
          'orderedIds': _stringArray(
            'Every saved server id exactly once, in the desired order.',
            minimumItems: 1,
          ),
        },
        required: const ['orderedIds'],
        handler: (arguments) => _reorderServers(
          arguments,
          approvedWrite: false,
        ),
      ),
      AiTool(
        name: 'ssh_list_sessions',
        description:
            'List current SSH terminal sessions and their metadata without exposing raw terminal output.',
        properties: {
          'connectionId': _string('Optional server connection id filter.'),
        },
        handler: _sshListSessions,
      ),
      AiTool(
        name: 'ssh_open_session',
        description:
            'Open a new SSH terminal session using the saved server credentials. Returns session metadata only.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'displayName': _string('Optional display name for the new session.'),
        },
        required: const ['connectionId'],
        handler: _sshOpenSession,
      ),
      AiTool(
        name: 'ssh_ensure_session_connected',
        description:
            'Ensure an existing SSH terminal session is connected. Returns session metadata only.',
        properties: {
          'sessionId': _string('Existing session id.'),
          'connectionId': _string('Server connection id for that session.'),
        },
        required: const ['sessionId', 'connectionId'],
        handler: _sshEnsureSessionConnected,
      ),
      AiTool(
        name: 'ssh_rename_session',
        description:
            'Rename an SSH terminal session display name. Returns session metadata only.',
        properties: {
          'sessionId': _string('Existing session id.'),
          'name': _string('New display name.'),
        },
        required: const ['sessionId', 'name'],
        handler: _sshRenameSession,
      ),
      AiTool(
        name: 'ssh_close_session',
        description:
            'Close one SSH terminal session. Returns session metadata only.',
        properties: {
          'sessionId': _string('Existing session id.'),
        },
        required: const ['sessionId'],
        handler: _sshCloseSession,
      ),
      AiTool(
        name: 'ssh_close_server_sessions',
        description:
            'Close all SSH terminal sessions for one server connection id.',
        properties: {
          'connectionId': _string('Server connection id.'),
        },
        required: const ['connectionId'],
        handler: _sshCloseServerSessions,
      ),
      AiTool(
        name: 'ssh_restore_tmux_sessions',
        description:
            'Restore saved tmux-backed SSH sessions after an app restart. Returns summary metadata only.',
        properties: const {},
        handler: _sshRestoreTmuxSessions,
      ),
      AiTool(
        name: 'ssh_list_terminal_history',
        description:
            'List saved terminal history records by metadata only. Does not expose raw terminal output.',
        properties: {
          'connectionId': _string('Optional server connection id filter.'),
          'limit': _int(
            'Maximum number of records to return. Defaults to 50.',
            minimum: 1,
            maximum: 200,
            defaultValue: 50,
          ),
        },
        handler: _sshListTerminalHistory,
      ),
      AiTool(
        name: 'ssh_delete_terminal_history_record',
        description:
            'Delete one saved terminal history record by session id. Does not access raw terminal output.',
        properties: {
          'sessionId': _string('Terminal history session id.'),
        },
        required: const ['sessionId'],
        handler: _sshDeleteTerminalHistoryRecord,
      ),
      AiTool(
        name: 'detect_os',
        description:
            'Detect whether a selected SSH server is Windows or Linux or Unix before choosing OS-specific commands.',
        properties: {
          'connectionId': _string('Server connection id.'),
        },
        required: const ['connectionId'],
        handler: _detectOsTool,
      ),
      AiTool(
        name: 'run_command',
        description:
            'Run a shell command on a selected server. The saved server platform is enforced: use Linux or POSIX commands only on Linux servers, and explicit cmd /c or PowerShell diagnostics only on Windows servers. Delete commands, environment dumps, and commands that reference secret-bearing paths are blocked.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'command': _string(
            'Shell command to run. On Windows use explicit cmd /c or powershell or pwsh read-only diagnostics. On Linux use POSIX or Linux commands such as uname, ps, ss, df, cat.',
          ),
        },
        required: const ['connectionId', 'command'],
        handler: (arguments) => _runCommand(arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'sftp_list_dir',
        description:
            'List a remote directory through detached SFTP. Secret-bearing paths are blocked by the tool secret policy.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string('Remote directory path. Defaults to ".".'),
        },
        required: const ['connectionId'],
        handler: _listDir,
      ),
      AiTool(
        name: 'sftp_get_entry_info',
        description:
            'Get detached SFTP metadata for one remote path. Secret-bearing paths are blocked by the tool secret policy.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string('Remote path.'),
        },
        required: const ['connectionId', 'path'],
        handler: _sftpGetEntryInfo,
      ),
      AiTool(
        name: 'sftp_read_text',
        description:
            'Read a small remote text file through detached SFTP. Binary and large files are rejected. Secret-bearing paths are blocked.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string('Remote text file path.'),
        },
        required: const ['connectionId', 'path'],
        handler: _readText,
      ),
      AiTool(
        name: 'sftp_download_file',
        description:
            'Download a remote file through detached SFTP and save it to the client device running SSH Mobile. The tool returns save metadata, not file content. Secret-bearing paths are blocked.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string('Remote file path.'),
        },
        required: const ['connectionId', 'path'],
        handler: _sftpDownloadFile,
      ),
      AiTool(
        name: 'sftp_write_text',
        description:
            'Write a text file through detached SFTP by replacing or creating the remote file. This changes remote state, requires user approval, and is blocked on secret-bearing paths.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string('Remote text file path.'),
          'content': _string('Full text content to write to the remote file.'),
        },
        required: const ['connectionId', 'path', 'content'],
        handler: (arguments) => _sftpWriteText(arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'sftp_upload_local_file',
        description:
            'Pick a local client file and upload it to a remote path through detached SFTP. This changes remote state, requires user approval, and is blocked on secret-bearing paths.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string(
            'Remote destination path. If it ends with "/" the picked local filename is appended.',
          ),
        },
        required: const ['connectionId', 'path'],
        handler: (arguments) => _sftpUploadLocalFile(
          arguments,
          approvedWrite: false,
        ),
      ),
      AiTool(
        name: 'sftp_create_directory',
        description:
            'Create a remote directory through detached SFTP. This changes remote state, requires user approval, and is blocked on secret-bearing paths.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string('Remote directory path to create.'),
        },
        required: const ['connectionId', 'path'],
        handler: (arguments) => _sftpCreateDirectory(
          arguments,
          approvedWrite: false,
        ),
      ),
      AiTool(
        name: 'sftp_rename_entry',
        description:
            'Rename or move a remote file or directory through detached SFTP. This changes remote state, requires user approval, and is blocked on secret-bearing paths.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string('Current remote path.'),
          'newPath': _string('New remote path.'),
        },
        required: const ['connectionId', 'path', 'newPath'],
        handler: (arguments) => _sftpRenameEntry(
          arguments,
          approvedWrite: false,
        ),
      ),
      AiTool(
        name: 'sftp_delete_entry',
        description:
            'Delete a remote file or empty directory through detached SFTP. This is destructive, requires user approval, and is blocked on secret-bearing paths.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string('Remote file or directory path.'),
        },
        required: const ['connectionId', 'path'],
        handler: (arguments) => _sftpDeleteEntry(
          arguments,
          approvedWrite: false,
        ),
      ),
      AiTool(
        name: 'get_server_status',
        description:
            'Get read-only server status for diagnostics. Modes: performance, ports, applications, or all.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'mode': _string(
            'Status mode: performance, ports, applications, or all. Defaults to all.',
          ),
        },
        required: const ['connectionId'],
        handler: _serverStatus,
      ),
      AiTool(
        name: 'generate_ops_report',
        description:
            'Collect read-only server status and return an operations report payload with health score, risks, ports, applications, and suggested next checks.',
        properties: {
          'connectionId': _string('Server connection id.'),
        },
        required: const ['connectionId'],
        handler: _opsReport,
      ),
      AiTool(
        name: 'monitor_get_state',
        description:
            'Return the app-scoped performance monitor state for selected servers, running status, effective intervals, alerts, and health snapshots.',
        properties: const {},
        handler: _monitorGetState,
      ),
      AiTool(
        name: 'monitor_set_selected_servers',
        description:
            'Replace the performance monitor selected server set. This changes app monitor state and requires user approval.',
        properties: {
          'connectionIds': _stringArray(
            'Server connection ids to select for performance monitoring.',
            minimumItems: 1,
          ),
        },
        required: const ['connectionIds'],
        handler: (arguments) => _monitorSetSelectedServers(
          arguments,
          approvedWrite: false,
        ),
      ),
      AiTool(
        name: 'monitor_clear_selection',
        description:
            'Clear the performance monitor selected server set. This changes app monitor state and requires user approval.',
        properties: const {},
        handler: (arguments) =>
            _monitorClearSelection(arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'monitor_start',
        description:
            'Start the app-scoped performance monitor for the currently selected servers. This changes app monitor state and requires user approval.',
        properties: const {},
        handler: (arguments) => _monitorStart(arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'monitor_stop',
        description:
            'Stop the app-scoped performance monitor. This changes app monitor state and requires user approval.',
        properties: const {},
        handler: (arguments) => _monitorStop(arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'monitor_stop_for_connection',
        description:
            'Stop the app-scoped performance monitor for one connection id. This changes app monitor state and requires user approval.',
        properties: {
          'connectionId': _string('Server connection id.'),
        },
        required: const ['connectionId'],
        handler: (arguments) => _monitorStopForConnection(
          arguments,
          approvedWrite: false,
        ),
      ),
      AiTool(
        name: 'monitor_set_interval',
        description:
            'Set the app-scoped performance monitor sampling interval in seconds. This changes app monitor state and requires user approval.',
        properties: {
          'seconds': _int('Sampling interval in seconds.', minimum: 2),
        },
        required: const ['seconds'],
        handler: (arguments) =>
            _monitorSetInterval(arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'monitor_set_history_window',
        description:
            'Set the app-scoped performance monitor history window in seconds. This changes app monitor state and requires user approval.',
        properties: {
          'seconds': _int('History window in seconds.', minimum: 30),
        },
        required: const ['seconds'],
        handler: (arguments) =>
            _monitorSetHistoryWindow(arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'monitor_get_health',
        description:
            'Return current performance monitor health snapshots for one or more server connection ids.',
        properties: {
          'connectionIds': _stringArray(
            'Optional subset of server connection ids. Omit to return all monitor health snapshots.',
          ),
        },
        handler: _monitorGetHealth,
      ),
      AiTool(
        name: 'monitor_get_samples',
        description:
            'Return recent performance monitor samples for one server connection id.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'visibleOnly': _bool(
            'Optional. Default true. When true, return only samples inside the current history window.',
          ),
          'limit': _int(
            'Optional maximum number of newest samples to return. Defaults to 100.',
            minimum: 1,
            maximum: 500,
            defaultValue: 100,
          ),
        },
        required: const ['connectionId'],
        handler: _monitorGetSamples,
      ),
      AiTool(
        name: 'monitor_get_alerts',
        description:
            'Return recent performance monitor alerts across all monitored servers.',
        properties: {
          'limit': _int(
            'Optional maximum number of newest alerts to return. Defaults to 50.',
            minimum: 1,
            maximum: 200,
            defaultValue: 50,
          ),
        },
        handler: _monitorGetAlerts,
      ),
      AiTool(
        name: 'monitor_get_ports',
        description:
            'Return current listening ports and owning processes for one server using the existing performance monitor diagnostics path.',
        properties: {
          'connectionId': _string('Server connection id.'),
        },
        required: const ['connectionId'],
        handler: _monitorGetPorts,
      ),
      AiTool(
        name: 'monitor_get_applications',
        description:
            'Return current top applications or processes for one server using the existing performance monitor diagnostics path.',
        properties: {
          'connectionId': _string('Server connection id.'),
        },
        required: const ['connectionId'],
        handler: _monitorGetApplications,
      ),
      AiTool(
        name: 'app_get_operational_settings',
        description:
            'Return app operational settings that affect tools and server operations, including SFTP limits, secret-cache settings, AI timeout, web-search settings, and multi-agent settings. Does not reveal API keys.',
        properties: const {},
        handler: _appGetOperationalSettings,
      ),
      AiTool(
        name: 'app_update_operational_settings',
        description:
            'Update app operational settings that affect tools and server operations, including SFTP limits, secret-cache settings, AI timeout, web-search settings, and multi-agent settings. This changes local app state and requires user approval.',
        properties: {
          'sftpDownloadLimitBytes':
              _int('Optional SFTP download limit in bytes.'),
          'sftpTextEditLimitBytes':
              _int('Optional SFTP text edit limit in bytes.'),
          'secretCacheEnabled':
              _bool('Optional in-memory secret cache enabled flag.'),
          'secretCacheTtlMinutes': _int(
            'Optional in-memory secret cache TTL in minutes.',
          ),
          'aiRequestTimeoutSeconds':
              _int('Optional AI request timeout in seconds.'),
          'webSearchEnabled': _bool('Optional AI web search enabled flag.'),
          'webSearchMaxResults': _int(
            'Optional AI web search max results setting.',
          ),
          'multiAgentEnabled':
              _bool('Optional automatic multi-agent collaboration flag.'),
          'multiAgentMaxAgents': _int(
            'Optional maximum helper agents for automatic multi-agent collaboration.',
            minimum: AiMultiAgentMaxAgents.values.first,
            maximum: AiMultiAgentMaxAgents.values.last,
          ),
        },
        handler: (arguments) => _appUpdateOperationalSettings(
          arguments,
          approvedWrite: false,
        ),
      ),
      AiTool(
        name: 'app_clear_secret_cache',
        description:
            'Clear the in-memory secret cache for saved SSH credentials and the active LLM API key without revealing any secret values.',
        properties: const {},
        handler: _appClearSecretCache,
      ),
      AiTool(
        name: 'list_playbooks',
        description:
            'CLIENT tool. List all saved custom sequential task playbooks/scripts, including step names and commands.',
        properties: const {},
        handler: _listPlaybooksTool,
      ),
      AiTool(
        name: 'create_playbook',
        description:
            'CLIENT tool. Create a new visual sequential task playbook in storage. This updates local client data and requires user approval.',
        properties: {
          'name': _string('The display name for the playbook.'),
          'description':
              _string('A short description of what this playbook does.'),
          'steps': {
            'type': 'array',
            'description': 'The ordered list of steps to execute.',
            'items': {
              'type': 'object',
              'properties': {
                'name': _string('The step display name.'),
                'description': _string('What this step accomplishes.'),
                'command': _string(
                    'The multiline shell command/script to run via SSH exec.'),
                'expectedOutcomeRegex': _string(
                    'Optional regex pattern that the stdout must match to succeed.'),
              },
              'required': const ['name', 'description', 'command'],
            },
          },
        },
        required: const ['name', 'description', 'steps'],
        handler: (arguments) =>
            _createPlaybookTool(arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'run_playbook',
        description:
            'CLIENT tool. Trigger the async sequential execution of a saved playbook on a remote SSH server connection. This changes server state and requires user approval.',
        properties: {
          'playbookId': _string('The saved playbook ID.'),
          'connectionId': _string('The remote SSH server connection ID.'),
        },
        required: const ['playbookId', 'connectionId'],
        handler: (arguments) =>
            _runPlaybookTool(arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'get_playbook_status',
        description:
            'CLIENT tool. Query the active or latest execution status of a playbook, including live step results, exit codes, and stdout/stderr.',
        properties: {
          'playbookId': _string('The playbook ID to query.'),
        },
        required: const ['playbookId'],
        handler: _getPlaybookStatusTool,
      ),
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async {
    return (await tools()).map((tool) => tool.definition).toList();
  }

  @override
  AiCommandReview reviewCommand(
    String command, {
    ServerPlatform? platform,
  }) {
    final normalized = command.trim().toLowerCase();
    if (normalized.isEmpty) {
      return const AiCommandReview.blocked('Command is empty.');
    }
    final secretBlockReason = secretPolicy.blockedCommandReason(command);
    if (secretBlockReason != null) {
      return AiCommandReview.blocked(secretBlockReason);
    }
    final deletionReason = _deletionCommandBlockReason(normalized);
    if (deletionReason != null) {
      return AiCommandReview.blocked(deletionReason);
    }
    const blockedFragments = [
      'sudo -s',
      'sudo su',
      ' su ',
      'su -',
      'passwd',
      'sshpass',
      'password=',
      'private key',
    ];
    if (blockedFragments.any(normalized.contains)) {
      return const AiCommandReview.blocked(
        'This command asks for elevated shells, passwords, or secret handling.',
      );
    }
    switch (platform) {
      case ServerPlatform.windows:
        return _reviewWindowsCommand(normalized);
      case ServerPlatform.linux:
        return _reviewLinuxCommand(normalized);
      case null:
        return const AiCommandReview.blocked(
          'Server platform is unknown. Configure the server as Linux or Windows before running commands.',
        );
    }
  }

  @override
  AiToolApprovalRequest? approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) {
    switch (name) {
      case 'run_command':
        final connectionId = _arg(arguments, 'connectionId');
        final command = _arg(arguments, 'command');
        final config = storageService.getConnection(connectionId);
        final review = reviewCommand(command, platform: config?.serverPlatform);
        if (!review.requiresApproval) return null;
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'remote_write',
          connectionId: connectionId,
          connectionName: config?.name ?? connectionId,
          command: secretPolicy.previewText(command, maxChars: 240),
          reason: review.reason,
        );
      case 'sftp_write_text':
        final connectionId = _arg(arguments, 'connectionId');
        final path = _arg(arguments, 'path');
        final content = _arg(arguments, 'content');
        final config = storageService.getConnection(connectionId);
        final bytes = utf8.encode(content).length;
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'remote_write',
          connectionId: connectionId,
          connectionName: config?.name ?? connectionId,
          command: 'SFTP WRITE $path ($bytes bytes)',
          reason: 'Remote file write requires user approval.',
          targetPath: path,
          byteLength: bytes,
          contentPreview: secretPolicy.previewText(content, maxChars: 200),
        );
      case 'sftp_upload_local_file':
        return _remoteApproval(
          toolName: name,
          arguments: arguments,
          summaryBuilder: (connectionId, path) => 'SFTP UPLOAD $path',
          reason: 'Remote file upload requires user approval.',
        );
      case 'sftp_create_directory':
        return _remoteApproval(
          toolName: name,
          arguments: arguments,
          summaryBuilder: (connectionId, path) => 'SFTP MKDIR $path',
          reason: 'Remote directory creation requires user approval.',
        );
      case 'sftp_rename_entry':
        final connectionId = _arg(arguments, 'connectionId');
        final path = _arg(arguments, 'path');
        final newPath = _arg(arguments, 'newPath');
        final config = storageService.getConnection(connectionId);
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'remote_write',
          connectionId: connectionId,
          connectionName: config?.name ?? connectionId,
          command: 'SFTP RENAME $path -> $newPath',
          reason: 'Remote rename or move requires user approval.',
          targetPath: path,
        );
      case 'sftp_delete_entry':
        return _remoteApproval(
          toolName: name,
          arguments: arguments,
          approvalType: 'remote_delete',
          destructive: true,
          summaryBuilder: (connectionId, path) => 'SFTP DELETE $path',
          reason: 'Remote delete requires user approval.',
        );
      case 'update_server_metadata':
        final connectionId = _arg(arguments, 'connectionId');
        final config = storageService.getConnection(connectionId);
        final keys = arguments.keys
            .where((key) => key != 'connectionId')
            .toList(growable: false);
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'server_metadata_change',
          connectionId: connectionId,
          connectionName: config?.name ?? connectionId,
          command: 'UPDATE SERVER METADATA (${keys.join(', ')})',
          reason: 'Server metadata changes require user approval.',
          contentPreview: keys.isEmpty ? null : keys.join(', '),
        );
      case 'delete_server':
        final connectionId = _arg(arguments, 'connectionId');
        final config = storageService.getConnection(connectionId);
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'server_metadata_change',
          connectionId: connectionId,
          connectionName: config?.name ?? connectionId,
          command: 'DELETE SAVED SERVER ${config?.name ?? connectionId}',
          reason: 'Deleting a saved server requires user approval.',
          destructive: true,
        );
      case 'reorder_servers':
        final orderedIds = _stringList(arguments['orderedIds']);
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'server_metadata_change',
          connectionId: _clientScopeId,
          connectionName: _clientScopeName,
          command: 'REORDER SERVERS (${orderedIds.length})',
          reason: 'Reordering saved servers requires user approval.',
          contentPreview: orderedIds.join(', '),
        );
      case 'client_delete_log_entries':
        final ids = _intList(arguments['ids']);
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'local_log_change',
          connectionId: _clientScopeId,
          connectionName: _clientScopeName,
          command: 'DELETE CLIENT LOG ENTRIES (${ids.length})',
          reason: 'Deleting client logs requires user approval.',
          destructive: true,
          contentPreview: ids.join(', '),
        );
      case 'client_clear_logs':
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'local_log_change',
          connectionId: _clientScopeId,
          connectionName: _clientScopeName,
          command: 'CLEAR CLIENT LOGS',
          reason: 'Clearing client logs requires user approval.',
          destructive: true,
        );
      case 'client_import_app_backup':
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'local_import',
          connectionId: _clientScopeId,
          connectionName: _clientScopeName,
          command: 'IMPORT APP BACKUP',
          reason:
              'Importing a backup replaces local saved data. Credential fields remain ignored.',
          destructive: true,
        );
      case 'monitor_set_selected_servers':
        final ids = _stringList(arguments['connectionIds']);
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'monitor_state_change',
          connectionId: _clientScopeId,
          connectionName: _clientScopeName,
          command: 'MONITOR SELECT (${ids.length})',
          reason: 'Changing monitor selection requires user approval.',
          contentPreview: ids.join(', '),
        );
      case 'monitor_clear_selection':
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'monitor_state_change',
          connectionId: _clientScopeId,
          connectionName: _clientScopeName,
          command: 'MONITOR CLEAR SELECTION',
          reason: 'Changing monitor selection requires user approval.',
        );
      case 'monitor_start':
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'monitor_state_change',
          connectionId: _clientScopeId,
          connectionName: _clientScopeName,
          command: 'MONITOR START',
          reason: 'Starting performance monitoring requires user approval.',
        );
      case 'monitor_stop':
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'monitor_state_change',
          connectionId: _clientScopeId,
          connectionName: _clientScopeName,
          command: 'MONITOR STOP',
          reason: 'Stopping performance monitoring requires user approval.',
        );
      case 'monitor_stop_for_connection':
        final connectionId = _arg(arguments, 'connectionId');
        final config = storageService.getConnection(connectionId);
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'monitor_state_change',
          connectionId: connectionId,
          connectionName: config?.name ?? connectionId,
          command: 'MONITOR STOP FOR ${config?.name ?? connectionId}',
          reason: 'Changing monitor state requires user approval.',
        );
      case 'monitor_set_interval':
        final seconds = _argInt(arguments, 'seconds');
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'monitor_state_change',
          connectionId: _clientScopeId,
          connectionName: _clientScopeName,
          command: 'MONITOR SET INTERVAL ${seconds}s',
          reason: 'Changing monitor sampling settings requires user approval.',
        );
      case 'monitor_set_history_window':
        final seconds = _argInt(arguments, 'seconds');
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'monitor_state_change',
          connectionId: _clientScopeId,
          connectionName: _clientScopeName,
          command: 'MONITOR SET HISTORY ${seconds}s',
          reason: 'Changing monitor history settings requires user approval.',
        );
      case 'app_update_operational_settings':
        final keys = arguments.keys.toList(growable: false);
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'app_setting_change',
          connectionId: _clientScopeId,
          connectionName: _clientScopeName,
          command: 'UPDATE APP SETTINGS (${keys.join(', ')})',
          reason: 'Changing app operational settings requires user approval.',
          contentPreview: keys.isEmpty
              ? null
              : secretPolicy.previewText(
                  jsonEncode(
                    secretPolicy.redactValue(
                      arguments,
                      truncateLongStrings: true,
                      maxChars: 80,
                    ),
                  ),
                  maxChars: 200,
                ),
        );
      case 'create_playbook':
        final playbookName = _arg(arguments, 'name');
        final steps = arguments['steps'] as List? ?? [];
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'playbook_create',
          connectionId: _clientScopeId,
          connectionName: _clientScopeName,
          command: 'CREATE PLAYBOOK: "$playbookName" (${steps.length} steps)',
          reason: 'Creating a custom playbook requires user approval.',
          contentPreview: _arg(arguments, 'description'),
        );
      case 'run_playbook':
        final playbookId = _arg(arguments, 'playbookId');
        final connectionId = _arg(arguments, 'connectionId');
        final config = storageService.getConnection(connectionId);
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'playbook_run',
          connectionId: connectionId,
          connectionName: config?.name ?? connectionId,
          command: 'RUN PLAYBOOK ID: $playbookId',
          reason:
              'Executing sequential commands on a server requires user approval.',
        );
      default:
        return null;
    }
  }

  AiToolApprovalRequest _remoteApproval({
    required String toolName,
    required Map<String, dynamic> arguments,
    String approvalType = 'remote_write',
    bool destructive = false,
    required String Function(String connectionId, String path) summaryBuilder,
    required String reason,
  }) {
    final connectionId = _arg(arguments, 'connectionId');
    final path = _arg(arguments, 'path');
    final config = storageService.getConnection(connectionId);
    return AiToolApprovalRequest(
      toolName: toolName,
      approvalType: approvalType,
      connectionId: connectionId,
      connectionName: config?.name ?? connectionId,
      command: summaryBuilder(connectionId, path),
      reason: reason,
      targetPath: path,
      destructive: destructive,
    );
  }

  @override
  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async {
    final availableTools = await tools();
    for (final tool in availableTools) {
      if (tool.name != name) continue;
      final startedAt = DateTime.now();
      AppLogService.instance.info(
        'AI tool started',
        details:
            'tool=$name args=${secretPolicy.safeJson(arguments, truncateLongStrings: true)}',
      );
      try {
        final rawResult = switch (name) {
          'run_command' => await _runCommand(
              arguments,
              approvedWrite: approvedWrite,
            ),
          'client_delete_log_entries' => await _clientDeleteLogEntries(
              arguments,
              approvedWrite: approvedWrite,
            ),
          'client_clear_logs' => await _clientClearLogs(
              arguments,
              approvedWrite: approvedWrite,
            ),
          'client_import_app_backup' => await _clientImportAppBackup(
              arguments,
              approvedWrite: approvedWrite,
            ),
          'update_server_metadata' => await _updateServerMetadata(
              arguments,
              approvedWrite: approvedWrite,
            ),
          'delete_server' => await _deleteServer(
              arguments,
              approvedWrite: approvedWrite,
            ),
          'reorder_servers' => await _reorderServers(
              arguments,
              approvedWrite: approvedWrite,
            ),
          'sftp_write_text' => await _sftpWriteText(
              arguments,
              approvedWrite: approvedWrite,
            ),
          'sftp_upload_local_file' => await _sftpUploadLocalFile(
              arguments,
              approvedWrite: approvedWrite,
            ),
          'sftp_create_directory' => await _sftpCreateDirectory(
              arguments,
              approvedWrite: approvedWrite,
            ),
          'sftp_rename_entry' => await _sftpRenameEntry(
              arguments,
              approvedWrite: approvedWrite,
            ),
          'sftp_delete_entry' => await _sftpDeleteEntry(
              arguments,
              approvedWrite: approvedWrite,
            ),
          'monitor_set_selected_servers' => await _monitorSetSelectedServers(
              arguments,
              approvedWrite: approvedWrite,
            ),
          'monitor_clear_selection' => await _monitorClearSelection(
              arguments,
              approvedWrite: approvedWrite,
            ),
          'monitor_start' => await _monitorStart(
              arguments,
              approvedWrite: approvedWrite,
            ),
          'monitor_stop' => await _monitorStop(
              arguments,
              approvedWrite: approvedWrite,
            ),
          'monitor_stop_for_connection' => await _monitorStopForConnection(
              arguments,
              approvedWrite: approvedWrite,
            ),
          'monitor_set_interval' => await _monitorSetInterval(
              arguments,
              approvedWrite: approvedWrite,
            ),
          'monitor_set_history_window' => await _monitorSetHistoryWindow(
              arguments,
              approvedWrite: approvedWrite,
            ),
          'client_save_experience_skill' =>
            await _clientSaveExperienceSkill(arguments),
          'app_update_operational_settings' =>
            await _appUpdateOperationalSettings(
              arguments,
              approvedWrite: approvedWrite,
            ),
          'list_playbooks' => await _listPlaybooksTool(arguments),
          'create_playbook' => await _createPlaybookTool(
              arguments,
              approvedWrite: approvedWrite,
            ),
          'run_playbook' => await _runPlaybookTool(
              arguments,
              approvedWrite: approvedWrite,
            ),
          'get_playbook_status' => await _getPlaybookStatusTool(arguments),
          _ => await tool.handler(arguments),
        };
        final result = secretPolicy.redactJsonText(rawResult);
        AppLogService.instance.info(
          'AI tool completed',
          details:
              'tool=$name elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} resultChars=${result.length}',
        );
        return result;
      } catch (e, stackTrace) {
        AppLogService.instance.error(
          'AI tool failed',
          error: e,
          stackTrace: stackTrace,
          details:
              'tool=$name args=${secretPolicy.safeJson(arguments, truncateLongStrings: true)}',
        );
        rethrow;
      }
    }
    AppLogService.instance.warning('Unknown AI tool requested', details: name);
    return jsonEncode({'error': 'Unknown tool: $name'});
  }

  static Map<String, dynamic> _string(String description) {
    return {'type': 'string', 'description': description};
  }

  static Map<String, dynamic> _int(
    String description, {
    int? minimum,
    int? maximum,
    int? defaultValue,
  }) {
    return {
      'type': 'integer',
      'description': description,
      if (minimum != null) 'minimum': minimum,
      if (maximum != null) 'maximum': maximum,
      if (defaultValue != null) 'default': defaultValue,
    };
  }

  static Map<String, dynamic> _bool(String description) {
    return {'type': 'boolean', 'description': description};
  }

  static Map<String, dynamic> _stringArray(
    String description, {
    int? minimumItems,
  }) {
    return {
      'type': 'array',
      'description': description,
      'items': {'type': 'string'},
      if (minimumItems != null) 'minItems': minimumItems,
    };
  }

  static Map<String, dynamic> _intArray(
    String description, {
    int? minimumItems,
  }) {
    return {
      'type': 'array',
      'description': description,
      'items': {'type': 'integer'},
      if (minimumItems != null) 'minItems': minimumItems,
    };
  }
}
