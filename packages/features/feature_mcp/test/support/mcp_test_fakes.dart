import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:feature_mcp/feature_mcp.dart';

/// 测试用设置 Port；用内存状态模拟 App Shell 持久化设置，不触碰平台存储。
class FakeMcpSettingsPort extends ChangeNotifier implements McpSettingsPort {
  FakeMcpSettingsPort({McpServerSettings? value})
    : _value = value ?? const McpServerSettings();

  McpServerSettings _value;
  bool _isEnglish = false;
  int _tokenVersion = 0;

  @override
  McpServerSettings get mcpSettings => _value;

  @override
  bool get isEnglish => _isEnglish;

  void toggleLanguage() {
    _isEnglish = !_isEnglish;
    notifyListeners();
  }

  @override
  Future<void> ensureCoreLoaded() async {}

  @override
  Future<String> ensureMcpServerToken() async {
    if (_value.hasToken) return _value.token;
    return regenerateMcpServerToken();
  }

  @override
  Future<void> setMcpServerEnabled(bool value) async {
    _update(_value.copyWith(enabled: value));
  }

  @override
  Future<void> setMcpServerPort(int port) async {
    _update(_value.copyWith(port: port));
  }

  @override
  Future<void> setMcpApprovalMode(McpApprovalMode mode) async {
    _update(_value.copyWith(approvalMode: mode));
  }

  @override
  Future<void> setMcpToolExposure(
    String toolName,
    bool exposed, {
    required Set<String> availableToolNames,
  }) async {
    final exposedTools = {..._value.exposedTools};
    if (exposed) {
      exposedTools.add(toolName);
    } else {
      exposedTools.remove(toolName);
    }
    _update(
      _value.copyWith(
        exposedTools: exposedTools,
        exposureToolsConfigured: true,
      ),
    );
  }

  @override
  Future<void> setMcpToolSecondaryReview(String toolName, bool enabled) async {
    final tools = {..._value.secondaryReviewTools};
    if (enabled) {
      tools.add(toolName);
    } else {
      tools.remove(toolName);
    }
    _update(_value.copyWith(secondaryReviewTools: tools));
  }

  @override
  Future<void> setMcpSecondaryReviewTools(Set<String> tools) async {
    _update(_value.copyWith(secondaryReviewTools: tools));
  }

  @override
  Future<String> regenerateMcpServerToken() async {
    _tokenVersion++;
    final token = 'test-token-${_tokenVersion.toString().padLeft(2, '0')}';
    _update(_value.copyWith(token: token));
    return token;
  }

  void _update(McpServerSettings next) {
    _value = next;
    notifyListeners();
  }
}

/// 测试用日志 Port；验证行为时不输出真实应用日志。
class FakeMcpLogger implements McpLoggerPort {
  const FakeMcpLogger();

  @override
  void info(String message, {String? details}) {}

  @override
  void warning(String message, {String? details}) {}

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {}
}

/// 测试用内存活动仓储；生产仓储由 MCP Module 的 mcp.db 提供。
class FakeMcpActivityRepository implements McpActivityRepository {
  final records = <McpActivityRecord>[];

  @override
  Future<List<McpActivityRecord>> loadMcpActivityRecords({int limit = 500}) {
    return Future.value(records.reversed.take(limit).toList(growable: false));
  }

  @override
  Future<void> recordMcpActivity(McpActivityRecord record) async {
    records.add(record);
  }

  @override
  Future<void> clearMcpActivityRecords() async {
    records.clear();
  }
}

/// 测试用工具图，覆盖控制台展示所需的只读、写入和隐藏工具。
class FakeMcpToolExecutor implements McpToolExecutor {
  FakeMcpToolExecutor({List<McpTool>? values})
    : values =
          values ??
          const [
            McpTool(
              name: 'list_servers',
              description: 'List saved servers.',
              properties: {},
            ),
            McpTool(
              name: 'run_command',
              description: 'Run a remote command.',
              properties: {},
              executionMode: McpToolExecutionMode.stateChanging,
            ),
            McpTool(
              name: 'ssh_rename_session',
              description: 'Rename an SSH session.',
              properties: {},
              executionMode: McpToolExecutionMode.stateChanging,
            ),
            McpTool(
              name: 'client_set_plan_mode',
              description: 'Plan mode.',
              properties: {},
              executionMode: McpToolExecutionMode.planControl,
            ),
          ];

  final List<McpTool> values;
  final executedTools = <String>[];

  @override
  Future<List<McpTool>> tools() async => values;

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async {
    const adapter = McpAiToolAdapter();
    return values.map(adapter.toMcpTool).toList();
  }

  @override
  Future<McpApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async => null;

  @override
  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async {
    executedTools.add(name);
    return jsonEncode({'ok': true});
  }
}

/// 创建控制器时统一注入测试资源，避免 UI 测试自行创建 App Scope 单例。
McpServerController createTestMcpController(
  McpSettingsPort settings,
  McpToolExecutor Function() toolServiceFactory,
) {
  return McpServerController(
    settings: settings,
    toolServiceFactory: toolServiceFactory,
    activityRepository: FakeMcpActivityRepository(),
    logger: const FakeMcpLogger(),
  );
}
