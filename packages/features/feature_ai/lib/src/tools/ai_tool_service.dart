import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_core/app_core.dart' as app_core;
import 'package:feature_playbook/feature_playbook.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import 'package:connection_core/connection_core.dart';
import 'package:feature_ai/src/domain/ai_compat.dart';
import 'package:feature_ai/src/agent/multi_agent_coordinator.dart';
import 'package:feature_ai/src/tools/remote_target_scope.dart';
import 'tool_exposure_router.dart';
import 'package:feature_ai/src/tools/tool_secret_policy.dart';
import 'package:feature_ai/src/skills/skill_domain_service.dart';
import 'package:feature_ai/src/agent/plan_execution_controller.dart';
import 'package:feature_ai/src/llm/provider/llm_api_format.dart';

part 'ai_tool_types.dart';
part 'ai_tool_approval.dart';
part 'client_tools.dart';
part 'tools/client_tools_schemas.dart';
part 'tools/client_tools_impl.dart';
part 'tools/client_device_tools_impl.dart';
part 'tools/client_app_tools_impl.dart';
part 'tools/client_plan_tools_impl.dart';
part 'server_tools.dart';
part 'ssh_tools.dart';
part 'sftp_tools.dart';
part 'monitor_tools.dart';
part 'playbook_tools.dart';
part 'security_policy.dart';

class AiToolService
    implements
        AiToolExecutor,
        AiToolApprovalTargetGuard,
        McpApprovalRequestProvider {
  String get _clientScopeId => 'client';
  String get _clientScopeName => 'SSH Mobile client';
  static const int _maxToolTextChars = 12000;

  final AiStoragePort storageService;
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
  final PlaybookAutomationPort? playbookService;
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
    required AiStoragePort storageService,
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
    PlaybookAutomationPort? playbookService,
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

  @override
  Future<AiToolApprovalRequest?> mcpApprovalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final request = await _buildMcpApprovalRequest(name, arguments);
    if (request != null) return _bindApprovalRequest(request, arguments);
    return approvalRequestFor(name, arguments);
  }

  @override
  Future<bool> isApprovalTargetCurrent(AiToolApprovalRequest request) {
    return _isApprovalTargetCurrentImpl(request);
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

  bool _listEquals(List<String> left, List<String> right) {
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
