import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../application/mcp_approval_queue.dart';
import '../../../application/mcp_server_controller.dart';
import '../../../application/mcp_self_test_runner.dart';
import '../../../domain/mcp_activity.dart';
import '../../../domain/mcp_ports.dart';
import '../../../domain/mcp_server_settings.dart';
import '../../../domain/mcp_config_templates.dart';

/// MCP 控制台路由级状态；只持有 Module 服务和设置 Port，不创建全局资源。
class McpConsoleViewModel extends ChangeNotifier {
  final McpServerController _controller;
  final McpSettingsPort _settings;
  final McpApprovalQueue _approvalQueue;

  List<McpActivityRecord> _activities = const [];
  List<McpToolPolicySnapshot> _tools = const [];
  McpActivityOutcome? _selectedOutcome;
  McpSelfTestResult? _lastSelfTest;
  bool _loading = true;
  bool _loadingPolicies = false;
  bool _pendingPolicyReload = false;
  bool _runningAction = false;
  String? _errorCode;

  McpConsoleViewModel(this._controller, this._settings)
    : _approvalQueue = _controller.approvalQueue {
    _controller.addListener(_onControllerChanged);
    _settings.addListener(_onSettingsChanged);
    _approvalQueue.addListener(_onApprovalQueueChanged);
    unawaited(refresh());
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _settings.removeListener(_onSettingsChanged);
    _approvalQueue.removeListener(_onApprovalQueueChanged);
    super.dispose();
  }

  McpServerStatusSnapshot get status => _controller.snapshot;
  bool get isEnglish => _settings.isEnglish;
  McpApprovalMode get approvalMode => _settings.mcpSettings.approvalMode;
  bool get exposureToolsConfigured =>
      _settings.mcpSettings.exposureToolsConfigured;
  bool get loading => _loading;
  bool get runningAction => _runningAction;
  String? get errorCode => _errorCode;
  McpSelfTestResult? get lastSelfTest => _lastSelfTest;
  McpActivityOutcome? get selectedOutcome => _selectedOutcome;
  List<McpToolPolicySnapshot> get tools => _tools;
  List<McpApprovalSnapshot> get approvals => _approvalQueue.pending;
  List<McpActivityRecord> get activities => _selectedOutcome == null
      ? _activities
      : _activities
            .where((item) => item.outcome == _selectedOutcome)
            .toList(growable: false);
  String get maskedToken {
    final token = _settings.mcpSettings.token;
    if (token.length <= 8) return '••••••••';
    return '••••••••${token.substring(token.length - 4)}';
  }

  String get codexConfig => McpConfigTemplates.codex(_settings.mcpSettings);
  String get claudeConfig =>
      McpConfigTemplates.claudeCode(_settings.mcpSettings);
  String get geminiConfig =>
      McpConfigTemplates.geminiCli(_settings.mcpSettings);

  Future<void> refresh() async {
    _loading = true;
    _errorCode = null;
    notifyListeners();
    try {
      final values = await Future.wait<Object>([
        _controller.loadRecentActivity(),
        _controller.loadToolPolicySnapshot(),
      ]);
      _activities = values[0] as List<McpActivityRecord>;
      _tools = values[1] as List<McpToolPolicySnapshot>;
    } catch (_) {
      _errorCode = 'load_failed';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void setSelectedOutcome(McpActivityOutcome? outcome) {
    if (_selectedOutcome == outcome) return;
    _selectedOutcome = outcome;
    notifyListeners();
  }

  Future<void> start() => _runAction(() => _controller.start());
  Future<void> stop() => _runAction(_controller.stop);
  Future<void> restart() => _runAction(_controller.restart);
  Future<void> checkPort() => _runAction(_controller.checkPort);

  Future<void> runSelfTest() async {
    await _runAction(() async {
      _lastSelfTest = await _controller.runSelfTest();
    });
  }

  Future<void> clearActivities() => _runAction(_controller.clearRecentActivity);

  Future<void> approve(String id) => _approvalQueue.approve(id);

  void reject(String id) => _approvalQueue.reject(id);

  Future<void> setToolExposure(String toolName, bool exposed) async {
    await _settings.setMcpToolExposure(
      toolName,
      exposed,
      availableToolNames: {
        for (final tool in _tools)
          if (tool.exposureConfigurable) tool.name,
      },
    );
    await _reloadPolicies();
  }

  Future<void> setToolSecondaryReview(String toolName, bool enabled) async {
    final next = Set<String>.of(_settings.mcpSettings.secondaryReviewTools);
    if (enabled) {
      next.add(toolName);
    } else {
      next.remove(toolName);
    }
    await _settings.setMcpSecondaryReviewTools(next);
    await _reloadPolicies();
  }

  Future<void> _runAction(Future<dynamic> Function() action) async {
    if (_runningAction) return;
    _runningAction = true;
    _errorCode = null;
    notifyListeners();
    try {
      await action();
      await refresh();
    } catch (_) {
      _errorCode = 'action_failed';
      notifyListeners();
    } finally {
      _runningAction = false;
      notifyListeners();
    }
  }

  void _onControllerChanged() {
    notifyListeners();
  }

  void _onSettingsChanged() {
    notifyListeners();
    unawaited(_reloadPolicies());
  }

  void _onApprovalQueueChanged() {
    notifyListeners();
  }

  Future<void> _reloadPolicies() async {
    if (_loadingPolicies) {
      // A reload is already in flight; queue one more pass instead of dropping
      // the request, so rapid consecutive exposure/review toggles converge on
      // the latest settings instead of leaving a stale policy snapshot.
      _pendingPolicyReload = true;
      return;
    }
    _loadingPolicies = true;
    try {
      do {
        _pendingPolicyReload = false;
        try {
          _tools = await _controller.loadToolPolicySnapshot();
        } catch (_) {
          _errorCode ??= 'load_failed';
        }
      } while (_pendingPolicyReload);
    } finally {
      _loadingPolicies = false;
      notifyListeners();
    }
  }
}
