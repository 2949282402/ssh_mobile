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

class ToolExposureSelection {
  final List<AiTool> tools;
  final Set<String> selectedToolSet;

  const ToolExposureSelection({
    required this.tools,
    required this.selectedToolSet,
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

    for (final tool in tools) {
      if (normalizedAllowed != null &&
          !normalizedAllowed.contains(tool.name.toLowerCase())) {
        continue;
      }
      if (context.planMode && !tool.executionMode.allowedInPlanMode) {
        continue;
      }
      if (!context.planMode &&
          tool.executionMode == AiToolExecutionMode.planOnly) {
        continue;
      }
      if (!context.hasApprovedPlan &&
          tool.executionMode == AiToolExecutionMode.executionOnly) {
        continue;
      }
      if (tool.needsWebViewSession && !context.hasWebViewSession) {
        continue;
      }
      if (tool.needsServerSelection &&
          context.selectedConnectionIds.isEmpty &&
          !_isServerRelevantRequest(context.userRequest, requestedCaps)) {
        continue;
      }
      if (requestedCaps.isNotEmpty &&
          tool.effectiveCapabilities.isNotEmpty &&
          requestedCaps.intersection(tool.effectiveCapabilities).isEmpty &&
          !_isBaselineTool(tool, context)) {
        continue;
      }
      selected.add(tool);
    }

    return ToolExposureSelection(
      tools: selected,
      selectedToolSet: selected.map((tool) => tool.name).toSet(),
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
      '网址',
      '搜索',
      '网页',
      '外部',
    ])) {
      caps.add(AiToolCapability.web);
    }
    if (_containsAny(request, const [
      'log',
      'trace',
      '日志',
      '报错',
    ])) {
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
      'device',
      'clipboard',
      '设置',
      '权限',
      '设备',
      '剪贴板',
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
