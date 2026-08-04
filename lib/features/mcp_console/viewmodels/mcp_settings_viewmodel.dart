import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../services/app_settings.dart';
import '../../../services/mcp/mcp_config_templates.dart';
import '../../../services/mcp/mcp_port_probe.dart';
import '../../../services/mcp/mcp_server_controller.dart';
import '../../../services/mcp/mcp_server_settings.dart';

class McpSettingsViewModel extends ChangeNotifier {
  final AppSettings appSettings;
  final McpServerController controller;

  McpSettingsViewModel({required this.appSettings, required this.controller}) {
    appSettings.addListener(_notify);
    controller.addListener(_notify);
  }

  @override
  void dispose() {
    appSettings.removeListener(_notify);
    controller.removeListener(_notify);
    super.dispose();
  }

  McpServerSettings get settings => appSettings.mcpSettings;
  McpServerStatusSnapshot get status => controller.snapshot;
  bool get running => controller.running;
  bool get portRequiresRestart => running && status.port != settings.port;
  McpPortProbeResult? get lastPortProbe => controller.lastPortProbeResult;
  McpApprovalMode get approvalMode => settings.approvalMode;
  Set<String> get secondaryReviewTools => settings.secondaryReviewTools;
  String get maskedToken {
    final token = appSettings.mcpServerToken;
    if (token.length <= 8) return '••••••••';
    return '••••••••${token.substring(token.length - 4)}';
  }

  String get codexConfig => McpConfigTemplates.codex(settings);
  String get claudeConfig => McpConfigTemplates.claudeCode(settings);
  String get geminiConfig => McpConfigTemplates.geminiCli(settings);

  Future<void> setEnabled(bool value) async {
    await appSettings.setMcpServerEnabled(value);
    if (value) {
      await controller.start();
    } else {
      await controller.stop();
    }
  }

  Future<void> setPort(int port) => appSettings.setMcpServerPort(port);

  Future<void> setApprovalMode(McpApprovalMode mode) async {
    await appSettings.setMcpApprovalMode(mode);
    controller.rejectPendingApprovalsForPolicyChange();
  }

  Future<void> setToolSecondaryReview(String toolName, bool enabled) async {
    await appSettings.setMcpToolSecondaryReview(toolName, enabled);
    controller.rejectPendingApprovalsForPolicyChange();
  }

  Future<McpPortProbeResult> checkPort() => controller.checkPort();

  Future<void> restart() => controller.restart();

  Future<void> regenerateToken() async {
    final wasRunning = running;
    await appSettings.regenerateMcpServerToken();
    if (wasRunning) await controller.restart();
  }

  void _notify() {
    notifyListeners();
  }
}
