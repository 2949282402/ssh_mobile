import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../services/app_settings.dart';
import '../../../services/mcp/mcp_activity.dart';
import '../../../services/mcp/mcp_approval_queue.dart';
import '../../../services/mcp/mcp_config_templates.dart';
import '../../../services/mcp/mcp_server_controller.dart';
import '../../../services/mcp/mcp_server_settings.dart';

class McpConsoleViewModel extends ChangeNotifier {
  final McpServerController _controller;
  final AppSettings _appSettings;
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

  McpConsoleViewModel(this._controller, this._appSettings)
    : _approvalQueue = _controller.approvalQueue {
    _controller.addListener(_onControllerChanged);
    _appSettings.addListener(_onSettingsChanged);
    _approvalQueue.addListener(_onApprovalQueueChanged);
    unawaited(refresh());
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _appSettings.removeListener(_onSettingsChanged);
    _approvalQueue.removeListener(_onApprovalQueueChanged);
    super.dispose();
  }

  McpServerStatusSnapshot get status => _controller.snapshot;
  AppLanguage get language => _appSettings.language;
  bool get isEnglish => language == AppLanguage.en;
  McpApprovalMode get approvalMode => _appSettings.mcpApprovalMode;
  bool get exposureToolsConfigured => _appSettings.mcpExposureToolsConfigured;
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
    final token = _appSettings.mcpServerToken;
    if (token.length <= 8) return '••••••••';
    return '••••••••${token.substring(token.length - 4)}';
  }

  String get codexConfig => McpConfigTemplates.codex(_appSettings.mcpSettings);
  String get claudeConfig =>
      McpConfigTemplates.claudeCode(_appSettings.mcpSettings);
  String get geminiConfig =>
      McpConfigTemplates.geminiCli(_appSettings.mcpSettings);

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
    await _appSettings.setMcpToolExposure(
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
    final next = Set<String>.of(_appSettings.mcpSecondaryReviewTools);
    if (enabled) {
      next.add(toolName);
    } else {
      next.remove(toolName);
    }
    await _appSettings.setMcpSecondaryReviewTools(next);
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
