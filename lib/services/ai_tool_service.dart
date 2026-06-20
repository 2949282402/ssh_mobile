import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../features/connection/models/connection.dart';
import '../features/playbook/models/playbook.dart';
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
import 'tool_exposure_router.dart';
import 'tool_secret_policy.dart';
import 'skill/skill_domain_service.dart';
import 'agent/plan_execution_controller.dart';

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
  final SkillDomainService skillDomainService;

  final List<AiToolProvider> providers;

  AiToolService({
    List<AiToolProvider>? providers,
    required this.storageService,
    required this.sshService,
    required this.sftpService,
    ClientSystemToolAdapter? clientSystemToolService,
    ClientWebViewAdapter? clientWebViewService,
    ServerCatalogAdapter? serverCatalogService,
    PerformanceMonitorToolAdapter? performanceMonitorToolService,
    ServerDiagnosticsAdapter? serverDiagnosticsService,
    ToolSecretPolicy? secretPolicy,
    SkillDomainService? skillDomainService,
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
        secretPolicy = secretPolicy ?? const ToolSecretPolicy(),
        skillDomainService = skillDomainService ?? const SkillDomainService(),
        providers = providers ??
            _buildDefaultProviders(
              storageService: storageService,
              sshService: sshService,
              sftpService: sftpService,
              clientSystemToolService:
                  clientSystemToolService ?? ClientSystemToolService.instance,
              clientWebViewService:
                  clientWebViewService ?? ClientWebViewService.instance,
              serverCatalogService: serverCatalogService ??
                  ServerCatalogService(
                    storageService: storageService,
                    sshService: sshService,
                    sftpService: sftpService,
                  ),
              performanceMonitorToolService: performanceMonitorToolService ??
                  const _UnavailablePerformanceMonitorToolService(),
              serverDiagnosticsService: serverDiagnosticsService ??
                  ServerDiagnosticsService(
                    storageService: storageService,
                    sshService: sshService,
                  ),
              secretPolicy: secretPolicy ?? const ToolSecretPolicy(),
              skillDomainService:
                  skillDomainService ?? const SkillDomainService(),
              appSettings: appSettings,
              playbookService: playbookService,
              clientWebViewSessionId: clientWebViewSessionId,
            );

  static List<AiToolProvider> _buildDefaultProviders({
    required StorageService storageService,
    required SshClientAdapter sshService,
    required SftpClientAdapter sftpService,
    required ClientSystemToolAdapter clientSystemToolService,
    required ClientWebViewAdapter clientWebViewService,
    required ServerCatalogAdapter serverCatalogService,
    required PerformanceMonitorToolAdapter performanceMonitorToolService,
    required ServerDiagnosticsAdapter serverDiagnosticsService,
    required ToolSecretPolicy secretPolicy,
    required SkillDomainService skillDomainService,
    AppSettings? appSettings,
    PlaybookService? playbookService,
    String? clientWebViewSessionId,
  }) {
    return [
      ClientToolsProvider(
        storageService: storageService,
        clientSystemToolService: clientSystemToolService,
        clientWebViewService: clientWebViewService,
        clientWebViewSessionId: clientWebViewSessionId,
        secretPolicy: secretPolicy,
        skillDomainService: skillDomainService,
      ),
      ServerToolsProvider(
        serverCatalogService: serverCatalogService,
        serverDiagnosticsService: serverDiagnosticsService,
      ),
      SshToolsProvider(
        sshService: sshService,
        storageService: storageService,
        secretPolicy: secretPolicy,
      ),
      SftpToolsProvider(
        sftpService: sftpService,
        clientSystemToolService: clientSystemToolService,
      ),
      MonitorToolsProvider(
        performanceMonitorToolService: performanceMonitorToolService,
        storageService: storageService,
      ),
      PlaybookToolsProvider(
        storageService: storageService,
        appSettings: appSettings,
        playbookService: playbookService,
      ),
    ];
  }

  @override
  Future<List<AiTool>> tools() async {
    final list = <AiTool>[];
    for (final provider in providers) {
      list.addAll(await provider.getTools(this));
    }
    return list;
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
  Future<AiToolApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async {
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
      case 'ssh_open_session':
        final connectionId = _arg(arguments, 'connectionId');
        final config = storageService.getConnection(connectionId);
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'ssh_session_change',
          connectionId: connectionId,
          connectionName: config?.name ?? connectionId,
          command: 'OPEN SSH SESSION',
          reason: 'Opening a saved SSH session requires user approval.',
          contentPreview: _optionalString(arguments, 'displayName'),
        );
      case 'ssh_close_session':
        final sessionId = _arg(arguments, 'sessionId');
        final session = sshService.getSession(sessionId);
        final connectionId = session?.connectionId ?? _clientScopeId;
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'ssh_session_change',
          connectionId: connectionId,
          connectionName: session?.connectionName ?? _clientScopeName,
          command: 'CLOSE SSH SESSION $sessionId',
          reason: 'Closing an SSH session requires user approval.',
          contentPreview: session?.displayName,
        );
      case 'ssh_close_server_sessions':
        final connectionId = _arg(arguments, 'connectionId');
        final config = storageService.getConnection(connectionId);
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'ssh_session_change',
          connectionId: connectionId,
          connectionName: config?.name ?? connectionId,
          command: 'CLOSE ALL SSH SESSIONS',
          reason:
              'Closing all SSH sessions for a server requires user approval.',
        );
      case 'ssh_restore_tmux_sessions':
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'ssh_session_change',
          connectionId: _clientScopeId,
          connectionName: _clientScopeName,
          command: 'RESTORE TMUX SESSIONS',
          reason:
              'Restoring saved tmux-backed SSH sessions requires user approval.',
        );
      case 'ssh_delete_terminal_history_record':
        final sessionId = _arg(arguments, 'sessionId');
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'terminal_history_change',
          connectionId: _clientScopeId,
          connectionName: _clientScopeName,
          command: 'DELETE TERMINAL HISTORY $sessionId',
          reason: 'Deleting saved terminal history requires user approval.',
          destructive: true,
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
      case 'sftp_read_text':
        return _remoteApproval(
          toolName: name,
          arguments: arguments,
          approvalType: 'remote_read',
          summaryBuilder: (connectionId, path) => 'SFTP READ $path',
          reason:
              'Remote file reads require user approval because file contents may contain secrets.',
        );
      case 'sftp_download_file':
        return _remoteApproval(
          toolName: name,
          arguments: arguments,
          approvalType: 'remote_read',
          summaryBuilder: (connectionId, path) => 'SFTP DOWNLOAD $path',
          reason:
              'Remote file downloads require user approval because file contents may contain secrets.',
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
      case 'client_save_experience_skill':
        final summary = _arg(arguments, 'summary');
        final title = _optionalString(arguments, 'title') ?? '';
        final details = _optionalString(arguments, 'content') ?? '';
        final rawRefs = arguments['references'];
        final inputReferences = <SkillReferenceItem>[];
        if (rawRefs is List) {
          for (final item in rawRefs) {
            if (item is Map) {
              final t = (item['title'] as String?)?.trim() ?? '';
              final c = (item['content'] as String?)?.trim() ?? '';
              inputReferences.add(SkillReferenceItem(title: t, content: c));
            }
          }
        }
        final buildResult = skillDomainService.buildCreateSkill(
          title: title.isEmpty ? null : title,
          summary: summary,
          content:
              details.trim().isEmpty ? null : '$summary\n\n${details.trim()}',
          references: inputReferences,
        );
        final dummyRecord = AiSkillRecord(
          id: 'temp',
          name: buildResult.name,
          description: buildResult.description,
          content: buildResult.content,
          enabled: true,
          references: buildResult.references,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        final preview = skillDomainService.generatePreview(null, dummyRecord);
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'local_skill_change',
          connectionId: _clientScopeId,
          connectionName: _clientScopeName,
          command: 'CREATE LOCAL SKILL: "${preview.afterName}"',
          reason:
              'Saving a new local AI experience skill/note requires user approval.',
          contentPreview:
              'Name: ${preview.afterName}\nDescription: ${preview.afterDescription}\nContent: ${preview.afterContentSnippet}\nReferences: ${preview.addedReferencesCount} added',
        );
      case 'client_update_skill':
        final skillId = _arg(arguments, 'skillId');
        final skills = await storageService.loadAiSkills();
        final idx = skills.indexWhere((s) => s.id == skillId);
        if (idx == -1) return null;
        final current = skills[idx];

        final nameArg = _optionalString(arguments, 'name');
        final descriptionArg = _optionalString(arguments, 'description');
        final contentArg = _optionalString(arguments, 'content');
        final enabledArg = _optionalBool(arguments, 'enabled');
        final rawRefs = arguments['references'];
        List<SkillReferenceItem>? targetReferences;
        if (rawRefs is List) {
          targetReferences = [];
          for (final item in rawRefs) {
            if (item is Map) {
              final t = (item['title'] as String?)?.trim() ?? '';
              final c = (item['content'] as String?)?.trim() ?? '';
              targetReferences.add(SkillReferenceItem(title: t, content: c));
            }
          }
        }

        final buildResult = skillDomainService.buildUpdateSkill(
          current,
          name: nameArg,
          description: descriptionArg,
          content: contentArg,
          references: targetReferences,
        );

        final updated = current.copyWith(
          name: buildResult.name,
          description: buildResult.description,
          content: buildResult.content,
          enabled: enabledArg ?? current.enabled,
          references: buildResult.references,
        );

        final preview = skillDomainService.generatePreview(current, updated);
        final buffer = StringBuffer();
        if (preview.beforeName != preview.afterName) {
          buffer.writeln(
              'Name: "${preview.beforeName}" -> "${preview.afterName}"');
        }
        if (preview.beforeDescription != preview.afterDescription) {
          buffer.writeln(
              'Description: "${preview.beforeDescription}" -> "${preview.afterDescription}"');
        }
        if (preview.beforeEnabled != preview.afterEnabled) {
          buffer.writeln(
              'Enabled: ${preview.beforeEnabled} -> ${preview.afterEnabled}');
        }
        if (preview.beforeContentSnippet != preview.afterContentSnippet) {
          buffer.writeln('Content modified');
        }
        final refChanges = <String>[];
        if (preview.addedReferencesCount > 0) {
          refChanges.add('${preview.addedReferencesCount} added');
        }
        if (preview.removedReferencesCount > 0) {
          refChanges.add('${preview.removedReferencesCount} removed');
        }
        if (preview.modifiedReferencesCount > 0) {
          refChanges.add('${preview.modifiedReferencesCount} modified');
        }
        if (refChanges.isNotEmpty) {
          buffer.writeln('References: ${refChanges.join(', ')}');
        }
        if (buffer.isEmpty) {
          buffer.write('No visible changes or updating other fields');
        }

        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'local_skill_change',
          connectionId: _clientScopeId,
          connectionName: _clientScopeName,
          command: 'UPDATE LOCAL SKILL: $skillId',
          reason:
              'Updating a saved AI experience skill/note requires user approval.',
          contentPreview: buffer.toString(),
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
    final hasTool = availableTools.any((t) => t.name == name);
    if (!hasTool) {
      AppLogService.instance
          .warning('Unknown AI tool requested', details: name);
      return jsonEncode({'error': 'Unknown tool: $name'});
    }

    final tool = availableTools.firstWhere((t) => t.name == name);
    if (tool.needsServerSelection) {
      final connId = arguments['connectionId'];
      if (connId == null ||
          connId is! String ||
          connId.trim().isEmpty ||
          connId.trim() == 'local') {
        return jsonEncode({
          'error': 'This tool requires a selected server connection.',
          'code': 'connection_required',
          'tool': name,
          'nextAction':
              'Ask the user to select a server connection before running this tool.'
        });
      }
    }

    final startedAt = DateTime.now();
    AppLogService.instance.info(
      'AI tool started',
      details:
          'tool=$name args=${secretPolicy.safeJson(arguments, truncateLongStrings: true)}',
    );

    try {
      String? rawResult;

      // 尝试路由给对应的 Provider 执行
      for (final provider in providers) {
        final res = await provider.execute(
          this,
          name,
          arguments,
          approvedWrite: approvedWrite,
        );
        if (res != null) {
          rawResult = res;
          break;
        }
      }

      // 兜底直接执行原本 AiTool 中挂载的 handler
      if (rawResult == null) {
        for (final tool in availableTools) {
          if (tool.name == name) {
            rawResult = await tool.handler(arguments);
            break;
          }
        }
      }

      rawResult ??=
          jsonEncode({'error': 'Execution handler missing for tool: $name'});

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
