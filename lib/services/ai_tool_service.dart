import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../features/connection/models/connection.dart';
import '../features/playbook/models/playbook.dart';
import 'app_log_service.dart';
import 'app_settings.dart';
import 'client_system_tool_service.dart';
import 'client_health_advisor.dart';
import 'client_webview_service.dart';
import 'connection_target_binding.dart';
import 'multi_agent_coordinator.dart';
import 'performance_monitor_tool_service.dart';
import 'playbook_service.dart';
import 'server_catalog_service.dart';
import 'server_diagnostics_service.dart';
import 'sftp_service.dart';
import 'ssh_service.dart';
import 'storage_service.dart';
import 'remote_target_scope.dart';
import 'tool_exposure_router.dart';
import 'tool_secret_policy.dart';
import 'skill/skill_domain_service.dart';
import 'agent/plan_execution_controller.dart';
import 'llm_provider/llm_api_format.dart';

part 'ai_tool/ai_tool_types.dart';
part 'ai_tool/client_tools.dart';
part 'ai_tool/tools/client_tools_schemas.dart';
part 'ai_tool/tools/client_tools_impl.dart';
part 'ai_tool/server_tools.dart';
part 'ai_tool/ssh_tools.dart';
part 'ai_tool/sftp_tools.dart';
part 'ai_tool/monitor_tools.dart';
part 'ai_tool/playbook_tools.dart';
part 'ai_tool/security_policy.dart';

class AiToolService implements AiToolExecutor, AiToolApprovalTargetGuard {
  static const String _clientScopeId = 'client';
  static const String _clientScopeName = 'SSH Mobile client';
  static const int _maxToolTextChars = 12000;

  final StorageService storageService;
  final SshClientAdapter sshService;
  final SftpClientAdapter sftpService;
  final ClientSystemToolAdapter clientSystemToolService;
  final ClientHealthAdvisorAdapter clientHealthAdvisor;
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
  AiRuntimeConnectionSnapshot? _runtimeConnectionSnapshot;
  Map<String, ConnectionTargetBinding>? _connectionTargets;
  static final Object _approvalBindingZoneKey = Object();

  AiToolService({
    List<AiToolProvider>? providers,
    required this.storageService,
    required this.sshService,
    required this.sftpService,
    ClientSystemToolAdapter? clientSystemToolService,
    ClientHealthAdvisorAdapter? clientHealthAdvisor,
    ClientWebViewAdapter? clientWebViewService,
    ServerCatalogAdapter? serverCatalogService,
    PerformanceMonitorToolAdapter? performanceMonitorToolService,
    ServerDiagnosticsAdapter? serverDiagnosticsService,
    ToolSecretPolicy? secretPolicy,
    SkillDomainService? skillDomainService,
    this.appSettings,
    this.playbookService,
    this.clientWebViewSessionId,
  }) : clientSystemToolService =
           clientSystemToolService ?? ClientSystemToolService.instance,
       clientHealthAdvisor =
           clientHealthAdvisor ??
           ClientHealthAdvisor(
             clientSystemToolService:
                 clientSystemToolService ?? ClientSystemToolService.instance,
             secretPolicy: secretPolicy ?? const ToolSecretPolicy(),
           ),
       clientWebViewService =
           clientWebViewService ?? ClientWebViewService.instance,
       serverCatalogService =
           serverCatalogService ??
           ServerCatalogService(
             storageService: storageService,
             sshService: sshService,
             sftpService: sftpService,
           ),
       performanceMonitorToolService =
           performanceMonitorToolService ??
           const _UnavailablePerformanceMonitorToolService(),
       serverDiagnosticsService =
           serverDiagnosticsService ??
           ServerDiagnosticsService(
             storageService: storageService,
             sshService: sshService,
           ),
       secretPolicy = secretPolicy ?? const ToolSecretPolicy(),
       skillDomainService = skillDomainService ?? const SkillDomainService(),
       providers =
           providers ??
           _buildDefaultProviders(
             storageService: storageService,
             sshService: sshService,
             sftpService: sftpService,
             clientSystemToolService:
                 clientSystemToolService ?? ClientSystemToolService.instance,
             clientHealthAdvisor:
                 clientHealthAdvisor ??
                 ClientHealthAdvisor(
                   clientSystemToolService:
                       clientSystemToolService ??
                       ClientSystemToolService.instance,
                   secretPolicy: secretPolicy ?? const ToolSecretPolicy(),
                 ),
             clientWebViewService:
                 clientWebViewService ?? ClientWebViewService.instance,
             serverCatalogService:
                 serverCatalogService ??
                 ServerCatalogService(
                   storageService: storageService,
                   sshService: sshService,
                   sftpService: sftpService,
                 ),
             performanceMonitorToolService:
                 performanceMonitorToolService ??
                 const _UnavailablePerformanceMonitorToolService(),
             serverDiagnosticsService:
                 serverDiagnosticsService ??
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

  void bindRuntimeConnectionSnapshot(AiRuntimeConnectionSnapshot snapshot) {
    _runtimeConnectionSnapshot = snapshot;
  }

  void bindConnectionTargets(
    Map<String, ConnectionTargetBinding> connectionTargets,
  ) {
    _connectionTargets = Map<String, ConnectionTargetBinding>.unmodifiable(
      connectionTargets,
    );
  }

  AiToolApprovalExecutionBinding? get activeApprovalExecutionBinding =>
      Zone.current[_approvalBindingZoneKey] as AiToolApprovalExecutionBinding?;

  static List<AiToolProvider> _buildDefaultProviders({
    required StorageService storageService,
    required SshClientAdapter sshService,
    required SftpClientAdapter sftpService,
    required ClientSystemToolAdapter clientSystemToolService,
    required ClientHealthAdvisorAdapter clientHealthAdvisor,
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
        clientHealthAdvisor: clientHealthAdvisor,
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
  AiCommandReview reviewCommand(String command, {ServerPlatform? platform}) {
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
    final request = await _buildApprovalRequest(name, arguments);
    if (request == null) return null;
    return _bindApprovalRequest(request, arguments);
  }

  Future<AiToolApprovalRequest?> _buildApprovalRequest(
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
      case 'ssh_ensure_session_connected':
        final sessionId = _arg(arguments, 'sessionId');
        final connectionId = _arg(arguments, 'connectionId');
        final session = sshService.getSession(sessionId);
        final config = storageService.getConnection(connectionId);
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'ssh_session_change',
          connectionId: connectionId,
          connectionName: config?.name ?? connectionId,
          command: 'CONNECT SSH SESSION $sessionId',
          reason: 'Connecting an SSH session requires user approval.',
          contentPreview: session?.displayName,
          executionBinding: AiToolApprovalExecutionBinding(
            resourceKind: 'ssh_session',
            resourceId: sessionId,
            resourceFingerprint: session?.connectionId,
          ),
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
        final changes = <String, dynamic>{
          for (final entry in arguments.entries)
            if (entry.key != 'connectionId' && entry.value != null)
              entry.key: entry.value,
        };
        final keys = changes.keys.toList(growable: false);
        final current = config == null
            ? null
            : ConnectionConfig.fromJson(config.toJson());
        final candidate = current == null
            ? null
            : ServerCatalogService.buildUpdateCandidate(current, changes);
        final target = current == null
            ? null
            : ConnectionTargetBinding.fromConfig(current);
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'server_metadata_change',
          connectionId: connectionId,
          connectionName: config?.name ?? connectionId,
          command: candidate == null
              ? 'UPDATE SERVER METADATA (${keys.join(', ')})'
              : 'UPDATE SERVER TARGET ${candidate.username}@${candidate.host}:${candidate.port}',
          reason: 'Server metadata changes require user approval.',
          contentPreview: current == null || candidate == null
              ? (keys.isEmpty ? null : keys.join(', '))
              : _serverMetadataApprovalPreview(current, candidate, keys),
          executionBinding:
              target == null || current == null || candidate == null
              ? null
              : AiToolApprovalExecutionBinding(
                  connectionTargets: {connectionId: target},
                  resourceKind: 'server_metadata_update',
                  resourceId: connectionId,
                  resourceFingerprint: jsonEncode(current.toJson()),
                  resourceSnapshot: _ApprovedServerMetadataUpdate(
                    expected: current,
                    candidate: candidate,
                  ),
                ),
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
          content: details.trim().isEmpty
              ? null
              : '$summary\n\n${details.trim()}',
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
          updatedAt: DateTime.now(),
        );

        final preview = skillDomainService.generatePreview(current, updated);
        final buffer = StringBuffer();
        if (preview.beforeName != preview.afterName) {
          buffer.writeln(
            'Name: "${preview.beforeName}" -> "${preview.afterName}"',
          );
        }
        if (preview.beforeDescription != preview.afterDescription) {
          buffer.writeln(
            'Description: "${preview.beforeDescription}" -> "${preview.afterDescription}"',
          );
        }
        if (preview.beforeEnabled != preview.afterEnabled) {
          buffer.writeln(
            'Enabled: ${preview.beforeEnabled} -> ${preview.afterEnabled}',
          );
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
          executionBinding: AiToolApprovalExecutionBinding(
            resourceKind: 'ai_skill',
            resourceId: skillId,
            resourceFingerprint: _aiSkillFingerprint(current),
            resourceSnapshot: _ApprovedSkillUpdate(
              expected: current,
              updated: updated,
            ),
          ),
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
        final playbooks = await storageService.loadPlaybooks();
        final playbookIndex = playbooks.indexWhere(
          (playbook) => playbook.id == playbookId,
        );
        if (playbookIndex == -1) return null;
        final playbook = Playbook.fromJson(playbooks[playbookIndex].toJson());
        final commandPreview = playbook.steps
            .take(3)
            .map((step) => secretPolicy.previewText(step.command, maxChars: 80))
            .join('\n');
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'playbook_run',
          connectionId: connectionId,
          connectionName: config?.name ?? connectionId,
          command:
              'RUN PLAYBOOK: ${playbook.name} (${playbook.steps.length} steps)',
          reason:
              'Executing sequential commands on a server requires user approval.',
          contentPreview: commandPreview,
          executionBinding: AiToolApprovalExecutionBinding(
            resourceKind: 'playbook',
            resourceId: playbookId,
            resourceFingerprint: _playbookActionFingerprint(playbook),
            resourceSnapshot: _ApprovedPlaybookRun(
              playbook: playbook,
              actionFingerprint: _playbookActionFingerprint(playbook),
            ),
          ),
        );
      case 'client_task_skip':
        final taskId = _arg(arguments, 'taskId');
        final reason = _arg(arguments, 'reason');
        return AiToolApprovalRequest(
          toolName: name,
          approvalType: 'plan_task_change',
          connectionId: _clientScopeId,
          connectionName: _clientScopeName,
          command: 'SKIP PLAN TASK $taskId',
          reason: 'Skipping an execution plan step requires user approval.',
          contentPreview: 'Reason: $reason',
        );
      default:
        return null;
    }
  }

  Future<AiToolApprovalRequest> _bindApprovalRequest(
    AiToolApprovalRequest request,
    Map<String, dynamic> arguments,
  ) async {
    final existing = request.executionBinding;
    final targets = <String, ConnectionTargetBinding>{
      ...?existing?.connectionTargets,
    };
    var resourceKind = existing?.resourceKind;
    var resourceId = existing?.resourceId;
    var resourceFingerprint = existing?.resourceFingerprint;
    final resourceSnapshot = existing?.resourceSnapshot;

    void addTarget(String rawId, {bool allowOutsideTurn = false}) {
      final id = rawId.trim();
      if (id.isEmpty || id == _clientScopeId || targets.containsKey(id)) {
        return;
      }
      ConnectionTargetBinding? target;
      final turnTargets = _connectionTargets;
      if (turnTargets == null || allowOutsideTurn) {
        final config = storageService.getConnection(id);
        if (config != null) {
          target = ConnectionTargetBinding.fromConfig(config);
        }
      } else {
        target = turnTargets[id];
      }
      if (target != null) targets[id] = target;
    }

    addTarget(request.connectionId);
    switch (request.toolName) {
      case 'monitor_set_selected_servers':
        for (final id in _stringList(arguments['connectionIds'])) {
          addTarget(id, allowOutsideTurn: true);
        }
        break;
      case 'monitor_start':
        final state = performanceMonitorToolService.getState();
        final rawSelectedIds = state['selectedConnectionIds'];
        final selectedIds = rawSelectedIds is List
            ? rawSelectedIds
                  .map((item) => item?.toString().trim() ?? '')
                  .where((item) => item.isNotEmpty)
                  .toList(growable: false)
            : <String>[];
        selectedIds.sort();
        for (final id in selectedIds) {
          addTarget(id, allowOutsideTurn: true);
        }
        resourceKind = 'monitor_selection';
        resourceId = 'selected_connections';
        resourceFingerprint = jsonEncode(selectedIds);
        break;
      case 'ssh_restore_tmux_sessions':
        final sessions = await storageService.loadRestorableTmuxSessions();
        for (final session in sessions) {
          addTarget(session.connectionId, allowOutsideTurn: true);
        }
        break;
    }

    final binding = AiToolApprovalExecutionBinding(
      connectionTargets: Map<String, ConnectionTargetBinding>.unmodifiable(
        targets,
      ),
      resourceKind: resourceKind,
      resourceId: resourceId,
      resourceFingerprint: resourceFingerprint,
      resourceSnapshot: resourceSnapshot,
    );
    final singleTarget = targets[request.connectionId];
    final targetSummary = targets.values
        .map(
          (target) =>
              '${target.config.name} (${target.config.username}@${target.config.host}:${target.config.port})',
        )
        .join('\n');
    final preview =
        request.connectionId == _clientScopeId && targetSummary.isNotEmpty
        ? [
            if (request.contentPreview?.trim().isNotEmpty == true)
              request.contentPreview!.trim(),
            'Targets:\n$targetSummary',
          ].join('\n')
        : request.contentPreview;
    return request.copyWith(
      connectionName: singleTarget?.config.name,
      contentPreview: preview,
      executionBinding: binding,
    );
  }

  @override
  Future<bool> isApprovalTargetCurrent(AiToolApprovalRequest request) async {
    final binding = request.executionBinding;
    if (binding == null) {
      return request.connectionId.trim().isEmpty ||
          request.connectionId == _clientScopeId;
    }
    if (request.connectionId != _clientScopeId &&
        !binding.connectionTargets.containsKey(request.connectionId)) {
      return false;
    }
    for (final target in binding.connectionTargets.values) {
      if (!target.matches(storageService.getConnection(target.id))) {
        return false;
      }
    }
    switch (binding.resourceKind) {
      case 'ai_skill':
        final skills = await storageService.loadAiSkills();
        final index = skills.indexWhere(
          (skill) => skill.id == binding.resourceId,
        );
        return index >= 0 &&
            _aiSkillFingerprint(skills[index]) == binding.resourceFingerprint;
      case 'playbook':
        final playbooks = await storageService.loadPlaybooks();
        final index = playbooks.indexWhere(
          (playbook) => playbook.id == binding.resourceId,
        );
        return index >= 0 &&
            _playbookActionFingerprint(playbooks[index]) ==
                binding.resourceFingerprint;
      case 'monitor_selection':
        final rawSelectedIds = performanceMonitorToolService
            .getState()['selectedConnectionIds'];
        if (rawSelectedIds is! List) return false;
        final selectedIds =
            rawSelectedIds
                .map((item) => item?.toString().trim() ?? '')
                .where((item) => item.isNotEmpty)
                .toList(growable: false)
              ..sort();
        final boundIds = binding.connectionTargets.keys.toList()..sort();
        return selectedIds.isNotEmpty &&
            jsonEncode(selectedIds) == binding.resourceFingerprint &&
            _listEquals(selectedIds, boundIds);
      case 'server_metadata_update':
        final current = storageService.getConnection(
          binding.resourceId ?? request.connectionId,
        );
        return current != null &&
            jsonEncode(current.toJson()) == binding.resourceFingerprint;
      case 'ssh_session':
        final sessionId = binding.resourceId;
        if (sessionId == null || sessionId.isEmpty) return false;
        final session = sshService.getSession(sessionId);
        return session != null &&
            session.connectionId == binding.resourceFingerprint;
      default:
        return true;
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
  }) {
    return _executeBound(name, arguments, approvedWrite: approvedWrite);
  }

  @override
  Future<String> executeApproved(
    AiToolApprovalRequest request,
    Map<String, dynamic> arguments,
  ) async {
    if (!await isApprovalTargetCurrent(request)) {
      return jsonEncode({
        'error':
            'The approved target or resource changed before execution. Review it and approve again.',
        'code': 'approval_target_changed',
        'command': request.command,
      });
    }
    return _executeBound(
      request.toolName,
      arguments,
      approvedWrite: true,
      approvalBinding: request.executionBinding,
    );
  }

  String _serverMetadataApprovalPreview(
    ConnectionConfig current,
    ConnectionConfig candidate,
    List<String> keys,
  ) {
    final lines = <String>[
      'Target: ${current.username}@${current.host}:${current.port} -> '
          '${candidate.username}@${candidate.host}:${candidate.port}',
      for (final key in keys)
        '$key: ${_serverMetadataValue(current, key)} -> '
            '${_serverMetadataValue(candidate, key)}',
    ];
    return lines.join('\n');
  }

  Object? _serverMetadataValue(ConnectionConfig config, String key) {
    return switch (key) {
      'name' => config.name,
      'host' => config.host,
      'port' => config.port,
      'username' => config.username,
      'group' => config.group,
      'serverPlatform' => config.serverPlatform.name,
      'launchMode' => config.launchMode.name,
      'tmuxAutoDeleteSeconds' => config.tmuxAutoDeleteSeconds,
      'keepAlive' => config.keepAlive,
      'keepAliveInterval' => config.keepAliveInterval,
      'terminalWidth' => config.terminalWidth,
      'terminalHeight' => config.terminalHeight,
      'jumpHost' => config.jumpHost,
      'jumpPort' => config.jumpPort,
      'jumpUsername' => config.jumpUsername,
      _ => null,
    };
  }

  static bool _listEquals(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  Future<String> _executeBound(
    String name,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
    AiToolApprovalExecutionBinding? approvalBinding,
  }) async {
    final turnTargets = _connectionTargets;
    final executionTargets = turnTargets == null && approvalBinding == null
        ? null
        : <String, ConnectionTargetBinding>{
            ...?turnTargets,
            ...?approvalBinding?.connectionTargets,
          };

    Future<String> action() {
      return runZoned(
        () => _executeInternal(
          name,
          arguments,
          approvedWrite: approvedWrite,
          executionTargets: executionTargets,
        ),
        zoneValues: {_approvalBindingZoneKey: approvalBinding},
      );
    }

    try {
      if (executionTargets == null) return await action();
      return await RemoteTargetScope.run(executionTargets, action);
    } on RemoteTargetScopeException catch (error) {
      return jsonEncode({
        'error':
            'The selected server changed before the remote operation began. Review the current target and try again.',
        'code': 'approval_target_changed',
        'details': error.toString(),
      });
    }
  }

  Future<String> _executeInternal(
    String name,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
    required Map<String, ConnectionTargetBinding>? executionTargets,
  }) async {
    final availableTools = await tools();
    final hasTool = availableTools.any((t) => t.name == name);
    if (!hasTool) {
      AppLogService.instance.warning(
        'Unknown AI tool requested',
        details: name,
      );
      return jsonEncode({'error': 'Unknown tool: $name'});
    }

    final tool = availableTools.firstWhere((t) => t.name == name);
    final explicitConnectionId = arguments['connectionId'];
    if (executionTargets != null &&
        explicitConnectionId is String &&
        explicitConnectionId.trim().isNotEmpty &&
        explicitConnectionId.trim() != 'local' &&
        (!executionTargets.containsKey(explicitConnectionId.trim()) ||
            !executionTargets[explicitConnectionId.trim()]!.matches(
              storageService.getConnection(explicitConnectionId.trim()),
            ))) {
      return jsonEncode({
        'error':
            'This server was not part of the turn or approval target snapshot.',
        'code': 'approval_target_changed',
        'tool': name,
      });
    }
    final explicitConnectionIds = arguments['connectionIds'];
    if (executionTargets != null && explicitConnectionIds is List) {
      final missing = explicitConnectionIds
          .whereType<String>()
          .map((id) => id.trim())
          .where(
            (id) =>
                id.isNotEmpty &&
                id != 'local' &&
                (!executionTargets.containsKey(id) ||
                    !executionTargets[id]!.matches(
                      storageService.getConnection(id),
                    )),
          )
          .toList(growable: false);
      if (missing.isNotEmpty) {
        return jsonEncode({
          'error':
              'One or more servers were not part of the turn or approval target snapshot.',
          'code': 'approval_target_changed',
          'tool': name,
        });
      }
    }
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
              'Ask the user to select a server connection before running this tool.',
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

      rawResult ??= jsonEncode({
        'error': 'Execution handler missing for tool: $name',
      });

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
      'minimum': ?minimum,
      'maximum': ?maximum,
      'default': ?defaultValue,
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
      'minItems': ?minimumItems,
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
      'minItems': ?minimumItems,
    };
  }
}

String _aiSkillFingerprint(AiSkillRecord skill) => jsonEncode(skill.toJson());

String _playbookActionFingerprint(Playbook playbook) {
  return jsonEncode({
    'id': playbook.id,
    'name': playbook.name,
    'description': playbook.description,
    'steps': playbook.steps
        .map(
          (step) => {
            'id': step.id,
            'name': step.name,
            'command': step.command,
            'description': step.description,
            'expectedOutcomeRegex': step.expectedOutcomeRegex,
          },
        )
        .toList(growable: false),
  });
}

class _ApprovedSkillUpdate {
  final AiSkillRecord expected;
  final AiSkillRecord updated;

  const _ApprovedSkillUpdate({required this.expected, required this.updated});
}

class _ApprovedPlaybookRun {
  final Playbook playbook;
  final String actionFingerprint;

  const _ApprovedPlaybookRun({
    required this.playbook,
    required this.actionFingerprint,
  });
}

class _ApprovedServerMetadataUpdate {
  final ConnectionConfig expected;
  final ConnectionConfig candidate;

  _ApprovedServerMetadataUpdate({
    required ConnectionConfig expected,
    required ConnectionConfig candidate,
  }) : expected = ConnectionConfig.fromJson(expected.toJson()),
       candidate = ConnectionConfig.fromJson(candidate.toJson());
}
