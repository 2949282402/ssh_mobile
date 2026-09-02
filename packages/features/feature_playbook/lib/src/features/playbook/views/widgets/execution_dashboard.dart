part of '../playbook_screen.dart';

extension _PlaybookScreenExecutionDashboard on _PlaybookScreenState {
  Widget _buildExecutionDashboard(
    PlaybookViewModel viewModel,
    List<ConnectionConfig> connections,
    _PlaybookStrings strings,
    ColorScheme colorScheme,
  ) {
    final playbook = viewModel.activePlaybook;
    if (playbook == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.rocket_launch_outlined,
              size: 64,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              strings.selectPlaybookPrompt,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    final hasConnectedServer = connections.any(
      (c) => c.id == viewModel.selectedConnectionId,
    );

    return Column(
      children: [
        // Server Connection Selector Card
        Card(
          margin: const EdgeInsets.all(12),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: colorScheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(Icons.dns_outlined, color: colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        strings.selectServer,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value:
                              connections.any(
                                (c) => c.id == viewModel.selectedConnectionId,
                              )
                              ? viewModel.selectedConnectionId
                              : null,
                          hint: Text(strings.selectServerHint),
                          isExpanded: true,
                          isDense: true,
                          items: connections.map((conn) {
                            return DropdownMenuItem<String>(
                              value: conn.id,
                              child: Text(
                                conn.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }).toList(),
                          onChanged: viewModel.isRunning
                              ? null
                              : (v) {
                                  viewModel.setSelectedConnectionId(v);
                                },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // Playbook General Info Card
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      playbook.name,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (playbook.description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        playbook.description,
                        style: TextStyle(
                          fontSize: 13,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 8),
        Divider(height: 1, color: colorScheme.outlineVariant),

        // Steps display list
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
            itemCount: playbook.steps.length,
            itemBuilder: (context, index) {
              final step = playbook.steps[index];
              final isCurrent = viewModel.currentStepIndex == index;
              return _buildStepCard(
                index,
                step,
                isCurrent,
                playbook,
                viewModel,
                strings,
                colorScheme,
              );
            },
          ),
        ),

        // Execution Floating Control Bar
        _buildControlBar(viewModel, hasConnectedServer, strings, colorScheme),
      ],
    );
  }

  Widget _buildStepCard(
    int index,
    PlaybookStep step,
    bool isCurrent,
    Playbook playbook,
    PlaybookViewModel viewModel,
    _PlaybookStrings strings,
    ColorScheme colorScheme,
  ) {
    final isExpanded = viewModel.expandedSteps.contains(index);
    final hasOutput =
        (step.stdout != null && step.stdout!.isNotEmpty) ||
        (step.stderr != null && step.stderr!.isNotEmpty);

    Color statusColor;
    IconData statusIcon;
    Widget? trailingWidget;

    switch (step.status) {
      case StepStatus.success:
        statusColor = Colors.green;
        statusIcon = Icons.check_circle_rounded;
        break;
      case StepStatus.failed:
        statusColor = colorScheme.error;
        statusIcon = Icons.error_rounded;
        break;
      case StepStatus.running:
        statusColor = colorScheme.primary;
        statusIcon = Icons.sync_rounded;
        trailingWidget = const AppLoadingIndicator(size: 16, strokeWidth: 2);
        break;
      case StepStatus.skipped:
        statusColor = colorScheme.onSurfaceVariant.withValues(alpha: 0.5);
        statusIcon = Icons.double_arrow_rounded;
        break;
      case StepStatus.pending:
        statusColor = colorScheme.onSurfaceVariant.withValues(alpha: 0.35);
        statusIcon = Icons.radio_button_unchecked_rounded;
        break;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: isCurrent
              ? colorScheme.primary
              : (step.status == StepStatus.failed
                    ? colorScheme.error
                    : colorScheme.outlineVariant),
          width: isCurrent ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: hasOutput
                ? () {
                    viewModel.toggleStepExpanded(index);
                  }
                : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Status Icon
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: step.status == StepStatus.running
                        ? (trailingWidget ??
                              Icon(statusIcon, color: statusColor, size: 20))
                        : Icon(statusIcon, color: statusColor, size: 20),
                  ),
                  const SizedBox(width: 12),

                  // Content
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              '${strings.step} ${index + 1}: ',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: isCurrent
                                    ? colorScheme.primary
                                    : colorScheme.onSurface,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                step.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        OverflowScrollText(
                          step.command,
                          selectable: false,
                          maxLines: 1,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontFamilyFallback: [
                              'Consolas',
                              'Microsoft YaHei',
                              'PingFang SC',
                              'sans-serif',
                            ],
                            fontSize: 12,
                            backgroundColor: colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.5),
                            color: colorScheme.onSurface,
                          ),
                        ),
                        if (step.description.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            step.description,
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        if (step.expectedOutcomeRegex != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            '${strings.regex}: ${step.expectedOutcomeRegex}',
                            style: TextStyle(
                              fontSize: 11,
                              fontStyle: FontStyle.italic,
                              color: colorScheme.onSurfaceVariant.withValues(
                                alpha: 0.8,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  // Collapse / Expand toggle icon
                  if (hasOutput) ...[
                    const SizedBox(width: 8),
                    Icon(
                      isExpanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ],
                ],
              ),
            ),
          ),

          // AI Diagnostic Slot & Monospace Output Console
          if (step.status == StepStatus.failed) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(44, 0, 12, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    foregroundColor: colorScheme.primary,
                    backgroundColor: colorScheme.primaryContainer.withValues(
                      alpha: 0.3,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  icon: const Icon(Icons.smart_toy_outlined, size: 16),
                  label: Text(strings.aiDiagnostic),
                  onPressed: () =>
                      _requestAiDiagnostic(playbook, step, strings),
                ),
              ),
            ),
          ],

          if (hasOutput && isExpanded) ...[
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.terminalBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (step.exitCode != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        '${strings.exitCode}: ${step.exitCode}',
                        style: const TextStyle(
                          color: AppTheme.terminalAmber,
                          fontFamily: 'monospace',
                          fontFamilyFallback: [
                            'Consolas',
                            'Microsoft YaHei',
                            'PingFang SC',
                            'sans-serif',
                          ],
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  if (step.stdout != null && step.stdout!.isNotEmpty) ...[
                    const Text(
                      'STDOUT:',
                      style: TextStyle(
                        color: AppTheme.terminalGreen,
                        fontFamily: 'monospace',
                        fontFamilyFallback: [
                          'Consolas',
                          'Microsoft YaHei',
                          'PingFang SC',
                          'sans-serif',
                        ],
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      step.stdout!,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontFamily: 'monospace',
                        fontFamilyFallback: [
                          'Consolas',
                          'Microsoft YaHei',
                          'PingFang SC',
                          'sans-serif',
                        ],
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (step.stderr != null && step.stderr!.isNotEmpty) ...[
                    Text(
                      'STDERR:',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontFamily: 'monospace',
                        fontFamilyFallback: [
                          'Consolas',
                          'Microsoft YaHei',
                          'PingFang SC',
                          'sans-serif',
                        ],
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      step.stderr!,
                      style: TextStyle(
                        color: Theme.of(
                          context,
                        ).colorScheme.error.withValues(alpha: 0.9),
                        fontFamily: 'monospace',
                        fontFamilyFallback: [
                          'Consolas',
                          'Microsoft YaHei',
                          'PingFang SC',
                          'sans-serif',
                        ],
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildControlBar(
    PlaybookViewModel viewModel,
    bool hasConnectedServer,
    _PlaybookStrings strings,
    ColorScheme colorScheme,
  ) {
    final activePlaybook = viewModel.activePlaybook;
    if (activePlaybook == null) return const SizedBox.shrink();

    final isRunning = viewModel.isRunning;
    final isPaused = viewModel.isPaused;
    final isFinished =
        activePlaybook.steps.isNotEmpty &&
        activePlaybook.steps.every(
          (s) =>
              s.status == StepStatus.success || s.status == StepStatus.skipped,
        );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        border: Border(top: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            // Start / Pause / Resume / AI Summary
            Expanded(
              child: () {
                if (isFinished) {
                  return FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: colorScheme.primary,
                    ),
                    icon: const Icon(Icons.smart_toy_outlined),
                    label: Text(strings.aiSummary),
                    onPressed: () => _requestAiSummary(activePlaybook, strings),
                  );
                } else if (isRunning) {
                  return FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.orangeAccent.shade700,
                    ),
                    icon: const Icon(Icons.pause_rounded),
                    label: Text(strings.pause),
                    onPressed: () {
                      viewModel.pausePlaybook();
                    },
                  );
                } else if (isPaused) {
                  return FilledButton.icon(
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(strings.resume),
                    onPressed: viewModel.selectedConnectionId == null
                        ? null
                        : () => viewModel.resumePlaybook(
                            viewModel.selectedConnectionId!,
                          ),
                  );
                } else {
                  return FilledButton.icon(
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(strings.start),
                    onPressed: viewModel.selectedConnectionId == null
                        ? null
                        : () {
                            viewModel.runPlaybook(
                              viewModel.selectedConnectionId!,
                            );
                          },
                  );
                }
              }(),
            ),

            const SizedBox(width: 8),

            // Skip Step
            if (isRunning || isPaused) ...[
              OutlinedButton.icon(
                icon: const Icon(Icons.skip_next_rounded),
                label: Text(strings.skip),
                onPressed: viewModel.selectedConnectionId == null
                    ? null
                    : () => viewModel.skipCurrentStep(
                        viewModel.selectedConnectionId!,
                      ),
              ),
              const SizedBox(width: 8),
            ],

            // Reset
            OutlinedButton.icon(
              icon: const Icon(Icons.replay_rounded),
              label: Text(strings.reset),
              onPressed: () {
                viewModel.resetPlaybook(activePlaybook.id);
                // Clear local expanded steps
                viewModel.expandedSteps.clear();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _requestAiDiagnostic(
    Playbook playbook,
    PlaybookStep step,
    _PlaybookStrings strings,
  ) {
    final prompt =
        """My playbook step failed. Please diagnose and help me fix it!

Playbook: ${playbook.name}
Step Index: ${playbook.steps.indexOf(step) + 1}
Step Name: ${step.name}
Description: ${step.description}
Command executed: `${step.command}`
Exit code: ${step.exitCode}

Stdout:
${step.stdout ?? "(empty)"}

Stderr:
${step.stderr ?? "(empty)"}

Please analyze what went wrong and provide:
1. An explanation of why the command failed.
2. A corrected command or setup steps to fix this problem.""";

    // Set the prompt in the viewModel/service
    context.read<PlaybookViewModel>().pendingDiagnosticPrompt = prompt;

    // Send notification to switch to AI tab
    const PlaybookAiNavigationNotification().dispatch(context);

    // Pop current screen (if it was pushed on top of Home)
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    if (rootNavigator.canPop()) {
      rootNavigator.pop();
    }
  }

  void _requestAiSummary(Playbook playbook, _PlaybookStrings strings) {
    String limitOutput(String? text) {
      if (text == null || text.trim().isEmpty) return '(empty)';
      final trimmed = text.trim();
      if (trimmed.length > 500) {
        return '${trimmed.substring(0, 500)}\n...[truncated]';
      }
      return trimmed;
    }

    final buffer = StringBuffer()
      ..writeln(
        strings.language == PlaybookLanguage.en
            ? "I have finished executing the following playbook successfully! Please review the overall execution results and summarize them:"
            : "我已成功执行完以下运维剧本！请评估整体的执行结果并做一个总结：",
      )
      ..writeln()
      ..writeln("Playbook: ${playbook.name}")
      ..writeln(
        "Description: ${playbook.description.isEmpty ? '(none)' : playbook.description}",
      )
      ..writeln()
      ..writeln("Execution Steps & Results:");

    for (int i = 0; i < playbook.steps.length; i++) {
      final step = playbook.steps[i];
      buffer
        ..writeln("---")
        ..writeln("Step ${i + 1}: ${step.name}")
        ..writeln("Command: `${step.command}`")
        ..writeln("Status: ${step.status.name}")
        ..writeln("Exit Code: ${step.exitCode ?? 'N/A'}")
        ..writeln("Stdout:")
        ..writeln(limitOutput(step.stdout))
        ..writeln("Stderr:")
        ..writeln(limitOutput(step.stderr));
    }

    buffer
      ..writeln("---")
      ..writeln()
      ..writeln(
        strings.language == PlaybookLanguage.en
            ? "Please provide a quick summary confirming that everything is successful, highlight any potential post-run validation I should do, and give next step suggestions."
            : "请提供一个简短的总结，确认所有操作均已成功执行。指出任何我可能需要进行的后续校验，并给出下一步建议。",
      );

    // Set the prompt in the viewModel/service
    context.read<PlaybookViewModel>().pendingDiagnosticPrompt = buffer
        .toString();

    // Send notification to switch to AI tab
    const PlaybookAiNavigationNotification().dispatch(context);

    // Pop current screen (if it was pushed on top of Home)
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    if (rootNavigator.canPop()) {
      rootNavigator.pop();
    }
  }
}
