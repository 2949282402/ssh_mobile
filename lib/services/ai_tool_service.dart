import 'dart:async';
import 'dart:convert';

import '../models/connection.dart';
import 'app_log_service.dart';
import 'app_settings.dart';
import 'client_system_tool_service.dart';
import 'client_webview_service.dart';
import 'multi_agent_coordinator.dart';
import 'performance_monitor_tool_service.dart';
import 'server_catalog_service.dart';
import 'server_diagnostics_service.dart';
import 'sftp_service.dart';
import 'ssh_service.dart';
import 'storage_service.dart';
import 'tool_secret_policy.dart';

abstract interface class AiToolExecutor {
  Future<List<AiTool>> tools();

  Future<List<Map<String, dynamic>>> toolDefinitions();

  AiToolApprovalRequest? approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  );

  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  });

  AiCommandReview reviewCommand(
    String command, {
    ServerPlatform? platform,
  });
}

class AiToolService implements AiToolExecutor {
  static const String _clientScopeId = 'client';
  static const String _clientScopeName = 'SSH Mobile client';

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
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async {
    return (await tools()).map((tool) => tool.definition).toList();
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

  Future<String> _webSearch(Map<String, dynamic> arguments) async {
    final settings = await storageService.loadAiConnectionSettings();
    if (!settings.webSearchEnabled) {
      return jsonEncode({
        'execution': 'client',
        'target': 'client_webview',
        'provider': 'local_webview',
        'error': 'Web search is not enabled in LLM settings.',
      });
    }
    final chatId = clientWebViewSessionId;
    if (chatId == null || chatId.trim().isEmpty) {
      return jsonEncode(_missingChatSessionPayload());
    }
    final query = _arg(arguments, 'query');
    final limit = _webSearchLimit(arguments['limit'], settings);
    final result = await clientWebViewService.searchWeb(
      chatId,
      query,
      maxResults: limit,
    );
    return jsonEncode(result.toJson());
  }

  int _webSearchLimit(Object? requestedLimit, AiConnectionSettings settings) {
    final configuredLimit = AiWebSearchMaxResults.normalize(
      settings.webSearchMaxResults,
    );
    final parsedLimit = switch (requestedLimit) {
      num value => value.toInt(),
      String value => int.tryParse(value.trim()),
      _ => null,
    };
    return (parsedLimit ?? configuredLimit).clamp(1, configuredLimit).toInt();
  }

  Future<String> _clientSetAlarm(Map<String, dynamic> arguments) async {
    final result = await clientSystemToolService.setAlarm(
      triggerAt: _optionalString(arguments, 'triggerAt'),
      delaySeconds: _optionalInt(arguments, 'delaySeconds'),
      delayMinutes: _optionalInt(arguments, 'delayMinutes'),
      label: _optionalString(arguments, 'label'),
      useSystemAlarm: _optionalBool(arguments, 'useSystemAlarm') ?? true,
    );
    return jsonEncode(result);
  }

  Future<String> _clientCancelAlarm(Map<String, dynamic> arguments) async {
    return jsonEncode(
      await clientSystemToolService.cancelAlarm(_arg(arguments, 'alarmId')),
    );
  }

  Future<String> _clientSetClipboard(Map<String, dynamic> arguments) async {
    return jsonEncode(
      await clientSystemToolService.setClipboard(_arg(arguments, 'text')),
    );
  }

  Future<String> _clientSaveExperienceSkill(
    Map<String, dynamic> arguments,
  ) async {
    final summary = _arg(arguments, 'summary');
    final conciseSummary = _coerceConciseSkillSummary(summary);
    final title = _optionalString(arguments, 'title') ??
        _defaultExperienceSkillTitle(conciseSummary);
    final details = _optionalString(arguments, 'content');
    final now = DateTime.now();
    final record = AiSkillRecord(
      id: 'skill-${now.microsecondsSinceEpoch}',
      name: title,
      description: conciseSummary,
      content: details == null || details.trim().isEmpty
          ? conciseSummary
          : '$summary\n\n${details.trim()}',
      createdAt: now,
      updatedAt: now,
    );
    await storageService.saveAiSkill(record);
    AppLogService.instance.info(
      'AI experience skill saved',
      details:
          'skillId=${record.id} name=${secretPolicy.previewText(record.name)}',
    );
    return jsonEncode({
      'execution': 'client',
      'target': 'local_skill',
      'saved': true,
      'skillId': record.id,
      'name': record.name,
      'description': record.description,
    });
  }

  String _defaultExperienceSkillTitle(String summary) {
    final lines = summary
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.isEmpty) return 'Experience note';
    final firstLine = lines.first;
    if (firstLine.length <= 30) return firstLine;
    return '${firstLine.substring(0, 27).trim()}...';
  }

  String _coerceConciseSkillSummary(String summary) {
    final normalized = summary.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= 140) {
      return normalized;
    }
    final head = normalized.substring(0, 140).trim();
    final lastWordBoundary = head.lastIndexOf(' ');
    final truncated = lastWordBoundary >= 72
        ? head.substring(0, lastWordBoundary).trim()
        : head;
    return '$truncated…';
  }

  Future<String> _clientQueryLogs(Map<String, dynamic> arguments) async {
    final result = await clientSystemToolService.queryLogs(
      level: _optionalString(arguments, 'level'),
      contains: _optionalString(arguments, 'contains'),
      limit: _optionalInt(arguments, 'limit') ?? 50,
    );
    return jsonEncode(result);
  }

  Future<String> _clientDeleteLogEntries(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Deleting client log entries requires user approval.',
      });
    }
    final ids = _intList(arguments['ids']);
    return jsonEncode(await clientSystemToolService.deleteLogEntries(ids));
  }

  Future<String> _clientClearLogs(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Clearing client logs requires user approval.',
      });
    }
    return jsonEncode(await clientSystemToolService.clearLogs());
  }

  Future<String> _clientExportAppBackup(Map<String, dynamic> arguments) async {
    final jsonText = await storageService.exportAppDataJson();
    final now = DateTime.now();
    final fileName =
        'ssh_mobile_backup_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}.json';
    final saveResult = await clientSystemToolService.saveBytesToFile(
      fileName: fileName,
      bytes: utf8.encode(jsonText),
      dialogTitle: 'Export app backup',
    );
    return jsonEncode({
      ...saveResult,
      'backupSummary': _summarizeBackupJson(jsonText),
      'note':
          'Backup content was saved to the client device. Secrets and API keys are omitted from the exported file.',
    });
  }

  Future<String> _clientImportAppBackup(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Importing an app backup requires user approval.',
      });
    }
    final picked = await clientSystemToolService.pickFile(
      allowedExtensions: const ['json'],
      dialogTitle: 'Import app backup',
    );
    if (picked == null) {
      return jsonEncode({
        'execution': 'client',
        'target': 'app_backup',
        'imported': false,
        'cancelled': true,
        'note': 'The user cancelled the local file picker.',
      });
    }
    final jsonText = utf8.decode(picked.bytes);
    final summary = _summarizeBackupJson(jsonText);
    await storageService.importAppDataJson(jsonText);
    return jsonEncode({
      'execution': 'client',
      'target': 'app_backup',
      'imported': true,
      'cancelled': false,
      'fileName': picked.name,
      'bytes': picked.bytes.length,
      'summary': summary,
      'credentialFieldsIgnored': true,
    });
  }

  Future<String> _clientWebViewGetPageText(
    Map<String, dynamic> arguments,
  ) async {
    final chatId = clientWebViewSessionId;
    final maxChars = _optionalInt(arguments, 'maxChars') ??
        ClientWebViewService.defaultMaxChars;
    if (chatId == null || chatId.trim().isEmpty) {
      return jsonEncode(_missingChatSessionPayload());
    }
    final result = await clientWebViewService.readPlainText(
      chatId,
      maxChars: maxChars,
    );
    return jsonEncode(result.toJson());
  }

  Future<String> _clientWebViewGetState(Map<String, dynamic> arguments) async {
    final chatId = clientWebViewSessionId;
    if (chatId == null || chatId.trim().isEmpty) {
      return jsonEncode(_missingChatSessionPayload());
    }
    return jsonEncode((await clientWebViewService.getState(chatId)).toJson());
  }

  Future<String> _clientWebViewNavigate(Map<String, dynamic> arguments) async {
    final chatId = clientWebViewSessionId;
    if (chatId == null || chatId.trim().isEmpty) {
      return jsonEncode(_missingChatSessionPayload());
    }
    final result = await clientWebViewService.navigate(
      chatId,
      action: _arg(arguments, 'action'),
      input: _optionalString(arguments, 'input'),
    );
    return jsonEncode(result.toJson());
  }

  Map<String, dynamic> _missingChatSessionPayload() {
    return {
      'execution': 'client',
      'target': 'client_webview',
      'provider': 'local_webview',
      'hasPage': false,
      'error':
          'No current chat session is bound to this tool call. Open or use the WebView from the current AI chat first.',
    };
  }

  Future<String> _getServerDetails(Map<String, dynamic> arguments) async {
    final details = serverCatalogService.getServerDetails(
      _arg(arguments, 'connectionId'),
    );
    if (details == null) {
      return jsonEncode({'error': 'Connection config not found.'});
    }
    return jsonEncode(details);
  }

  Future<String> _updateServerMetadata(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Server metadata changes require user approval.',
      });
    }
    final connectionId = _arg(arguments, 'connectionId');
    final changes = Map<String, dynamic>.from(arguments)
      ..remove('connectionId');
    if (changes.isEmpty) {
      return jsonEncode({
        'updated': false,
        'error': 'No metadata fields were provided to update.',
      });
    }
    return jsonEncode(
      await serverCatalogService.updateServerMetadata(
        connectionId: connectionId,
        changes: changes,
      ),
    );
  }

  Future<String> _deleteServer(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Deleting a saved server requires user approval.',
      });
    }
    return jsonEncode(
      await serverCatalogService.deleteServer(_arg(arguments, 'connectionId')),
    );
  }

  Future<String> _reorderServers(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Reordering saved servers requires user approval.',
      });
    }
    return jsonEncode(
      await serverCatalogService.reorderServers(
        _stringList(arguments['orderedIds']),
      ),
    );
  }

  Future<String> _sshListSessions(Map<String, dynamic> arguments) async {
    final filterConnectionId = _optionalString(arguments, 'connectionId');
    final sessions = sshService.sessions
        .where((session) {
          return filterConnectionId == null ||
              session.connectionId == filterConnectionId;
        })
        .map(_sshSessionToJson)
        .toList(growable: false);
    return jsonEncode({
      'sessions': sessions,
      'serverOverview': {
        'windowCount': sshService.serverOverviewSnapshot.windowCount,
        'byConnection': {
          for (final entry
              in sshService.serverOverviewSnapshot.byConnection.entries)
            entry.key: {
              'count': entry.value.count,
              'latestState': entry.value.latestState?.name,
              'hasConnected': entry.value.hasConnected,
            },
        },
      },
    });
  }

  Future<String> _sshOpenSession(Map<String, dynamic> arguments) async {
    final connectionId = _arg(arguments, 'connectionId');
    final sessionId = await sshService.openSession(
      connectionId,
      displayName: _optionalString(arguments, 'displayName'),
    );
    final session = sessionId == null ? null : sshService.getSession(sessionId);
    return jsonEncode({
      'opened': sessionId != null,
      'connectionId': connectionId,
      'session': session == null ? null : _sshSessionToJson(session),
      if (sessionId == null)
        'error': sshService.errorMessage ?? 'Unable to open session.',
    });
  }

  Future<String> _sshEnsureSessionConnected(
      Map<String, dynamic> arguments) async {
    final sessionId = _arg(arguments, 'sessionId');
    final connectionId = _arg(arguments, 'connectionId');
    final connected = await sshService.ensureSessionConnected(
      sessionId,
      connectionId,
    );
    final session = sshService.getSession(sessionId);
    return jsonEncode({
      'connected': connected,
      'session': session == null ? null : _sshSessionToJson(session),
    });
  }

  Future<String> _sshRenameSession(Map<String, dynamic> arguments) async {
    final sessionId = _arg(arguments, 'sessionId');
    final renamed =
        sshService.renameSession(sessionId, _arg(arguments, 'name'));
    final session = sshService.getSession(sessionId);
    return jsonEncode({
      'renamed': renamed,
      'session': session == null ? null : _sshSessionToJson(session),
    });
  }

  Future<String> _sshCloseSession(Map<String, dynamic> arguments) async {
    final sessionId = _arg(arguments, 'sessionId');
    await sshService.disconnectSession(sessionId);
    return jsonEncode({
      'closed': true,
      'sessionId': sessionId,
    });
  }

  Future<String> _sshCloseServerSessions(Map<String, dynamic> arguments) async {
    final connectionId = _arg(arguments, 'connectionId');
    await sshService.disconnectSessionsForConnection(connectionId);
    return jsonEncode({
      'closed': true,
      'connectionId': connectionId,
    });
  }

  Future<String> _sshRestoreTmuxSessions(Map<String, dynamic> arguments) async {
    await sshService.restoreTmuxSessions();
    return jsonEncode({
      'restored': true,
      'sessions': sshService.sessions.map(_sshSessionToJson).toList(),
    });
  }

  Future<String> _sshListTerminalHistory(Map<String, dynamic> arguments) async {
    final connectionId = _optionalString(arguments, 'connectionId');
    final limit = _optionalInt(arguments, 'limit') ?? 50;
    var records = await sshService.loadTerminalHistoryRecords();
    if (connectionId != null) {
      records = records
          .where((record) => record.connectionId == connectionId)
          .toList(growable: false);
    }
    final visible = records.take(limit).map(_terminalHistoryToJson).toList();
    return jsonEncode({
      'records': visible,
      'returned': visible.length,
      'limit': limit,
      'truncated': records.length > visible.length,
    });
  }

  Future<String> _sshDeleteTerminalHistoryRecord(
    Map<String, dynamic> arguments,
  ) async {
    final sessionId = _arg(arguments, 'sessionId');
    await sshService.removeTerminalHistoryRecord(sessionId);
    return jsonEncode({
      'deleted': true,
      'sessionId': sessionId,
    });
  }

  Future<String> _runCommand(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    final connectionId = _arg(arguments, 'connectionId');
    final command = _arg(arguments, 'command');
    final config = storageService.getConnection(connectionId);
    if (config == null) {
      return jsonEncode({
        'error': 'Connection config not found.',
        'connectionId': connectionId,
      });
    }
    final review = reviewCommand(command, platform: config.serverPlatform);
    if (review.blocked) {
      return jsonEncode({
        'error': review.reason,
        'serverPlatform': config.serverPlatform.name,
        'command': secretPolicy.previewText(command, maxChars: 240),
      });
    }
    if (review.requiresApproval && !approvedWrite) {
      return jsonEncode({
        'error': 'Write command requires user approval before execution.',
        'serverPlatform': config.serverPlatform.name,
        'command': secretPolicy.previewText(command, maxChars: 240),
      });
    }
    final timeoutSeconds = await storageService.getAiRequestTimeoutSeconds();
    late final RemoteCommandResult result;
    try {
      result = await sshService.runOneShotCommand(
        connectionId: connectionId,
        command: command,
        timeout: Duration(seconds: timeoutSeconds),
      );
    } on TimeoutException {
      return jsonEncode({
        'error':
            'Command timed out after $timeoutSeconds seconds. Narrow the command or search path and try again.',
        'serverPlatform': config.serverPlatform.name,
      });
    }
    if (config.serverPlatform == ServerPlatform.windows &&
        _hasWindowsPermissionProblem(result.stdout, result.stderr)) {
      return jsonEncode({
        'exitCode': result.exitCode,
        'serverPlatform': config.serverPlatform.name,
        'permissionError': true,
        'error': _windowsPermissionMessage,
        'stdout': _truncate(result.stdout),
        'stderr': _truncate(result.stderr),
      });
    }
    return jsonEncode({
      'exitCode': result.exitCode,
      'serverPlatform': config.serverPlatform.name,
      'stdout': _truncate(result.stdout),
      'stderr': _truncate(result.stderr),
    });
  }

  Future<String> _detectOsTool(Map<String, dynamic> arguments) async {
    return jsonEncode(
      await serverDiagnosticsService.detectOs(_arg(arguments, 'connectionId')),
    );
  }

  Future<String> _listDir(Map<String, dynamic> arguments) async {
    final connectionId = _arg(arguments, 'connectionId');
    final path = _optionalString(arguments, 'path') ?? '.';
    final blocked = _secretPathBlocked(path);
    if (blocked != null) return blocked;
    final entries =
        await sftpService.listDirectoryForConnection(connectionId, path);
    return jsonEncode({
      'path': path,
      'entries': entries
          .take(200)
          .map(
            (entry) => {
              'name': entry.name,
              'path': entry.path,
              'type': entry.isDirectory ? 'directory' : 'file',
              'isLink': entry.isLink,
              'size': entry.size,
              'sizeLabel': entry.sizeLabel,
              'modifiedAt': entry.modifiedAt?.toIso8601String(),
              'modifiedLabel': entry.modifiedLabel,
            },
          )
          .toList(),
      if (entries.length > 200) 'truncated': true,
    });
  }

  Future<String> _sftpGetEntryInfo(Map<String, dynamic> arguments) async {
    final path = _arg(arguments, 'path');
    final blocked = _secretPathBlocked(path);
    if (blocked != null) return blocked;
    final info = await sftpService.statPathForConnection(
      connectionId: _arg(arguments, 'connectionId'),
      path: path,
    );
    return jsonEncode(info.toJson());
  }

  Future<String> _readText(Map<String, dynamic> arguments) async {
    final connectionId = _arg(arguments, 'connectionId');
    final path = _arg(arguments, 'path');
    final blocked = _secretPathBlocked(path);
    if (blocked != null) return blocked;
    final text = await sftpService.readTextPathForConnection(
      connectionId: connectionId,
      path: path,
    );
    return jsonEncode({
      'path': path,
      'content': _truncate(text),
      'truncated': text.length > _maxToolTextChars,
    });
  }

  Future<String> _sftpDownloadFile(Map<String, dynamic> arguments) async {
    final connectionId = _arg(arguments, 'connectionId');
    final path = _arg(arguments, 'path');
    final blocked = _secretPathBlocked(path);
    if (blocked != null) return blocked;
    final bytes = await sftpService.downloadPathForConnection(
      connectionId: connectionId,
      path: path,
      maxBytes: _sftpDownloadLimitBytes,
    );
    final saveResult = await clientSystemToolService.saveBytesToFile(
      fileName: _remoteFileName(path),
      bytes: bytes,
      dialogTitle: 'Download file',
    );
    return jsonEncode({
      ...saveResult,
      'remotePath': path,
    });
  }

  Future<String> _sftpWriteText(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    final connectionId = _arg(arguments, 'connectionId');
    final path = _arg(arguments, 'path');
    final content = _arg(arguments, 'content');
    final blocked = _secretPathBlocked(path);
    if (blocked != null) return blocked;
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Remote file write requires user approval before execution.',
        'path': path,
      });
    }
    final bytes = utf8.encode(content).length;
    await sftpService.writeTextPathForConnection(
      connectionId: connectionId,
      path: path,
      text: content,
      maxBytes: _sftpTextEditLimitBytes,
    );
    return jsonEncode({
      'path': path,
      'bytes': bytes,
      'written': true,
    });
  }

  Future<String> _sftpUploadLocalFile(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    final connectionId = _arg(arguments, 'connectionId');
    final path = _arg(arguments, 'path');
    final blocked = _secretPathBlocked(path);
    if (blocked != null) return blocked;
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Remote file upload requires user approval before execution.',
        'path': path,
      });
    }
    final picked = await clientSystemToolService.pickFile(
      dialogTitle: 'Upload local file',
    );
    if (picked == null) {
      return jsonEncode({
        'uploaded': false,
        'cancelled': true,
        'note': 'The user cancelled the local file picker.',
      });
    }
    final remotePath = _resolveRemoteUploadPath(path, picked.name);
    final remoteBlocked = _secretPathBlocked(remotePath);
    if (remoteBlocked != null) return remoteBlocked;
    await sftpService.uploadBytesPathForConnection(
      connectionId: connectionId,
      path: remotePath,
      bytes: picked.bytes,
    );
    return jsonEncode({
      'uploaded': true,
      'cancelled': false,
      'remotePath': remotePath,
      'fileName': picked.name,
      'bytes': picked.bytes.length,
    });
  }

  Future<String> _sftpCreateDirectory(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    final connectionId = _arg(arguments, 'connectionId');
    final path = _arg(arguments, 'path');
    final blocked = _secretPathBlocked(path);
    if (blocked != null) return blocked;
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Remote directory creation requires user approval.',
        'path': path,
      });
    }
    await sftpService.createDirectoryPathForConnection(
      connectionId: connectionId,
      path: path,
    );
    return jsonEncode({
      'created': true,
      'path': path,
    });
  }

  Future<String> _sftpRenameEntry(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    final connectionId = _arg(arguments, 'connectionId');
    final path = _arg(arguments, 'path');
    final newPath = _arg(arguments, 'newPath');
    final blocked = _secretPathBlocked(path) ?? _secretPathBlocked(newPath);
    if (blocked != null) return blocked;
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Remote rename or move requires user approval.',
        'path': path,
        'newPath': newPath,
      });
    }
    await sftpService.renamePathForConnection(
      connectionId: connectionId,
      path: path,
      newPath: newPath,
    );
    return jsonEncode({
      'renamed': true,
      'path': path,
      'newPath': newPath,
    });
  }

  Future<String> _sftpDeleteEntry(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    final connectionId = _arg(arguments, 'connectionId');
    final path = _arg(arguments, 'path');
    final blocked = _secretPathBlocked(path);
    if (blocked != null) return blocked;
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Remote delete requires user approval.',
        'path': path,
      });
    }
    await sftpService.deletePathForConnection(
      connectionId: connectionId,
      path: path,
    );
    return jsonEncode({
      'deleted': true,
      'path': path,
    });
  }

  Future<String> _serverStatus(Map<String, dynamic> arguments) async {
    final connectionId = _arg(arguments, 'connectionId');
    final mode = _optionalString(arguments, 'mode')?.toLowerCase();
    return jsonEncode(
      await serverDiagnosticsService.getStatus(
        connectionId: connectionId,
        mode: mode,
      ),
    );
  }

  Future<String> _opsReport(Map<String, dynamic> arguments) async {
    return jsonEncode(
      await serverDiagnosticsService.generateOpsReport(
        _arg(arguments, 'connectionId'),
      ),
    );
  }

  Future<String> _monitorGetState(Map<String, dynamic> arguments) async {
    return jsonEncode(performanceMonitorToolService.getState());
  }

  Future<String> _monitorSetSelectedServers(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Changing monitor selection requires user approval.',
      });
    }
    final ids = _stringList(arguments['connectionIds']);
    for (final id in ids) {
      if (storageService.getConnection(id) == null) {
        throw StateError('Unknown connection id: $id');
      }
    }
    return jsonEncode(performanceMonitorToolService.setSelectedServers(ids));
  }

  Future<String> _monitorClearSelection(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Changing monitor selection requires user approval.',
      });
    }
    return jsonEncode(performanceMonitorToolService.clearSelection());
  }

  Future<String> _monitorStart(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Starting performance monitoring requires user approval.',
      });
    }
    return jsonEncode(await performanceMonitorToolService.start());
  }

  Future<String> _monitorStop(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Stopping performance monitoring requires user approval.',
      });
    }
    return jsonEncode(performanceMonitorToolService.stop());
  }

  Future<String> _monitorStopForConnection(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Changing monitor state requires user approval.',
      });
    }
    return jsonEncode(
      performanceMonitorToolService.stopForConnection(
        _arg(arguments, 'connectionId'),
      ),
    );
  }

  Future<String> _monitorSetInterval(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Changing monitor sampling settings requires user approval.',
      });
    }
    final seconds = _argInt(arguments, 'seconds').clamp(2, 300);
    return jsonEncode(
      performanceMonitorToolService.setInterval(Duration(seconds: seconds)),
    );
  }

  Future<String> _monitorSetHistoryWindow(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Changing monitor history settings requires user approval.',
      });
    }
    final seconds = _argInt(arguments, 'seconds').clamp(30, 600);
    return jsonEncode(
      performanceMonitorToolService
          .setHistoryWindow(Duration(seconds: seconds)),
    );
  }

  Future<String> _monitorGetHealth(Map<String, dynamic> arguments) async {
    return jsonEncode(
      performanceMonitorToolService.getHealth(
        connectionIds: _optionalStringList(arguments, 'connectionIds'),
      ),
    );
  }

  Future<String> _monitorGetSamples(Map<String, dynamic> arguments) async {
    return jsonEncode(
      performanceMonitorToolService.getSamples(
        _arg(arguments, 'connectionId'),
        visibleOnly: _optionalBool(arguments, 'visibleOnly') ?? true,
        limit: _optionalInt(arguments, 'limit') ?? 100,
      ),
    );
  }

  Future<String> _monitorGetAlerts(Map<String, dynamic> arguments) async {
    return jsonEncode(
      performanceMonitorToolService.getAlerts(
        limit: _optionalInt(arguments, 'limit') ?? 50,
      ),
    );
  }

  Future<String> _monitorGetPorts(Map<String, dynamic> arguments) async {
    return jsonEncode(
      await performanceMonitorToolService
          .getPorts(_arg(arguments, 'connectionId')),
    );
  }

  Future<String> _monitorGetApplications(Map<String, dynamic> arguments) async {
    return jsonEncode(
      await performanceMonitorToolService.getApplications(
        _arg(arguments, 'connectionId'),
      ),
    );
  }

  Future<String> _appGetOperationalSettings(
      Map<String, dynamic> arguments) async {
    return jsonEncode(await _readOperationalSettings());
  }

  Future<String> _appUpdateOperationalSettings(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Changing app operational settings requires user approval.',
      });
    }
    final current = await storageService.loadAiConnectionSettings();
    final nextDownloadLimit = _optionalInt(arguments, 'sftpDownloadLimitBytes');
    final nextEditLimit = _optionalInt(arguments, 'sftpTextEditLimitBytes');
    if (nextDownloadLimit != null && appSettings != null) {
      await appSettings!.setSftpDownloadLimitBytes(nextDownloadLimit);
    }
    if (nextEditLimit != null && appSettings != null) {
      await appSettings!.setSftpTextEditLimitBytes(nextEditLimit);
    }
    final secretCacheEnabled = _optionalBool(arguments, 'secretCacheEnabled');
    if (secretCacheEnabled != null) {
      await storageService.setSecretCacheEnabled(secretCacheEnabled);
    }
    final secretCacheTtlMinutes =
        _optionalInt(arguments, 'secretCacheTtlMinutes');
    if (secretCacheTtlMinutes != null) {
      await storageService.setSecretCacheTtl(
        Duration(minutes: secretCacheTtlMinutes),
      );
    }
    final nextTimeout = _optionalInt(arguments, 'aiRequestTimeoutSeconds');
    final nextWebSearchEnabled = _optionalBool(arguments, 'webSearchEnabled');
    final nextWebSearchMaxResults =
        _optionalInt(arguments, 'webSearchMaxResults');
    final nextMultiAgentEnabled = _optionalBool(arguments, 'multiAgentEnabled');
    final nextMultiAgentMaxAgents =
        _optionalInt(arguments, 'multiAgentMaxAgents');
    if (nextTimeout != null ||
        nextWebSearchEnabled != null ||
        nextWebSearchMaxResults != null ||
        nextMultiAgentEnabled != null ||
        nextMultiAgentMaxAgents != null) {
      await storageService.saveAiConnectionSettings(
        baseUrl: current.baseUrl,
        model: current.model,
        contextWindowTokens: current.contextWindowTokens,
        timeoutSeconds: nextTimeout ?? current.timeoutSeconds,
        deepSeekThinkingEnabled: current.deepSeekThinkingEnabled,
        deepSeekReasoningEffort: current.deepSeekReasoningEffort,
        openAiReasoningEffort: current.openAiReasoningEffort,
        webSearchEnabled: nextWebSearchEnabled ?? current.webSearchEnabled,
        webSearchMaxResults:
            nextWebSearchMaxResults ?? current.webSearchMaxResults,
        multiAgentEnabled: nextMultiAgentEnabled ?? current.multiAgentEnabled,
        multiAgentMaxAgents:
            nextMultiAgentMaxAgents ?? current.multiAgentMaxAgents,
      );
    }
    return jsonEncode(await _readOperationalSettings());
  }

  Future<String> _appClearSecretCache(Map<String, dynamic> arguments) async {
    storageService.clearSecretCache();
    return jsonEncode({
      'cleared': true,
      'scope': 'memory_secret_cache',
    });
  }

  Future<Map<String, dynamic>> _readOperationalSettings() async {
    final ai = await storageService.loadAiConnectionSettings();
    return {
      'sftpDownloadLimitBytes': appSettings?.sftpDownloadLimitBytes ??
          AppSettings.defaultSftpDownloadLimitBytes,
      'sftpTextEditLimitBytes': appSettings?.sftpTextEditLimitBytes ??
          AppSettings.defaultSftpTextEditLimitBytes,
      'secretCacheEnabled': storageService.isSecretCacheEnabled,
      'secretCacheTtlMinutes': storageService.secretCacheTtlMinutes,
      'aiRequestTimeoutSeconds': ai.timeoutSeconds,
      'webSearchEnabled': ai.webSearchEnabled,
      'webSearchMaxResults': ai.webSearchMaxResults,
      'multiAgentEnabled': ai.multiAgentEnabled,
      'multiAgentMaxAgents': ai.multiAgentMaxAgents,
      'hasApiKeyConfigured': ai.hasApiKey,
    };
  }

  Map<String, dynamic> _sshSessionToJson(SshSession session) {
    return {
      'id': session.id,
      'connectionId': session.connectionId,
      'connectionName': session.connectionName,
      'displayName': session.displayName,
      'tmuxSessionName': session.tmuxSessionName,
      'tmuxKillCommand': session.tmuxKillCommand,
      'tmuxAutoDeleteSeconds': session.tmuxAutoDeleteSeconds,
      'state': session.state.name,
      'isConnected': session.isConnected,
      'errorMessage': session.errorMessage,
      'createdAt': session.createdAt.toIso8601String(),
      'updatedAt': session.updatedAt.toIso8601String(),
      'estimatedMemoryBytes': session.estimatedMemoryBytes,
    };
  }

  Map<String, dynamic> _terminalHistoryToJson(TerminalHistoryRecord record) {
    return {
      'sessionId': record.sessionId,
      'connectionId': record.connectionId,
      'connectionName': record.connectionName,
      'displayName': record.displayName,
      'tmuxSessionName': record.tmuxSessionName,
      'tmuxKillCommand': record.tmuxKillCommand,
      'state': record.state,
      'errorMessage': record.errorMessage,
      'createdAt': record.createdAt.toIso8601String(),
      'updatedAt': record.updatedAt.toIso8601String(),
    };
  }

  Map<String, dynamic> _summarizeBackupJson(String jsonText) {
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != 'ssh_mobile_backup') {
      throw StateError('Unsupported backup file.');
    }
    final connections = (decoded['connections'] as List<dynamic>? ?? const []);
    final aiSettings = decoded['aiSettings'] as Map<String, dynamic>?;
    final hasCredentialFields =
        connections.whereType<Map<String, dynamic>>().any(
                  (item) =>
                      (item['password'] as String?)?.isNotEmpty == true ||
                      (item['privateKey'] as String?)?.isNotEmpty == true,
                ) ||
            ((aiSettings?['apiKey'] as String?)?.isNotEmpty == true);
    return {
      'format': decoded['format'],
      'version': decoded['version'],
      'exportedAt': decoded['exportedAt'],
      'connections': connections.length,
      'restorableTmuxSessions':
          (decoded['restorableTmuxSessions'] as List<dynamic>? ?? const [])
              .length,
      'terminalHistoryRecords':
          (decoded['terminalHistoryRecords'] as List<dynamic>? ?? const [])
              .length,
      'aiChats': (decoded['aiChats'] as List<dynamic>? ?? const []).length,
      'aiSkills': (decoded['aiSkills'] as List<dynamic>? ?? const []).length,
      'hasAiSettings': aiSettings != null,
      'credentialFieldsIgnored': hasCredentialFields,
    };
  }

  String? _secretPathBlocked(String path) {
    final reason = secretPolicy.suspiciousPathReason(path);
    if (reason == null) return null;
    AppLogService.instance.warning(
      'AI tool blocked by secret path policy',
      details: 'blocked by tool secret policy',
    );
    return jsonEncode({
      'error': reason,
      'path': path,
      'blockedBy': 'tool_secret_policy',
    });
  }

  String _resolveRemoteUploadPath(String requestedPath, String pickedName) {
    final trimmed = requestedPath.trim();
    if (trimmed.isEmpty) return pickedName;
    if (trimmed.endsWith('/')) return '$trimmed$pickedName';
    return trimmed;
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

  AiCommandReview _reviewLinuxCommand(String normalized) {
    if (_looksLikeWindowsShellCommand(normalized)) {
      return const AiCommandReview.blocked(
        'Windows command was requested for a Linux server. Use POSIX or Linux commands for this server.',
      );
    }
    if (_hasCommandSeparator(normalized)) {
      return const AiCommandReview.requiresApproval(
        'Command chaining or piping requires user approval.',
      );
    }
    const allowedPrefixes = [
      'cat ',
      'command -v ',
      'df ',
      'du ',
      'free',
      'grep ',
      'head ',
      'journalctl ',
      'ls',
      'netstat ',
      'ps ',
      'pwd',
      'readlink ',
      'realpath ',
      'ss ',
      'stat ',
      'systemctl status ',
      'tail ',
      'top ',
      'uname',
      'uptime',
      'whereis ',
      'which ',
      'whoami',
    ];
    if (!allowedPrefixes.any(normalized.startsWith) &&
        !_isSafePowerShellDiagnostic(normalized)) {
      return const AiCommandReview.requiresApproval(
        'This command may change server state.',
      );
    }
    return const AiCommandReview.readOnly();
  }

  AiCommandReview _reviewWindowsCommand(String normalized) {
    if (_looksLikeLinuxShellCommand(normalized)) {
      return const AiCommandReview.blocked(
        'Linux or POSIX command was requested for a Windows server. Use explicit cmd /c or PowerShell commands for this server.',
      );
    }
    if (_isSafePowerShellDiagnostic(normalized)) {
      return const AiCommandReview.readOnly();
    }
    const safeCmdPrefixes = [
      'cmd /c cd',
      'cmd /c dir',
      'cmd /c echo',
      'cmd /c hostname',
      'cmd /c ipconfig',
      'cmd /c netstat',
      'cmd /c systeminfo',
      'cmd /c tasklist',
      'cmd /c type',
      'cmd /c ver',
      'cmd /c whoami',
    ];
    if (_hasCommandSeparator(normalized)) {
      return const AiCommandReview.requiresApproval(
        'Command chaining or piping requires user approval.',
      );
    }
    if (safeCmdPrefixes.any(normalized.startsWith)) {
      return const AiCommandReview.readOnly();
    }
    if (normalized.startsWith('cmd /c ') ||
        normalized.startsWith('powershell ') ||
        normalized.startsWith('pwsh ')) {
      return const AiCommandReview.requiresApproval(
        'This Windows command may change server state.',
      );
    }
    return const AiCommandReview.blocked(
      'Windows server commands must be explicit: use cmd /c or powershell or pwsh so the tool can enforce Windows safety rules.',
    );
  }

  String? _deletionCommandBlockReason(String normalized) {
    final text = normalized
        .replaceAll(RegExp(r'''["'`]'''), ' ')
        .replaceAll(RegExp(r'\s+'), ' ');
    if (text.contains(' remove-') || text.startsWith('remove-')) {
      return 'Delete or remove commands are blocked for AI tools.';
    }
    final deletePatterns = [
      RegExp(
        r'(^|[\s;&|()])(rm|unlink|rmdir|shred|trash-put)(\.exe)?([\s;&|()]|$)',
      ),
      RegExp(r'(^|[\s;&|()])(del|erase|rd)(\.exe)?([\s;&|()]|$)'),
      RegExp(r'(^|[\s;&|()])find([\s;&|()].*)\s-delete([\s;&|()]|$)'),
      RegExp(
        r'(^|[\s;&|()])(docker|podman|kubectl|git)\s+(rm|rmi|delete)([\s;&|()]|$)',
      ),
      RegExp(
        r'(^|[\s;&|()])(sc|reg|schtasks|netsh)\s+delete([\s;&|()]|$)',
      ),
    ];
    if (deletePatterns.any((pattern) => pattern.hasMatch(text))) {
      return 'Delete or remove commands are blocked for AI tools.';
    }
    return null;
  }

  bool _looksLikeWindowsShellCommand(String normalized) {
    const prefixes = [
      'cmd ',
      'cmd.exe ',
      'powershell ',
      'powershell.exe ',
      'pwsh ',
      'pwsh.exe ',
      'wmic ',
      'tasklist',
      'systeminfo',
      'ipconfig',
    ];
    return prefixes.any(normalized.startsWith);
  }

  bool _looksLikeLinuxShellCommand(String normalized) {
    const prefixes = [
      './',
      '/',
      'awk ',
      'bash ',
      'cat ',
      'command -v ',
      'df ',
      'du ',
      'free',
      'grep ',
      'head ',
      'journalctl ',
      'ls',
      'ps ',
      'pwd',
      'readlink ',
      'realpath ',
      'sed ',
      'sh ',
      'ss ',
      'stat ',
      'systemctl ',
      'tail ',
      'top ',
      'uname',
      'uptime',
      'whereis ',
      'which ',
      'whoami',
      'zsh ',
    ];
    return prefixes.any(normalized.startsWith);
  }

  bool _hasCommandSeparator(String normalized) {
    return normalized.contains(';') ||
        normalized.contains('|') ||
        normalized.contains('&&') ||
        normalized.contains('||') ||
        normalized.contains(' & ');
  }

  bool _isSafePowerShellDiagnostic(String normalized) {
    final isPowerShell =
        normalized.startsWith('powershell ') || normalized.startsWith('pwsh ');
    if (!isPowerShell) return false;
    const blockedFragments = [
      ' add-',
      ' clear-',
      ' copy-',
      ' disable-',
      ' enable-',
      ' invoke-',
      ' move-',
      ' new-',
      ' out-file',
      ' remove-',
      ' rename-',
      ' restart-',
      ' set-',
      ' start-',
      ' stop-',
      ' write-',
      '>>',
      '>',
      ';',
      '&&',
      '||',
      ' del ',
      ' erase ',
      ' rd ',
      ' rmdir ',
    ];
    if (blockedFragments.any(normalized.contains)) return false;
    const safeFragments = [
      'get-',
      'select-object',
      'sort-object',
      'measure-object',
      'where-object',
      'convertto-json',
      r'$psversiontable',
    ];
    return safeFragments.any(normalized.contains);
  }

  bool _hasWindowsPermissionProblem(String stdout, String stderr) {
    final combined = '$stdout\n$stderr'.toLowerCase();
    const needles = [
      'access is denied',
      'access denied',
      'administrator privileges',
      'administrator rights',
      'elevation is required',
      'requires elevation',
      'requested operation requires elevation',
      'run as administrator',
      'not have sufficient privilege',
      'not have the required privilege',
      'unauthorizedaccessexception',
      '拒绝访问',
      '权限不足',
      '需要提升',
      '管理员权限',
    ];
    return needles.any(combined.contains);
  }

  String get _windowsPermissionMessage =>
      'Windows permission denied: the current account does not have enough privileges for this operation. Use an Administrator or elevated account, or grant the required permission and try again.';

  String _truncate(String value) {
    final redacted = secretPolicy.redactText(value);
    if (redacted.length <= _maxToolTextChars) return redacted;
    return '${redacted.substring(0, _maxToolTextChars)}\n...[truncated]';
  }

  String _remoteFileName(String path) {
    final normalized = path.trim().replaceAll('\\', '/');
    final parts = normalized.split('/').where((part) => part.isNotEmpty);
    if (parts.isEmpty) return 'download.bin';
    return parts.last;
  }

  int get _sftpDownloadLimitBytes =>
      appSettings?.sftpDownloadLimitBytes ??
      AppSettings.defaultSftpDownloadLimitBytes;

  int get _sftpTextEditLimitBytes =>
      appSettings?.sftpTextEditLimitBytes ??
      AppSettings.defaultSftpTextEditLimitBytes;

  String _arg(Map<String, dynamic> arguments, String key) {
    final value = arguments[key];
    if (value is! String || value.trim().isEmpty) {
      throw StateError('Missing tool argument: $key');
    }
    return value.trim();
  }

  String? _optionalString(Map<String, dynamic> arguments, String key) {
    final value = arguments[key];
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  int _argInt(Map<String, dynamic> arguments, String key) {
    final value = _optionalInt(arguments, key);
    if (value == null) {
      throw StateError('Missing tool argument: $key');
    }
    return value;
  }

  int? _optionalInt(Map<String, dynamic> arguments, String key) {
    final value = arguments[key];
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  bool? _optionalBool(Map<String, dynamic> arguments, String key) {
    final value = arguments[key];
    if (value is bool) return value;
    if (value is String) {
      switch (value.trim().toLowerCase()) {
        case 'true':
        case 'yes':
        case '1':
          return true;
        case 'false':
        case 'no':
        case '0':
          return false;
      }
    }
    return null;
  }

  List<String> _stringList(Object? value) {
    if (value is! List) {
      throw StateError('Expected a string array.');
    }
    final items = value
        .whereType<Object?>()
        .map((item) => item?.toString().trim() ?? '')
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    if (items.isEmpty) {
      throw StateError('Expected a non-empty string array.');
    }
    return items;
  }

  List<String>? _optionalStringList(
    Map<String, dynamic> arguments,
    String key,
  ) {
    if (!arguments.containsKey(key)) return null;
    final value = arguments[key];
    if (value == null) return null;
    return _stringList(value);
  }

  List<int> _intList(Object? value) {
    if (value is! List) {
      throw StateError('Expected an integer array.');
    }
    final items = <int>[];
    for (final item in value) {
      if (item is num) {
        items.add(item.toInt());
      } else if (item is String) {
        final parsed = int.tryParse(item.trim());
        if (parsed != null) items.add(parsed);
      }
    }
    if (items.isEmpty) {
      throw StateError('Expected a non-empty integer array.');
    }
    return items;
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

class AiToolApprovalRequest {
  final String toolName;
  final String approvalType;
  final String connectionId;
  final String connectionName;
  final String command;
  final String reason;
  final String? targetPath;
  final int? byteLength;
  final String? contentPreview;
  final bool destructive;

  const AiToolApprovalRequest({
    required this.toolName,
    required this.approvalType,
    required this.connectionId,
    required this.connectionName,
    required this.command,
    required this.reason,
    this.targetPath,
    this.byteLength,
    this.contentPreview,
    this.destructive = false,
  });
}

class AiToolApprovalDecision {
  final bool approved;
  final bool abort;
  final String? feedback;

  const AiToolApprovalDecision.approved()
      : approved = true,
        abort = false,
        feedback = null;

  const AiToolApprovalDecision.rejected({
    this.abort = true,
    this.feedback,
  }) : approved = false;
}

class AiCommandReview {
  final bool requiresApproval;
  final bool blocked;
  final String reason;

  const AiCommandReview.readOnly()
      : requiresApproval = false,
        blocked = false,
        reason = 'Read-only diagnostic command.';

  const AiCommandReview.requiresApproval(this.reason)
      : requiresApproval = true,
        blocked = false;

  const AiCommandReview.blocked(this.reason)
      : requiresApproval = false,
        blocked = true;
}

class AiTool {
  final String name;
  final String description;
  final Map<String, dynamic> properties;
  final List<String> required;
  final Future<String> Function(Map<String, dynamic> arguments) handler;

  const AiTool({
    required this.name,
    required this.description,
    required this.properties,
    required this.handler,
    this.required = const [],
  });

  Map<String, dynamic> get definition {
    return {
      'type': 'function',
      'function': {
        'name': name,
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': properties,
          'required': required,
          'additionalProperties': false,
        },
      },
    };
  }
}

class _UnavailablePerformanceMonitorToolService
    implements PerformanceMonitorToolAdapter {
  const _UnavailablePerformanceMonitorToolService();

  static const String _message =
      'Performance monitor service is not available in this context.';

  @override
  Map<String, dynamic> clearSelection() =>
      {'supported': false, 'error': _message};

  @override
  Future<Map<String, dynamic>> getApplications(String connectionId) async =>
      {'supported': false, 'error': _message};

  @override
  Map<String, dynamic> getAlerts({int limit = 50}) =>
      {'supported': false, 'error': _message};

  @override
  Map<String, dynamic> getHealth({List<String>? connectionIds}) =>
      {'supported': false, 'error': _message};

  @override
  Future<Map<String, dynamic>> getPorts(String connectionId) async =>
      {'supported': false, 'error': _message};

  @override
  Map<String, dynamic> getSamples(
    String connectionId, {
    bool visibleOnly = true,
    int limit = 100,
  }) =>
      {'supported': false, 'error': _message};

  @override
  Map<String, dynamic> getState() => {'supported': false, 'error': _message};

  @override
  Map<String, dynamic> setHistoryWindow(Duration window) =>
      {'supported': false, 'error': _message};

  @override
  Map<String, dynamic> setInterval(Duration interval) =>
      {'supported': false, 'error': _message};

  @override
  Map<String, dynamic> setSelectedServers(List<String> connectionIds) =>
      {'supported': false, 'error': _message};

  @override
  Future<Map<String, dynamic>> start() async =>
      {'supported': false, 'error': _message};

  @override
  Map<String, dynamic> stop() => {'supported': false, 'error': _message};

  @override
  Map<String, dynamic> stopForConnection(String connectionId) =>
      {'supported': false, 'error': _message};
}

const int _maxToolTextChars = 12000;
