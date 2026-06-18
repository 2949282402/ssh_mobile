import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/startup/viewmodels/startup_viewmodel.dart';
import '../services/app_settings.dart';
import '../theme/app_theme.dart';
import 'home_screen.dart';

class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key});

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<StartupViewModel>();

    if (!viewModel.storageInitialized || !viewModel.settingsInitialized) {
      return const _StartupLoadingScreen();
    }

    if (!viewModel.isAndroidTarget) {
      return const HomeScreen();
    }

    viewModel.schedulePowerGuideCheck(() {
      if (mounted) {
        viewModel.checkPowerGuideStatus();
      }
    });

    if (!viewModel.powerStatusChecked) {
      return const _StartupLoadingScreen();
    }

    if (viewModel.shouldShowPowerGuide) {
      return PowerGuideScreen(
        viewModel: viewModel,
      );
    }

    return const HomeScreen();
  }
}

class _StartupLoadingScreen extends StatelessWidget {
  const _StartupLoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class PowerGuideScreen extends StatefulWidget {
  final StartupViewModel viewModel;

  const PowerGuideScreen({super.key, required this.viewModel});

  @override
  State<PowerGuideScreen> createState() => _PowerGuideScreenState();
}

class _PowerGuideScreenState extends State<PowerGuideScreen> {
  @override
  void initState() {
    super.initState();
    widget.viewModel.refreshBatteryExemptionStatus();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final strings = AppStrings(widget.viewModel.language);
    final viewModel = widget.viewModel;

    return Scaffold(
      appBar: AppBar(title: Text(strings.backgroundConnectionSettings)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Icon(
              Icons.battery_saver_outlined,
              size: 56,
              color: colorScheme.secondary,
            ),
            const SizedBox(height: 20),
            Text(
              strings.enableBackgroundPermission,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text(
              strings.backgroundPermissionGuide,
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: colorScheme.onSurface.withValues(alpha: 0.72),
              ),
            ),
            const SizedBox(height: 24),
            _StatusTile(isExempt: viewModel.isExempt, strings: strings),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => viewModel.requestBatteryExemption(),
              icon: const Icon(Icons.power_settings_new),
              label: Text(strings.adjustPowerLimit),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => viewModel.openAppSettings(),
              icon: const Icon(Icons.settings_outlined),
              label: Text(strings.openAppSettings),
            ),
            const SizedBox(height: 20),
            Text(
              strings.backgroundGuideNote,
              style: TextStyle(
                fontSize: 13,
                height: 1.45,
                color: colorScheme.onSurface.withValues(alpha: 0.62),
              ),
            ),
            const SizedBox(height: 28),
            TextButton(
              onPressed: () => viewModel.markPowerGuideSeen(),
              child: Text(strings.enterApp),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusTile extends StatelessWidget {
  final bool isExempt;
  final AppStrings strings;

  const _StatusTile({required this.isExempt, required this.strings});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final statusColor =
        isExempt ? colorScheme.secondary : AppTheme.terminalAmber;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(
            isExempt ? Icons.check_circle_outline : Icons.info_outline,
            color: statusColor,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              isExempt ? strings.powerLimitExempt : strings.powerLimitUnknown,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
