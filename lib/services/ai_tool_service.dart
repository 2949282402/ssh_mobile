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
    return [
      ..._getClientTools(searchSettings),
      ..._getServerTools(),
      ..._getSshTools(),
      ..._getSftpTools(),
      ..._getMonitorTools(),
      ..._getPlaybookTools(),
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
