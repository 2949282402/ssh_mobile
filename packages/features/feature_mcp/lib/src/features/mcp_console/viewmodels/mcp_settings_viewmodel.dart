import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../application/mcp_port_probe.dart';
import '../../../application/mcp_server_controller.dart';
import '../../../domain/mcp_config_templates.dart';
import '../../../domain/mcp_ports.dart';
import '../../../domain/mcp_server_settings.dart';

/// MCP 设置路由级 ViewModel；只协调设置 Port 与 App Scope Controller。
class McpSettingsViewModel extends ChangeNotifier {
  final McpSettingsPort settingsPort;
  final McpServerController controller;

  McpSettingsViewModel({required this.settingsPort, required this.controller}) {
    settingsPort.addListener(_notify);
    controller.addListener(_notify);
  }

  @override
  void dispose() {
    settingsPort.removeListener(_notify);
    controller.removeListener(_notify);
    super.dispose();
  }

  McpServerSettings get settings => settingsPort.mcpSettings;
  McpServerStatusSnapshot get status => controller.snapshot;
  bool get running => controller.running;
  bool get portRequiresRestart => running && status.port != settings.port;
  McpPortProbeResult? get lastPortProbe => controller.lastPortProbeResult;
  McpApprovalMode get approvalMode => settings.approvalMode;
  Set<String> get secondaryReviewTools => settings.secondaryReviewTools;
  String get maskedToken {
    final token = settingsPort.mcpSettings.token;
    if (token.length <= 8) return '••••••••';
    return '••••••••${token.substring(token.length - 4)}';
  }

  String get codexConfig => McpConfigTemplates.codex(settings);
  String get claudeConfig => McpConfigTemplates.claudeCode(settings);
  String get geminiConfig => McpConfigTemplates.geminiCli(settings);

  Future<void> setEnabled(bool value) async {
    await settingsPort.setMcpServerEnabled(value);
    if (value) {
      await controller.start();
    } else {
      await controller.stop();
    }
  }

  Future<void> setPort(int port) => settingsPort.setMcpServerPort(port);

  Future<void> setApprovalMode(McpApprovalMode mode) async {
    await settingsPort.setMcpApprovalMode(mode);
    controller.rejectPendingApprovalsForPolicyChange();
  }

  Future<void> setToolSecondaryReview(String toolName, bool enabled) async {
    await settingsPort.setMcpToolSecondaryReview(toolName, enabled);
    controller.rejectPendingApprovalsForPolicyChange();
  }

  Future<McpPortProbeResult> checkPort() => controller.checkPort();

  Future<void> restart() => controller.restart();

  Future<void> regenerateToken() async {
    final wasRunning = running;
    await settingsPort.regenerateMcpServerToken();
    if (wasRunning) await controller.restart();
  }

  void _notify() {
    notifyListeners();
  }
}
