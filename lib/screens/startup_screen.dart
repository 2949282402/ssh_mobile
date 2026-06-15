import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/background_service.dart';
import '../services/app_settings.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import 'home_screen.dart';

class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key});

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  bool _checkingPowerStatus = false;
  bool _powerStatusChecked = false;
  bool _powerStatusCheckScheduled = false;
  bool _shouldShowPowerGuide = false;

  bool get _isAndroidTarget {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  }

  Future<void> _checkPowerGuideStatus() async {
    if (_powerStatusChecked || _checkingPowerStatus) return;
    if (!_isAndroidTarget) {
      setState(() {
        _powerStatusChecked = true;
        _shouldShowPowerGuide = false;
      });
      return;
    }

    setState(() => _checkingPowerStatus = true);
    var isExempt = false;
    try {
      isExempt = await BackgroundServiceManager.isIgnoringBatteryOptimizations()
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      isExempt = false;
    }

    if (!mounted) return;
    setState(() {
      _checkingPowerStatus = false;
      _powerStatusChecked = true;
      _shouldShowPowerGuide = !isExempt;
    });
  }

  void _enterAppForThisLaunch() {
    setState(() => _shouldShowPowerGuide = false);
  }

  @override
  Widget build(BuildContext context) {
    final storageInitialized = context.select<StorageService, bool>(
      (storage) => storage.initialized,
    );
    final settingsInitialized = context.select<AppSettings, bool>(
      (settings) => settings.initialized,
    );

    if (!storageInitialized || !settingsInitialized) {
      return const _StartupLoadingScreen();
    }

    if (!_isAndroidTarget) {
      return const HomeScreen();
    }

    _schedulePowerGuideCheck();

    if (!_powerStatusChecked) {
      return const _StartupLoadingScreen();
    }

    if (_shouldShowPowerGuide) {
      return PowerGuideScreen(onContinue: _enterAppForThisLaunch);
    }

    return const HomeScreen();
  }

  void _schedulePowerGuideCheck() {
    if (_powerStatusChecked ||
        _checkingPowerStatus ||
        _powerStatusCheckScheduled) {
      return;
    }
    _powerStatusCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _powerStatusCheckScheduled = false;
      if (mounted) {
        _checkPowerGuideStatus();
      }
    });
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
  final VoidCallback? onContinue;

  const PowerGuideScreen({super.key, this.onContinue});

  @override
  State<PowerGuideScreen> createState() => _PowerGuideScreenState();
}

class _PowerGuideScreenState extends State<PowerGuideScreen> {
  bool _isExempt = false;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    try {
      final exempt =
          await BackgroundServiceManager.isIgnoringBatteryOptimizations()
              .timeout(const Duration(seconds: 2));
      if (mounted) {
        setState(() => _isExempt = exempt);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isExempt = false);
      }
    }
  }

  Future<void> _continue() async {
    await context.read<StorageService>().markPowerGuideSeen();
    widget.onContinue?.call();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AppStrings(language);

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
            _StatusTile(isExempt: _isExempt),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () async {
                await BackgroundServiceManager
                        .requestBatteryOptimizationExemption()
                    .timeout(const Duration(seconds: 2), onTimeout: () {});
                await _refreshStatus();
              },
              icon: const Icon(Icons.power_settings_new),
              label: Text(strings.adjustPowerLimit),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: BackgroundServiceManager.openAppSettings,
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
              onPressed: _continue,
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

  const _StatusTile({required this.isExempt});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AppStrings(language);
    final statusColor =
        isExempt ? colorScheme.secondary : AppTheme.terminalAmber;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
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
