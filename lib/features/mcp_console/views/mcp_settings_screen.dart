import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../services/app_settings.dart';
import '../../../services/mcp/mcp_port_probe.dart';
import '../../../services/mcp/mcp_server_controller.dart';
import '../../../services/mcp/mcp_server_settings.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/app_surface.dart';
import '../viewmodels/mcp_settings_viewmodel.dart';

class McpSettingsScreen extends StatefulWidget {
  const McpSettingsScreen({super.key});

  @override
  State<McpSettingsScreen> createState() => _McpSettingsScreenState();
}

class _McpSettingsScreenState extends State<McpSettingsScreen> {
  final TextEditingController _portController = TextEditingController();
  final FocusNode _portFocusNode = FocusNode();
  Timer? _portDebounce;
  String? _portMessage;
  bool _checkingPort = false;

  @override
  void dispose() {
    _portDebounce?.cancel();
    _portController.dispose();
    _portFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<McpSettingsViewModel>();
    final strings = AppStrings(vm.appSettings.language);
    if (!_portFocusNode.hasFocus &&
        _portController.text != '${vm.settings.port}') {
      _portController.text = '${vm.settings.port}';
    }
    final desktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS);

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.openMcpSettings),
        leading: IconButton(
          tooltip: strings.close,
          onPressed: () => Navigator.maybePop(context),
          icon: const Icon(Icons.close_rounded),
        ),
      ),
      body: AppPageSurface(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(AppTheme.compactPagePadding),
            children: [
              AppSectionCard(
                title: strings.mcpServer,
                subtitle: strings.mcpServerHint,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(strings.mcpServer),
                      subtitle: Text(_statusText(vm, strings)),
                      value: vm.settings.enabled,
                      onChanged: vm.setEnabled,
                    ),
                    Text('${strings.mcpHost}: ${vm.settings.host}'),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _portController,
                      focusNode: _portFocusNode,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: strings.mcpPort,
                        border: const OutlineInputBorder(),
                        suffixIcon: _checkingPort
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : IconButton(
                                tooltip: strings.mcpCheckPort,
                                onPressed: _checkPort,
                                icon: const Icon(Icons.search_rounded),
                              ),
                      ),
                      onChanged: _onPortChanged,
                    ),
                    if (_portMessage != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        _portMessage!,
                        style: TextStyle(
                          color: _portMessage == strings.mcpPortAvailable
                              ? Colors.green
                              : Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    _approvalModeSection(vm, strings),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: vm.restart,
                          icon: const Icon(Icons.restart_alt_rounded),
                          label: Text(strings.mcpRestart),
                        ),
                        OutlinedButton.icon(
                          onPressed: () async {
                            await vm.regenerateToken();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(strings.mcpTokenRegenerated),
                                ),
                              );
                            }
                          },
                          icon: const Icon(Icons.key_rounded),
                          label: Text(strings.mcpRegenerateToken),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('${strings.mcpServerToken}: ${vm.maskedToken}'),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              AppSectionCard(
                title: strings.mcpClientConfiguration,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _CopyButton(
                      label: strings.mcpCopyCodex,
                      text: vm.codexConfig,
                      strings: strings,
                    ),
                    _CopyButton(
                      label: strings.mcpCopyClaude,
                      text: vm.claudeConfig,
                      strings: strings,
                    ),
                    _CopyButton(
                      label: strings.mcpCopyGemini,
                      text: vm.geminiConfig,
                      strings: strings,
                    ),
                    if (desktop)
                      OutlinedButton.icon(
                        onPressed: () =>
                            Navigator.pushNamed(context, '/mcp-console'),
                        icon: const Icon(Icons.dashboard_outlined),
                        label: Text(strings.openMcpConsole),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _approvalModeSection(McpSettingsViewModel vm, AppStrings strings) {
    final reviewMode = vm.approvalMode == McpApprovalMode.reviewConfiguredTools;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Text(
          strings.mcpApprovalMode,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        RadioGroup<McpApprovalMode>(
          groupValue: vm.approvalMode,
          onChanged: (mode) {
            if (mode == null) return;
            if (mode == McpApprovalMode.trustedAgent) {
              unawaited(_selectApprovalMode(vm, mode, strings));
            } else {
              unawaited(vm.setApprovalMode(mode));
            }
          },
          child: Column(
            children: [
              RadioListTile<McpApprovalMode>(
                contentPadding: EdgeInsets.zero,
                value: McpApprovalMode.reviewConfiguredTools,
                title: Text(strings.mcpReviewConfiguredTools),
                subtitle: Text(strings.mcpReviewConfiguredToolsHint),
              ),
              RadioListTile<McpApprovalMode>(
                contentPadding: EdgeInsets.zero,
                value: McpApprovalMode.trustedAgent,
                title: Text(strings.mcpTrustedAgent),
                subtitle: Text(strings.mcpTrustedAgentHint),
              ),
            ],
          ),
        ),
        if (!reviewMode)
          AppSectionCard(
            title: strings.mcpTrustedAgentActive,
            subtitle: strings.mcpTrustedAgentActiveHint,
            child: Text(strings.mcpTrustedAgentSafetyBoundary),
          )
        else ...[
          const SizedBox(height: 4),
          Text(
            strings.mcpSecondaryReviewTools,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          Text(strings.mcpSecondaryReviewToolsHint),
          const SizedBox(height: 4),
          if (vm.secondaryReviewToolOptions.isEmpty)
            Text(strings.mcpNoReviewTools)
          else
            for (final tool in vm.secondaryReviewToolOptions)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: vm.secondaryReviewTools.contains(tool.name),
                title: Text(tool.name),
                subtitle: Text(
                  tool.descriptionFor(
                    vm.appSettings.language == AppLanguage.en,
                  ),
                ),
                secondary: Icon(
                  tool.destructive
                      ? Icons.warning_amber_rounded
                      : tool.readOnly
                      ? Icons.visibility_outlined
                      : Icons.build_outlined,
                ),
                onChanged: (enabled) {
                  if (enabled != null) {
                    unawaited(vm.setToolSecondaryReview(tool.name, enabled));
                  }
                },
              ),
        ],
      ],
    );
  }

  Future<void> _selectApprovalMode(
    McpSettingsViewModel vm,
    McpApprovalMode mode,
    AppStrings strings,
  ) async {
    if (mode != McpApprovalMode.trustedAgent) {
      await vm.setApprovalMode(mode);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.mcpTrustedAgentWarningTitle),
        content: Text(strings.mcpTrustedAgentWarningBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.mcpEnableTrustedAgent),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await vm.setApprovalMode(mode);
    }
  }

  String _statusText(McpSettingsViewModel vm, AppStrings strings) {
    final snapshot = vm.status;
    switch (snapshot.status) {
      case McpServerRunStatus.checkingPort:
        return strings.mcpCheckingPort;
      case McpServerRunStatus.starting:
        return strings.mcpStarting;
      case McpServerRunStatus.running:
        return vm.portRequiresRestart
            ? '${strings.mcpRunningAt(snapshot.url)}\n${strings.mcpPortRestartNeeded}'
            : strings.mcpRunningAt(snapshot.url);
      case McpServerRunStatus.failed:
        return snapshot.lastError ?? strings.mcpFailed;
      case McpServerRunStatus.stopped:
        return strings.mcpStopped;
    }
  }

  void _onPortChanged(String value) {
    _portDebounce?.cancel();
    final vm = context.read<McpSettingsViewModel>();
    final port = int.tryParse(value.trim());
    if (port == null || !McpServerSettings.isValidPort(port)) {
      setState(
        () => _portMessage = AppStrings(
          vm.appSettings.language,
        ).mcpPortInvalidMessage,
      );
      return;
    }
    setState(() => _portMessage = null);
    _portDebounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        await vm.setPort(port);
        if (!mounted) return;
        if (vm.running) {
          setState(
            () => _portMessage = AppStrings(
              vm.appSettings.language,
            ).mcpPortRestartNeeded,
          );
        } else {
          await _checkPort();
        }
      } catch (_) {
        if (mounted) {
          setState(
            () => _portMessage = AppStrings(
              vm.appSettings.language,
            ).mcpPortInvalidMessage,
          );
        }
      }
    });
  }

  Future<void> _checkPort() async {
    if (_checkingPort) return;
    setState(() => _checkingPort = true);
    try {
      final vm = context.read<McpSettingsViewModel>();
      final result = await vm.checkPort();
      if (!mounted) return;
      setState(
        () => _portMessage = _probeMessage(
          AppStrings(vm.appSettings.language),
          result,
        ),
      );
    } finally {
      if (mounted) setState(() => _checkingPort = false);
    }
  }

  String _probeMessage(AppStrings strings, McpPortProbeResult result) {
    if (result.available) return strings.mcpPortAvailable;
    if (result.reason == McpPortProbeReason.invalidHostOrPort) {
      return strings.mcpPortInvalidMessage;
    }
    return strings.mcpPortOccupied;
  }
}

class _CopyButton extends StatelessWidget {
  final String label;
  final String text;
  final AppStrings strings;

  const _CopyButton({
    required this.label,
    required this.text,
    required this.strings,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: text));
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(strings.mcpCopied)));
        }
      },
      icon: const Icon(Icons.copy_rounded),
      label: Text(label),
    );
  }
}
