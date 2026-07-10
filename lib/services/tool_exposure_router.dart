import 'ai_tool_service.dart';

enum AiToolCapability {
  client,
  server,
  ssh,
  sftp,
  monitor,
  web,
  planning,
  playbook,
  diagnostics,
  logs,
  settings,
}

class ToolExposureContext {
  final String userRequest;
  final bool planMode;
  final bool hasWebViewSession;
  final bool hasApprovedPlan;
  final Set<String> selectedConnectionIds;
  final Set<String>? allowedTools;

  const ToolExposureContext({
    required this.userRequest,
    this.planMode = false,
    this.hasWebViewSession = false,
    this.hasApprovedPlan = false,
    this.selectedConnectionIds = const {},
    this.allowedTools,
  });
}

class ToolExposureDecision {
  final String toolName;
  final bool selected;
  final List<String> reasons;
  final List<String> blockedBy;
  final Set<AiToolCapability> toolCapabilities;

  const ToolExposureDecision({
    required this.toolName,
    required this.selected,
    required this.reasons,
    required this.blockedBy,
    required this.toolCapabilities,
  });

  Map<String, dynamic> toJson() {
    return {
      'toolName': toolName,
      'selected': selected,
      'reasons': reasons,
      'blockedBy': blockedBy,
      'toolCapabilities': toolCapabilities.map((c) => c.name).toList(),
    };
  }
}

class ToolExposureSelection {
  final List<AiTool> tools;
  final Set<String> selectedToolSet;
  final Set<AiToolCapability> requestedCapabilities;
  final List<ToolExposureDecision> decisions;

  const ToolExposureSelection({
    required this.tools,
    required this.selectedToolSet,
    required this.requestedCapabilities,
    required this.decisions,
  });
}

class ToolExposureRouter {
  const ToolExposureRouter();

  ToolExposureSelection selectTools(
    Iterable<AiTool> tools, {
    required ToolExposureContext context,
  }) {
    final normalizedAllowed = context.allowedTools
        ?.map((tool) => tool.trim().toLowerCase())
        .where((tool) => tool.isNotEmpty)
        .toSet();
    final requestedCaps = _requestedCapabilities(context);
    final selected = <AiTool>[];
    final decisions = <ToolExposureDecision>[];

    for (final tool in tools) {
      final blockedBy = <String>[];
      final reasons = <String>[];

      if (normalizedAllowed != null &&
          !normalizedAllowed.contains(tool.name.toLowerCase())) {
        blockedBy.add('allowedTools_filter');
      }
      if (context.planMode && !tool.executionMode.allowedInPlanMode) {
        blockedBy.add('plan_mode_blocked');
      }
      if (!context.planMode &&
          tool.executionMode == AiToolExecutionMode.planOnly) {
        blockedBy.add('plan_only_outside_plan_mode');
      }
      if (!context.hasApprovedPlan &&
          tool.executionMode == AiToolExecutionMode.executionOnly) {
        blockedBy.add('execution_only_without_approved_plan');
      }
      if (tool.needsWebViewSession && !context.hasWebViewSession) {
        blockedBy.add('webview_session_missing');
      }
      if (tool.needsServerSelection &&
          !context.planMode &&
          context.selectedConnectionIds.isEmpty &&
          !_isServerRelevantRequest(context.userRequest, requestedCaps)) {
        blockedBy.add('server_selection_missing');
      }
      final hasCapabilityMismatch =
          requestedCaps.isNotEmpty &&
          tool.effectiveCapabilities.isNotEmpty &&
          requestedCaps.intersection(tool.effectiveCapabilities).isEmpty &&
          !_isBaselineTool(tool, context);
      if (hasCapabilityMismatch) {
        blockedBy.add('capability_mismatch');
      }

      final isSelected = blockedBy.isEmpty;
      if (isSelected) {
        selected.add(tool);
        reasons.add('selected');
        if (_isBaselineTool(tool, context)) {
          reasons.add('baseline_tool_allowed');
        } else if (requestedCaps.isNotEmpty &&
            tool.effectiveCapabilities.isNotEmpty &&
            requestedCaps.intersection(tool.effectiveCapabilities).isNotEmpty) {
          reasons.add('selected_by_capability');
        } else if (normalizedAllowed != null &&
            normalizedAllowed.contains(tool.name.toLowerCase())) {
          reasons.add('selected_by_allowedTools');
        } else if (context.planMode && tool.executionMode.allowedInPlanMode) {
          reasons.add('selected_by_plan_mode');
        }
      }

      decisions.add(
        ToolExposureDecision(
          toolName: tool.name,
          selected: isSelected,
          reasons: reasons,
          blockedBy: blockedBy,
          toolCapabilities: tool.effectiveCapabilities,
        ),
      );
    }

    return ToolExposureSelection(
      tools: selected,
      selectedToolSet: selected.map((tool) => tool.name).toSet(),
      requestedCapabilities: requestedCaps,
      decisions: decisions,
    );
  }

  Set<AiToolCapability> _requestedCapabilities(ToolExposureContext context) {
    final request = context.userRequest.toLowerCase();
    final caps = <AiToolCapability>{};
    if (context.planMode ||
        request.contains('plan') ||
        request.contains('步骤')) {
      caps.add(AiToolCapability.planning);
    }
    if (_containsAny(request, const [
      'search',
      'latest',
      'news',
      'web',
      'browser',
      'current',
      'client/sch',
      '网址',
      '搜索',
      '网页',
      '外部',
      '最新',
      '新闻',
      '现在',
    ])) {
      caps.add(AiToolCapability.web);
    }
    if (_containsAny(request, const ['log', 'trace', '日志', '报错'])) {
      caps.add(AiToolCapability.logs);
      caps.add(AiToolCapability.diagnostics);
    }
    if (_containsAny(request, const [
      'file',
      'path',
      'directory',
      'upload',
      'download',
      'sftp',
      '.yml',
      '.yaml',
      '.json',
      '.conf',
      '文件',
      '目录',
      '路径',
      '上传',
      '下载',
    ])) {
      caps.add(AiToolCapability.sftp);
    }
    if (_containsAny(request, const [
      'terminal',
      'session',
      'tmux',
      'ssh',
      '终端',
      '会话',
    ])) {
      caps.add(AiToolCapability.ssh);
      caps.add(AiToolCapability.server);
    }
    if (_containsAny(request, const [
      'monitor',
      'cpu',
      'memory',
      'port',
      'process',
      'service',
      'health',
      '性能',
      '监控',
      '端口',
      '进程',
      '服务',
      '健康',
    ])) {
      caps.add(AiToolCapability.monitor);
      caps.add(AiToolCapability.diagnostics);
    }
    if (_containsAny(request, const [
      'server',
      'deploy',
      'ops',
      'debug',
      'diagnose',
      'fix',
      '服务器',
      '排查',
      '诊断',
      '修复',
      '运维',
    ])) {
      caps.add(AiToolCapability.server);
      caps.add(AiToolCapability.diagnostics);
    }
    if (_containsAny(request, const [
      'setting',
      'permission',
      'runtime',
      'health',
      'battery',
      'network',
      'background',
      'device',
      'clipboard',
      'skill',
      'skills',
      'experience',
      '设置',
      '权限',
      '运行环境',
      '健康',
      '电池',
      '网络',
      '后台',
      '设备',
      '剪贴板',
      '技能',
      '经验',
    ])) {
      caps.add(AiToolCapability.client);
      caps.add(AiToolCapability.settings);
    }
    if (_isExplicitPlaybookRequest(request)) {
      caps.add(AiToolCapability.playbook);
    }
    if (context.hasApprovedPlan) {
      caps.add(AiToolCapability.planning);
    }
    return caps;
  }

  bool _isBaselineTool(AiTool tool, ToolExposureContext context) {
    if (tool.name == 'list_servers') return true;
    if (tool.name == 'client_set_plan_mode') return context.planMode;
    if (tool.name == 'client_check_runtime_health') {
      return context.hasApprovedPlan;
    }
    if (tool.name == 'client_task_create') return context.planMode;
    if (tool.name == 'client_task_update') return context.hasApprovedPlan;
    return false;
  }

  bool _isServerRelevantRequest(
    String request,
    Set<AiToolCapability> capabilities,
  ) {
    if (capabilities.contains(AiToolCapability.server) ||
        capabilities.contains(AiToolCapability.ssh) ||
        capabilities.contains(AiToolCapability.sftp) ||
        capabilities.contains(AiToolCapability.monitor) ||
        capabilities.contains(AiToolCapability.diagnostics)) {
      return true;
    }
    final lower = request.toLowerCase();
    return lower.contains('server') ||
        lower.contains('ssh') ||
        lower.contains('服务器');
  }

  bool _containsAny(String text, List<String> needles) {
    return needles.any(text.contains);
  }

  bool _isExplicitPlaybookRequest(String request) {
    if (_containsAny(request, const [
      'playbook',
      'playbooks',
      '剧本',
      'runbook',
    ])) {
      return true;
    }
    final wantsPersistence = _containsAny(request, const [
      'save',
      'saved',
      'persist',
      'store',
      'reuse',
      'reusable',
      'template',
      '保存',
      '持久化',
      '存起来',
      '复用',
      '可复用',
      '模板',
    ]);
    final mentionsScriptArtifact = _containsAny(request, const [
      'script',
      'scripts',
      'workflow',
      '运维脚本',
      '脚本',
      '命令集',
    ]);
    return wantsPersistence && mentionsScriptArtifact;
  }
}
